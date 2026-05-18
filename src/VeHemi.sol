// SPDX-License-Identifier: MIT
pragma solidity 0.8.29;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable2StepUpgradeable} from "@openzeppelin/contracts-upgradeable/access/Ownable2StepUpgradeable.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IRewardDistributor} from "./interfaces/IRewardDistributor.sol";
import {IVeHemiVoteDelegation} from "./interfaces/IVeHemiVoteDelegation.sol";
import {ERC721EnumerableUpgradeable, ERC721Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC721/extensions/ERC721EnumerableUpgradeable.sol";
import {ReentrancyGuardTransientUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardTransientUpgradeable.sol";
import {VeHemiStorageV2} from "./storage/VeHemiStorageV2.sol";

/**
 * @title VeHemi
 * @notice Vesting and yield system based on Curve's veCRV and AERO voting escrow mechanism. Users lock HEMI for up to 4 years.
 * @dev The contract maintains a global curve and two parallel subcurves
 *      (locked and forfeitable) tracking non-transferable and forfeitable
 *      stake weight. The subcurves are gated behind `lockedSeedingFinalized`,
 *      a one-way latch:
 *
 *        - `lockedSeedingFinalized == false`: `_checkpoint` skips all
 *          subcurve accumulation. The global curve behaves identically with
 *          or without the latch flipped.
 *        - `markSeedingStarted` + repeated `seedBatch(maxIterations)` +
 *          `finalizeSeeding` performs the on-chain enumeration that
 *          materializes the locked + forfeitable `LockedPoint`s for all
 *          existing non-transferable positions, then flips the latch to
 *          true. There is no un-finalize path; a position missed at
 *          seeding time permanently understates the locked subcurve with
 *          no on-chain recovery.
 *        - `lockedSeedingFinalized == true`: subcurve logic is live; every
 *          `_checkpoint` updates the locked and forfeitable curves in
 *          parallel with the global one.
 *
 *      Checkpoint math is strictly additive: the global curve produces
 *      identical values whether or not the latch is flipped. Only the
 *      subcurve reads (`supplyBreakdown`, `nonTransferableTotalVeHemiSupply`,
 *      `forfeitableTotalVeHemiSupply`) depend on seeding having run.
 *
 *      Behavior notes:
 *        - `createLock` / `createLockFor` reject amounts below
 *          `MIN_LOCK_AMOUNT` (10 HEMI) with `AmountTooSmall`.
 *        - `createLockFor` reverts `InvalidConfiguration` if both
 *          `transferable_` and `forfeitable_` are true (mutually exclusive).
 *        - `forfeit` is bounded by `transferableAfter` rather than
 *          `lock.end`: once a position becomes transferable, the forfeit
 *          window closes (reverts `ForfeitWindowExpired`).
 *        - Between `markSeedingStarted()` and `finalizeSeeding()` (a
 *          multi-block window: owner opens with `markSeedingStarted`,
 *          anyone drives `seedBatch` until the cursor reaches
 *          `seedingTargetId - 1`, anyone calls `finalizeSeeding`),
 *          `_createLock` for non-transferable positions, `forfeit`, and
 *          `increaseAmount` / `increaseUnlockTime` on non-transferable
 *          positions all revert with `SeedingInProgress`. Transferable
 *          positions are unaffected. Operators MUST drive the flow to
 *          completion within hours of opening the window to keep finalize
 *          ahead of any seeded position's `subEnd` (worst-case floor
 *          ~6 days after SIX_DAYS rounding, ~12 days typical; see
 *          `finalizeSeeding` NatSpec).
 *        - `transferFrom` carries a `nonReentrant` modifier. Composed
 *          contracts that re-enter VeHemi from `onERC721Received` will
 *          revert; pure ERC-721 receivers and callbacks that only read
 *          VeHemi state are unaffected.
 */
contract VeHemi is
    ERC721EnumerableUpgradeable,
    Ownable2StepUpgradeable,
    ReentrancyGuardTransientUpgradeable,
    VeHemiStorageV2
{
    using SafeCast for uint256;
    using SafeCast for int256;
    using SafeCast for int128;
    using SafeERC20 for IERC20;

    IERC20 public immutable HEMI;

    // --- Constants ---
    uint256 private constant YEAR = 365.25 days;
    /// @dev SIX_DAYS is the week-ish epoch bucket used by all time rounding
    ///      (lock.end, transferableAfter, slope-change grid). Despite the name,
    ///      it equals `YEAR / 60` = 525,960 seconds ≈ 6.0875 days — chosen so
    ///      there are exactly 60 buckets per Julian year (120 per 2 years,
    ///      240 per 4-year MAX_TIME). This matches the Curve veCRV convention
    ///      of "60 periods per year" even though each period is slightly longer
    ///      than 6 calendar days.
    uint256 private constant SIX_DAYS = YEAR / (12 * 5);
    uint256 private constant MAX_TIME = 4 * YEAR; // 4 years
    uint256 private constant MULTIPLIER = 1 ether;
    uint256 private constant MIN_LOCK_AMOUNT = 10e18; // 10 HEMI — prevents dust lock griefing
    string public constant version = "2.0.0";
    uint8 public constant decimals = 18;

    // --- Errors ---
    error AddressIsNull();
    error AmountIsZero();
    error AmountTooSmall();
    error LockExpired();
    error LockNotExpired();
    error LockDurationTooShort();
    error LockDurationTooLong();
    error NoExistingLock();
    error NotOwner();
    error NewLockDurationNotGreater();
    error NotForfeitable();
    error NotForfeitAdmin();
    error OwnerIsZero();
    error NotTransferable();
    error SeedingAlreadyFinalized();
    error SeedingAlreadyStarted();
    error SeedingNotStarted();
    error SeedingInProgress();
    error SeedingIncomplete(uint256 lastProcessedId, uint256 expectedEnd);
    error ForfeitWindowExpired();
    error InvalidConfiguration();
    error TokenDoesNotExist();

    constructor(address hemi_) {
        if (hemi_ == address(0)) revert AddressIsNull();
        HEMI = IERC20(hemi_);

        _disableInitializers();
    }

    /**
     * @notice Initializes the contract with the owner address
     * @param owner_ The address of the contract owner
     */
    function initialize(address owner_) external initializer {
        if (owner_ == address(0)) revert OwnerIsZero();
        __ERC721_init("veHemi", "veHemi");
        __Ownable_init_unchained(owner_);
        globalPointHistory[0].blockNumber = block.number.toUint64();
        globalPointHistory[0].timestamp = block.timestamp.toUint64();
        nextTokenId = 1;
    }

    /**
     * @notice Returns the current stake weight for a given NFT
     * @dev Stake weight is the linearly-decaying bias: slope * (lock.end - now).
     *      This is NOT the deposited HEMI amount — use getLockedBalance() for that.
     * @param tokenId_ The token ID
     * @return _balance The stake weight (0 if expired or non-existent)
     */
    function balanceOfNFT(uint256 tokenId_) external view returns (uint256 _balance) {
        (_balance, ) = _balanceOfNFTAt(tokenId_, block.timestamp);
    }

    /**
     * @notice Returns the stake weight for a given NFT at a specific timestamp
     * @dev Stake weight is the linearly-decaying bias: slope * (lock.end - timestamp).
     * @param tokenId_ The token ID
     * @param timestamp_ The timestamp to query
     * @return _balance The stake weight at the given timestamp
     */
    function balanceOfNFTAt(
        uint256 tokenId_,
        uint256 timestamp_
    ) external view returns (uint256 _balance) {
        (_balance, ) = _balanceOfNFTAt(tokenId_, timestamp_);
    }

    /**
     * @notice Returns the stake weight and recorded owner for a given NFT at a specific timestamp
     * @dev The owner is the address recorded in the user point history at that time
     *      (may differ from current ownerOf after transfers or burns).
     * @param tokenId_ The token ID
     * @param timestamp_ The timestamp to query
     * @return _balance The stake weight at the given timestamp
     * @return _owner The owner recorded in the user point at that timestamp
     */
    function balanceAndOwnerOfNFTAt(
        uint256 tokenId_,
        uint256 timestamp_
    ) external view returns (uint256 _balance, address _owner) {
        return _balanceOfNFTAt(tokenId_, timestamp_);
    }

    /**
     * @notice Checkpoints the contract state to update global and user point histories
     */
    function checkpoint() external nonReentrant {
        _checkpoint(0, LockedBalance(0, 0), LockedBalance(0, 0));
    }

    /**
     * @notice Creates a new lock for the sender
     * @param amount_ The amount of HEMI to lock
     * @param lockDuration_ The duration to lock HEMI for
     * @return _tokenId The ID of the created lock NFT
     */
    function createLock(
        uint256 amount_,
        uint256 lockDuration_
    ) external nonReentrant returns (uint256 _tokenId) {
        _tokenId = _createLock(amount_, lockDuration_, _msgSender(), true, false);
    }

    /**
     * @notice Creates a new lock for a specified account
     * @param amount_ The amount of HEMI to lock
     * @param lockDuration_ The duration to lock HEMI for
     * @param account_ The address to assign the lock NFT to
     * @return _tokenId The ID of the created lock NFT
     */
    function createLockFor(
        uint256 amount_,
        uint256 lockDuration_,
        address account_,
        bool transferable_,
        bool forfeitable_
    ) external nonReentrant returns (uint256 _tokenId) {
        if (account_ == address(0)) revert AddressIsNull();
        _tokenId = _createLock(amount_, lockDuration_, account_, transferable_, forfeitable_);
    }

    /**
     * @notice Forfeit a lock position — callable only by the forfeit admin.
     * @dev The locked HEMI is transferred to the forfeit admin (msg.sender), NOT the position owner.
     *      V2: The forfeit window is bounded by transferableAfter. Once block.timestamp >= transferableAfter,
     *      the position can no longer be forfeited (reverts ForfeitWindowExpired). This prevents punishing
     *      users who voluntarily extended their lock past the original non-transferability term.
     * @param tokenId_ The token ID to forfeit
     */
    function forfeit(uint256 tokenId_) external nonReentrant {
        if (_msgSender() != forfeitAdmin) revert NotForfeitAdmin();
        if (!forfeitable[tokenId_]) revert NotForfeitable();
        if (locked[tokenId_].end < block.timestamp) revert LockExpired();
        // V2: Forfeit window is bounded by transferableAfter. Once the position
        // becomes transferable, it can no longer be forfeited — this prevents
        // punishing users who voluntarily extend their lock past the original term.
        if (block.timestamp >= transferableAfter[tokenId_]) revert ForfeitWindowExpired();
        // Forfeitable positions are always non-transferable, so always check.
        _requireSeedingNotActiveForNonTransferable(true);
        _delegate(tokenId_, address(0));
        _withdraw(tokenId_);
    }

    /**
     * @notice Get the locked balance information for a specific token
     * @param tokenId_ The token ID to get locked balance for
     * @return The LockedBalance struct containing amount and end time
     */
    function getLockedBalance(uint256 tokenId_) external view returns (LockedBalance memory) {
        return locked[tokenId_];
    }

    /**
     * @notice Returns the user point for a given token and epoch
     * @param tokenId_ The token ID
     * @param epoch_ The epoch number
     * @return The Point struct for the user at the given epoch
     */
    function getUserPoint(
        uint256 tokenId_,
        uint256 epoch_
    ) external view returns (UserPoint memory) {
        return userPointHistory[tokenId_][epoch_];
    }

    /**
     * @notice Returns the global point for a given epoch
     * @param epoch_ The epoch number
     * @return The Point struct for the global point at the given epoch
     */
    function getGlobalPoint(uint256 epoch_) external view returns (Point memory) {
        return globalPointHistory[epoch_];
    }

    /**
     * @notice Increases the amount of HEMI locked for a given token
     * @param tokenId_ The token ID
     * @param amount_ The additional amount to lock
     */
    function increaseAmount(uint256 tokenId_, uint256 amount_) external nonReentrant {
        LockedBalance memory _oldLocked = locked[tokenId_];

        if (amount_ == 0) revert AmountIsZero();
        if (_oldLocked.amount <= 0) revert NoExistingLock();
        if (_oldLocked.end <= block.timestamp) revert LockExpired();

        _requireSeedingNotActiveForNonTransferable(transferableAfter[tokenId_] != 0);

        _depositFor(tokenId_, amount_, 0, _oldLocked);
    }

    /**
     * @notice Increases the unlock time for a given lock NFT
     * @param tokenId_ The token ID
     * @param lockDuration_ The new lock duration (from now)
     */
    function increaseUnlockTime(uint256 tokenId_, uint256 lockDuration_) external nonReentrant {
        if (_ownerOf(tokenId_) != _msgSender()) revert NotOwner();
        LockedBalance memory _oldLocked = locked[tokenId_];
        if (_oldLocked.end <= block.timestamp) revert LockExpired();
        if (_oldLocked.amount <= 0) revert NoExistingLock();
        uint256 _unlockTime = ((block.timestamp + lockDuration_) / SIX_DAYS) * SIX_DAYS; // unlock time is rounded down to SIX_DAYS
        if (_unlockTime > block.timestamp + MAX_TIME) revert LockDurationTooLong();
        if (_unlockTime <= _oldLocked.end) revert NewLockDurationNotGreater();

        _requireSeedingNotActiveForNonTransferable(transferableAfter[tokenId_] != 0);

        // V2: transferableAfter is NOT extended when the user voluntarily extends their lock.
        // The user was promised transferability at the original unlock time, and extending the
        // lock should not move that goalpost. After transferableAfter passes, the position:
        //   - becomes transferable (can be traded via transferFrom)
        //   - is no longer forfeitable (admin cannot claw it back)
        //   - exits the locked/forfeitable subcurves (tracked in global only)
        //   - retains its full voting power until the new lock.end

        _depositFor(tokenId_, 0, _unlockTime.toUint64(), _oldLocked);
    }

    /**
     * @notice Check if a token is currently transferable.
     * @dev True when `transferableAfter[tokenId_] <= block.timestamp`. The
     *      `<=` makes the position transferable AT its `transferableAfter`
     *      timestamp. Transferable-at-mint positions store
     *      `transferableAfter == 0` and therefore return true unconditionally.
     *
     *      Non-existent and burned ids share the default `transferableAfter`
     *      value of 0 and so this predicate returns true for them too —
     *      `transferFrom` rejects them via its own `_ownerOf == 0` check,
     *      but external callers using this view as a membership test
     *      should pair it with an `ownerOf` query. Folding an
     *      `_ownerOf(tokenId_) != address(0)` SLOAD into this predicate is
     *      deferred until bytecode headroom is reclaimed via library
     *      extraction.
     * @param tokenId_ The token ID.
     * @return True if the token is transferable now.
     */
    function isTransferable(uint256 tokenId_) public view returns (bool) {
        return (transferableAfter[tokenId_] <= block.timestamp);
    }

    /**
     * @notice Get the total veHEMI stake weight at the current timestamp
     * @return The aggregate stake weight across all positions (sum of linearly-decaying biases)
     */
    function totalVeHemiSupply() public view returns (uint256) {
        return _supplyAt(block.timestamp);
    }

    /**
     * @notice Get the total veHEMI stake weight at a specific timestamp
     * @param timestamp_ The timestamp to query
     * @return The aggregate stake weight at the given timestamp
     */
    function totalVeHemiSupplyAt(uint256 timestamp_) external view returns (uint256) {
        return _supplyAt(timestamp_);
    }

    /**
     * @notice Update the reward distributor contract address
     * @dev Only callable by the contract owner. Can be set to address(0) to disable rewards.
     * @param newRewardDistributor_ The new reward distributor contract address
     */
    function updateRewardDistributor(IRewardDistributor newRewardDistributor_) external onlyOwner {
        // Allowed to set to 0x0
        IRewardDistributor _oldRewardDistributor = rewardDistributor;
        rewardDistributor = newRewardDistributor_;
        emit RewardDistributorUpdated(_oldRewardDistributor, newRewardDistributor_);
    }

    /**
     * @notice Update the forfeit admin address
     * @dev Only callable by the contract owner. Can be set to address(0) to disable forfeits.
     * @param newForfeitAdmin_ The new forfeit admin address
     */
    function updateForfeitAdmin(address newForfeitAdmin_) external onlyOwner {
        address _oldForfeitAdmin = forfeitAdmin;
        forfeitAdmin = newForfeitAdmin_;
        emit ForfeitAdminUpdated(_oldForfeitAdmin, newForfeitAdmin_);
    }

    /**
     * @notice Replace the vote delegation contract pointer.
     *
     * @dev    ⚠️ CRITICAL: this is a single-SSTORE pointer swap that performs
     *         ZERO state migration. Every cached delegation (per-tokenId
     *         `delegations[id]`, per-account `autoDelegate[owner]`,
     *         `delegateCheckpoints[delegatee][]` history, slope-change
     *         buckets, EIP-712 nonces, and `trustedAdapter`) lives entirely
     *         inside the OLD VeHemiVoteDelegation proxy's storage. The NEW
     *         contract starts empty. After this call:
     *
     *         1. `_reDelegate(tokenId)` reads the NEW contract, sees
     *            `delegations[id].delegatee == address(0)`, and SILENTLY
     *            SKIPS re-delegation (no event, no revert). Every voter's
     *            stake is effectively undelegated until each user manually
     *            calls `delegate()` on the new contract.
     *
     *         2. Aragon proposals snapshotted BEFORE this call read
     *            `getPastVotes(voter, snapshotBlock)` against the NEW
     *            (empty) contract and return 0 for every voter. In-flight
     *            proposals can become unwinnable — even users who
     *            re-delegate immediately after the swap cannot vote on
     *            them, because the snapshot block is fixed in the past.
     *            NOTE: `importDelegationsFromLegacy` builds FORWARD-ONLY
     *            checkpoints starting at the next epoch boundary; it does
     *            not back-fill historical `getPastVotes`. Pre-swap snapshot
     *            queries are unrecoverable on the new contract.
     *
     *         3. The Aragon event relay (`notifyDelegateChanged`,
     *            `notifyVotesChanged`) stops firing until `setTrustedAdapter`
     *            is called on the new contract.
     *
     *         4. `autoDelegate[owner]` mappings are empty — users who had
     *            "auto-delegate all future mints to X" lose that config.
     *
     *      ⚠️ MANDATORY OPERATOR RUNBOOK (single Gnosis Safe MultiSend):
     *         1. Deploy the new VeHemiVoteDelegation proxy + implementation.
     *         2. Snapshot every live (tokenId, delegatee) and (owner,
     *            autoDelegate) pair from the OLD proxy off-chain (via
     *            `VeHemiVoteDelegation.delegation(id)` and
     *            `.autoDelegate(owner)` on the live OLD proxy).
     *         3. Call `newVoteDelegation.importDelegationsFromLegacy(oldProxy,
     *            tokenIds)` in paginated batches to replay the snapshot.
     *            Recommended batch size: ≤ 150 tokenIds per call. Empirical
     *            cost is ~165k gas/iter worst-case (cold checkpoint write +
     *            slope-bucket update + two STATICCALLs), so 150 IDs ≈ 25M
     *            gas — within Hemi's 30M block limit with ~5M headroom.
     *            Multiple calls inside one MultiSend remain atomic, and
     *            each call is idempotent.
     *         4. Call `newVoteDelegation.importAutoDelegatesFromLegacy(
     *            oldProxy, owners)` for the autoDelegate map.
     *         5. Call `newVoteDelegation.setTrustedAdapter(adapter)` to
     *            re-wire the Aragon event relay.
     *         6. Call `newVoteDelegation.finalizeMigration()` to seal the
     *            import path so no further state can be injected.
     *         7. Call `veHemi.updateVoteDelegation(newProxy)` LAST — only
     *            after steps 1–6 are complete in the SAME Safe MultiSend.
     *
     *      ⚠️ DO NOT call this function while Aragon proposals are in
     *         flight (snapshotted but not yet executed). Wait for all
     *         pending proposals to resolve, OR schedule the migration
     *         during a deliberate governance freeze.
     *
     *      ⚠️ This function is a RECOVERY PRIMITIVE for when the deployed
     *         VeHemiVoteDelegation proxy is irreparably broken. For routine
     *         implementation changes, prefer the TransparentProxy upgrade
     *         path which preserves all storage.
     *
     * @param newVoteDelegation_ Address of the new VeHemiVoteDelegation
     *        proxy. Must have its `delegations[]` / `autoDelegate[]` /
     *        `trustedAdapter` already populated via the new contract's
     *        import functions BEFORE this swap lands.
     */
    function updateVoteDelegation(IVeHemiVoteDelegation newVoteDelegation_) external onlyOwner {
        if (address(newVoteDelegation_) == address(0)) revert AddressIsNull();
        IVeHemiVoteDelegation _oldVoteDelegation = voteDelegation;
        voteDelegation = newVoteDelegation_;
        emit VoteDelegationUpdated(_oldVoteDelegation, newVoteDelegation_);
    }

    /**
     * @notice Withdraws HEMI after the lock has expired and burns the NFT
     * @param tokenId_ The token ID to withdraw from
     */
    function withdraw(uint256 tokenId_) external nonReentrant {
        if (_ownerOf(tokenId_) != _msgSender()) revert NotOwner();
        if (block.timestamp < locked[tokenId_].end) revert LockNotExpired();
        // Clear the stale `delegations[tokenId]` cache and emit
        // `DelegateChanged(tokenId, X, 0)` so indexers see a clean lifecycle
        // for the burned token. `_delegate` routes `delegatee_ == address(0)`
        // through unconditionally so this works even when the lock has just
        // expired.
        _delegate(tokenId_, address(0));
        _withdraw(tokenId_);
    }

    /**
     * @dev Computes the linearly-decayed stake weight for a token at a historical timestamp
     *      by binary-searching the user point history and projecting from the nearest point.
     *      Returns (0, address(0)) if no user point exists (epoch 0).
     */
    function _balanceOfNFTAt(
        uint256 tokenId_,
        uint256 timestamp_
    ) internal view returns (uint256, address) {
        uint256 _epoch = _getPastUserPointIndex(tokenId_, timestamp_);
        // epoch 0 is an empty point
        if (_epoch == 0) return (0, address(0));
        UserPoint memory _lastUserPoint = userPointHistory[tokenId_][_epoch];
        _lastUserPoint.point.bias -=
            _lastUserPoint.point.slope *
            (timestamp_ - _lastUserPoint.point.timestamp).toInt256().toInt128();
        if (_lastUserPoint.point.bias < 0) {
            _lastUserPoint.point.bias = 0;
        }
        return (_lastUserPoint.point.bias.toUint256(), _lastUserPoint.owner);
    }

    function _getPastGlobalPointIndex(
        uint256 epoch_,
        uint256 timestamp_
    ) internal view returns (uint256) {
        if (epoch_ == 0) return 0;
        // First check most recent balance
        if (globalPointHistory[epoch_].timestamp <= timestamp_) return (epoch_);
        // Next check implicit zero balance
        if (globalPointHistory[1].timestamp > timestamp_) return 0;

        uint256 _lower;
        uint256 _upper = epoch_;
        while (_upper > _lower) {
            uint256 _center = _upper - (_upper - _lower) / 2; // ceil, avoiding overflow
            Point memory _globalPoint = globalPointHistory[_center];
            if (_globalPoint.timestamp == timestamp_) {
                return _center;
            } else if (_globalPoint.timestamp < timestamp_) {
                _lower = _center;
            } else {
                _upper = _center - 1;
            }
        }
        return _lower;
    }

    function _getPastUserPointIndex(
        uint256 tokenId_,
        uint256 timestamp_
    ) internal view returns (uint256) {
        uint256 _userEpoch = userPointEpoch[tokenId_];
        if (_userEpoch == 0) return 0;
        Point memory _lastPoint = userPointHistory[tokenId_][_userEpoch].point;
        // First check most recent balance
        if (_lastPoint.timestamp <= timestamp_) return (_userEpoch);
        // Next check implicit zero balance
        if (userPointHistory[tokenId_][1].point.timestamp > timestamp_) return 0;

        uint256 _lower;
        uint256 _upper = _userEpoch;
        while (_upper > _lower) {
            uint256 _center = _upper - (_upper - _lower) / 2; // ceil, avoiding overflow
            Point memory _userPoint = userPointHistory[tokenId_][_center].point;
            if (_userPoint.timestamp == timestamp_) {
                return _center;
            } else if (_userPoint.timestamp < timestamp_) {
                _lower = _center;
            } else {
                _upper = _center - 1;
            }
        }
        return _lower;
    }

    /**
     * @notice Internal function to checkpoint user and global point histories.
     * @dev V2: Maintains parallel locked and forfeitable subcurves.
     *      - Locked curve: all non-transferrable positions (transferableAfter != 0)
     *      - Forfeitable curve: forfeitable non-transferrable positions (strict subset of locked)
     *      Both share the same epoch counter as the global curve.
     *      All subcurve tracking is gated on `lockedSeedingFinalized` to prevent corruption
     *      during the seeding window.
     *
     *      V1-COMPATIBILITY INVARIANT: the global-curve computations (Point arithmetic,
     *      `slopeChanges`, `globalPointHistory`, `userPointHistory`, `epoch`) are byte-for-byte
     *      identical to the V1 implementation. The V2 additions are strictly additive:
     *          (a) compute `_curveFlags` from `transferableAfter` / `forfeitable` — side-effect free,
     *          (b) compute `_oldSubcurveBias` / `_newSubcurveBias` using `min(lock.end, transferableAfter)`,
     *          (c) write to `lockedGlobalPointHistory` / `forfeitableGlobalPointHistory` /
     *              `lockedSlopeChanges` / `forfeitableSlopeChanges` — disjoint storage from V1,
     *          (d) every subcurve branch is guarded by `lockedSeedingFinalized`, so pre-seeding
     *              this function is a pure V1 checkpoint.
     *      This means upgrading the implementation (before seeding) cannot alter the global
     *      curve's view of any historical or future timestamp.
     *
     *      Stack depth is managed by:
     *        - Moving `_initialLastPoint`, `_blockSlope`, `_lastCheckpoint` into the
     *          catchup loop's scoping block (they are only used inside the loop).
     *        - Extracting slope change scheduling (Phase D) into `_scheduleSlopeChanges`.
     * @param tokenId_ The token ID (0 for external checkpoint)
     * @param oldLocked_ The previous locked balance
     * @param newLocked_ The new locked balance
     */
    function _checkpoint(
        uint256 tokenId_,
        LockedBalance memory oldLocked_,
        LockedBalance memory newLocked_
    ) internal {
        Point memory _oldUserPoint;
        Point memory _newUserPoint;
        // V2: Curve membership flags (packed into uint8 for stack depth).
        // Bits: [newFlags:4..7][oldFlags:0..3]. Each nibble: 0=transferable, 1=locked, 2=locked+forfeitable.
        // oldFlags: what the position WAS (determines subcurve removal)
        // newFlags: what the position IS NOW (determines subcurve addition)
        uint8 _curveFlags;
        // V2: Subcurve-specific bias deltas (differ from global when transferableAfter < lock.end)
        int128 _oldSubcurveBias;
        int128 _newSubcurveBias;

        // --- Phase A: Compute old/new user points, determine locked/forfeitable status ---
        if (tokenId_ != 0) {
            if (oldLocked_.end > block.timestamp && oldLocked_.amount > 0) {
                _oldUserPoint.slope = oldLocked_.amount / MAX_TIME.toInt256().toInt128();
                _oldUserPoint.bias =
                    _oldUserPoint.slope *
                    (oldLocked_.end - block.timestamp).toInt256().toInt128();
            }

            if (newLocked_.end > block.timestamp && newLocked_.amount > 0) {
                _newUserPoint.slope = newLocked_.amount / MAX_TIME.toInt256().toInt128();
                _newUserPoint.bias =
                    _newUserPoint.slope *
                    (newLocked_.end - block.timestamp).toInt256().toInt128();
            }

            if (lockedSeedingFinalized && transferableAfter[tokenId_] != 0) {
                uint256 _ta = transferableAfter[tokenId_];
                bool _isForfeitable = forfeitable[tokenId_];

                // Old flags: position was in subcurves if it had active locked data
                // AND was still within the non-transferability window at the old state.
                // We use the old lock's end to determine if the position was previously tracked.
                if (oldLocked_.end > 0 && oldLocked_.amount > 0 && _ta > block.timestamp) {
                    _curveFlags |= _isForfeitable ? 2 : 1; // old flags in low nibble
                }
                // New flags: position is currently in subcurves if transferableAfter > now
                if (_ta > block.timestamp) {
                    _curveFlags |= (_isForfeitable ? 2 : 1) << 4; // new flags in high nibble
                }

                // Subcurve-specific biases use min(lock.end, transferableAfter) as effective end.
                // This handles the case where a user extended their lock past transferableAfter.
                if (oldLocked_.end > block.timestamp && oldLocked_.amount > 0 && _ta > block.timestamp) {
                    uint256 _oldEffEnd = oldLocked_.end < _ta ? oldLocked_.end : _ta;
                    _oldSubcurveBias = _oldUserPoint.slope * (_oldEffEnd - block.timestamp).toInt256().toInt128();
                }
                if (newLocked_.end > block.timestamp && newLocked_.amount > 0 && _ta > block.timestamp) {
                    uint256 _newEffEnd = newLocked_.end < _ta ? newLocked_.end : _ta;
                    _newSubcurveBias = _newUserPoint.slope * (_newEffEnd - block.timestamp).toInt256().toInt128();
                }
            }
        }

        Point memory _lastPoint = Point({
            bias: 0,
            slope: 0,
            timestamp: block.timestamp.toUint64(),
            blockNumber: block.number.toUint64(),
            amount: 0,
            fixedBias: 0
        });

        // --- Phases B + C + epoch write ---
        // _epoch and subcurve points scoped here to manage stack depth.
        uint256 _writtenEpoch;
        {
            uint256 _epoch = epoch;
            if (_epoch > 0) {
                _lastPoint = globalPointHistory[_epoch];
            }

            // V2: Load locked + forfeitable points (only after seeding is finalized)
            LockedPoint memory _lastLockedPoint;
            LockedPoint memory _lastForfeitablePoint;
            if (_epoch > 0 && lockedSeedingFinalized) {
                _lastLockedPoint = lockedGlobalPointHistory[_epoch];
                _lastForfeitablePoint = forfeitableGlobalPointHistory[_epoch];
            }

            // --- Phase B: Catchup loop — fill history at SIX_DAYS boundaries ---
            {
                uint256 _lastCheckpoint = _lastPoint.timestamp;
                Point memory _initialLastPoint = Point({
                    bias: _lastPoint.bias,
                    slope: _lastPoint.slope,
                    timestamp: _lastPoint.timestamp,
                    blockNumber: _lastPoint.blockNumber,
                    amount: _lastPoint.amount,
                    fixedBias: 0
                });
                uint256 _blockSlope;
                if (block.timestamp > _lastPoint.timestamp) {
                    _blockSlope =
                        (MULTIPLIER * (block.number - _lastPoint.blockNumber)) /
                        (block.timestamp - _lastPoint.timestamp);
                }

                uint256 t_i = (_lastCheckpoint / SIX_DAYS) * SIX_DAYS;
                for (uint256 i; i < 300; ++i) {
                    t_i += SIX_DAYS;
                    int128 d_slope;
                    bool _atBoundary = (t_i <= block.timestamp);
                    if (!_atBoundary) {
                        t_i = block.timestamp;
                    } else {
                        d_slope = slopeChanges[t_i];
                    }

                    // Global curve decay
                    int128 _dt = (t_i - _lastCheckpoint).toInt256().toInt128();
                    _lastPoint.bias -= _lastPoint.slope * _dt;
                    _lastPoint.slope += d_slope;
                    if (_lastPoint.bias < 0) {
                        _lastPoint.bias = 0;
                    }
                    if (_lastPoint.slope < 0) {
                        _lastPoint.slope = 0;
                    }

                    // V2: Locked + forfeitable curve decay (parallel tracking)
                    // Slope changes read inline (no temp vars) to avoid stack-too-deep.
                    if (lockedSeedingFinalized) {
                        _lastLockedPoint.bias -= _lastLockedPoint.slope * _dt;
                        if (_atBoundary) _lastLockedPoint.slope += lockedSlopeChanges[t_i];
                        if (_lastLockedPoint.bias < 0) _lastLockedPoint.bias = 0;
                        if (_lastLockedPoint.slope < 0) _lastLockedPoint.slope = 0;
                        _lastLockedPoint.timestamp = t_i.toUint64();

                        _lastForfeitablePoint.bias -= _lastForfeitablePoint.slope * _dt;
                        if (_atBoundary) _lastForfeitablePoint.slope += forfeitableSlopeChanges[t_i];
                        if (_lastForfeitablePoint.bias < 0) _lastForfeitablePoint.bias = 0;
                        if (_lastForfeitablePoint.slope < 0) _lastForfeitablePoint.slope = 0;
                        _lastForfeitablePoint.timestamp = t_i.toUint64();
                    }

                    _lastCheckpoint = t_i;
                    _lastPoint.timestamp = t_i.toUint64();
                    _lastPoint.blockNumber = (_initialLastPoint.blockNumber +
                        (_blockSlope * (t_i - _initialLastPoint.timestamp)) /
                        MULTIPLIER).toUint64();
                    _epoch += 1;
                    if (t_i == block.timestamp) {
                        _lastPoint.blockNumber = block.number.toUint64();
                        if (lockedSeedingFinalized) {
                            _lastLockedPoint.blockNumber = block.number.toUint64();
                            _lastForfeitablePoint.blockNumber = block.number.toUint64();
                        }
                        break;
                    } else {
                        globalPointHistory[_epoch] = _lastPoint;
                        if (lockedSeedingFinalized) {
                            _lastLockedPoint.blockNumber = _lastPoint.blockNumber;
                            lockedGlobalPointHistory[_epoch] = _lastLockedPoint;
                            _lastForfeitablePoint.blockNumber = _lastPoint.blockNumber;
                            forfeitableGlobalPointHistory[_epoch] = _lastForfeitablePoint;
                        }
                    }
                }
            }

            // --- Phase C: Apply user delta to global + locked + forfeitable points ---
            // V2: Subcurve deltas use separate old/new flags and subcurve-specific biases.
            //     oldFlags (low nibble of _curveFlags): determines removal from subcurves
            //     newFlags (high nibble of _curveFlags): determines addition to subcurves
            //     Subcurve biases use min(lock.end, transferableAfter) as effective end.
            if (tokenId_ != 0) {
                _lastPoint.slope += (_newUserPoint.slope - _oldUserPoint.slope);
                _lastPoint.bias += (_newUserPoint.bias - _oldUserPoint.bias);
                if (_lastPoint.slope < 0) {
                    _lastPoint.slope = 0;
                }
                if (_lastPoint.bias < 0) {
                    _lastPoint.bias = 0;
                }

                // V2: Locked curve — apply old removal + new addition separately
                uint8 _oldFlags = _curveFlags & 0x0F;
                uint8 _newFlags = (_curveFlags >> 4) & 0x0F;
                if (_oldFlags >= 1 || _newFlags >= 1) {
                    // Slope delta is same as global (slope = amount/MAX_TIME, independent of end)
                    // Bias delta uses subcurve-specific values (bounded by transferableAfter)
                    int128 _slopeDelta;
                    if (_newFlags >= 1) _slopeDelta += _newUserPoint.slope;
                    if (_oldFlags >= 1) _slopeDelta -= _oldUserPoint.slope;
                    _lastLockedPoint.slope += _slopeDelta;
                    _lastLockedPoint.bias += (_newSubcurveBias - _oldSubcurveBias);
                    if (_lastLockedPoint.slope < 0) _lastLockedPoint.slope = 0;
                    if (_lastLockedPoint.bias < 0) _lastLockedPoint.bias = 0;

                    // Forfeitable curve — same logic, only for flags == 2
                    if (_oldFlags == 2 || _newFlags == 2) {
                        int128 _forfSlopeDelta;
                        if (_newFlags == 2) _forfSlopeDelta += _newUserPoint.slope;
                        if (_oldFlags == 2) _forfSlopeDelta -= _oldUserPoint.slope;
                        _lastForfeitablePoint.slope += _forfSlopeDelta;
                        _lastForfeitablePoint.bias += (_newSubcurveBias - _oldSubcurveBias);
                        if (_lastForfeitablePoint.slope < 0) _lastForfeitablePoint.slope = 0;
                        if (_lastForfeitablePoint.bias < 0) _lastForfeitablePoint.bias = 0;
                    }
                }
            }

            // Write global + locked + forfeitable points (same overwrite-vs-append logic)
            if (_epoch != 1 && globalPointHistory[_epoch - 1].timestamp == block.timestamp) {
                _writtenEpoch = _epoch - 1;
                globalPointHistory[_writtenEpoch] = _lastPoint;
                if (lockedSeedingFinalized) {
                    lockedGlobalPointHistory[_writtenEpoch] = _lastLockedPoint;
                    forfeitableGlobalPointHistory[_writtenEpoch] = _lastForfeitablePoint;
                }
            } else {
                _writtenEpoch = _epoch;
                epoch = _epoch;
                globalPointHistory[_epoch] = _lastPoint;
                if (lockedSeedingFinalized) {
                    lockedGlobalPointHistory[_epoch] = _lastLockedPoint;
                    forfeitableGlobalPointHistory[_epoch] = _lastForfeitablePoint;
                }
            }
        }

        // --- Phase D: Schedule slope changes + write user point ---
        if (tokenId_ != 0) {
            _scheduleSlopeChanges(tokenId_, oldLocked_, newLocked_, _oldUserPoint, _newUserPoint, _curveFlags);

            _newUserPoint.timestamp = block.timestamp.toUint64();
            _newUserPoint.blockNumber = block.number.toUint64();
            _newUserPoint.amount = locked[tokenId_].amount.toUint256().toUint128();
            uint256 _userEpoch = userPointEpoch[tokenId_];
            if (
                _userEpoch == 0 ||
                userPointHistory[tokenId_][_userEpoch].point.timestamp != block.timestamp
            ) {
                userPointEpoch[tokenId_] = ++_userEpoch;
            }

            userPointHistory[tokenId_][_userEpoch].point = _newUserPoint;
            userPointHistory[tokenId_][_userEpoch].owner = _ownerOf(tokenId_);
        }
        emit Checkpoint(_writtenEpoch, tokenId_, oldLocked_, newLocked_);
    }

    /**
     * @dev Schedules slope changes for global, locked, and forfeitable curves.
     *      Extracted from _checkpoint to manage stack depth (Phase D).
     *
     *      V2: For subcurves, the effective endpoint is min(lock.end, transferableAfter).
     *      This handles the case where a user extends their lock past the transferability
     *      window — the subcurve slope change fires at transferableAfter (when the position
     *      exits the subcurve), not at lock.end.
     *
     *      Flag encoding (per nibble): 0 = transferable (global only, no subcurves),
     *                                  1 = non-transferable (global + locked subcurve),
     *                                  2 = non-transferable + forfeitable (all three curves).
     *      The packing uses: `[newFlags:4..7][oldFlags:0..3]`. Old flags describe what
     *      subcurves the position WAS tracked in (what to unwind); new flags describe
     *      what subcurves it is tracked in NOW (what to apply). The transitions are
     *      monotonically non-increasing over a position's lifetime:
     *        - 2 (forfeitable) → 1 (non-transferable) via `forfeit`
     *        - 1 or 2 → 0 when `block.timestamp >= transferableAfter` (subcurve exit,
     *          global weight retained until lock.end)
     *
     * @param curveFlags_ Packed old/new flags: [newFlags:4..7][oldFlags:0..3]
     */
    function _scheduleSlopeChanges(
        uint256 tokenId_,
        LockedBalance memory oldLocked_,
        LockedBalance memory newLocked_,
        Point memory _oldUserPoint,
        Point memory _newUserPoint,
        uint8 curveFlags_
    ) internal {
        uint8 _oldFlags = curveFlags_ & 0x0F;
        uint8 _newFlags = (curveFlags_ >> 4) & 0x0F;

        // --- Global slope changes (use lock.end directly) ---
        int128 _oldDslope = slopeChanges[oldLocked_.end];
        int128 _newDslope;
        if (newLocked_.end != 0) {
            if (newLocked_.end == oldLocked_.end) {
                _newDslope = _oldDslope;
            } else {
                _newDslope = slopeChanges[newLocked_.end];
            }
        }

        if (oldLocked_.end > block.timestamp) {
            _oldDslope += _oldUserPoint.slope;
            if (newLocked_.end == oldLocked_.end) {
                _oldDslope -= _newUserPoint.slope;
            }
            slopeChanges[oldLocked_.end] = _oldDslope;
        }

        if (newLocked_.end > block.timestamp && newLocked_.end > oldLocked_.end) {
            _newDslope -= _newUserPoint.slope;
            slopeChanges[newLocked_.end] = _newDslope;
        }

        // --- Subcurve slope changes (use min(lock.end, transferableAfter) as effective end) ---
        if (_oldFlags >= 1 || _newFlags >= 1) {
            uint256 _ta = transferableAfter[tokenId_];
            // Effective ends for subcurves: bounded by transferableAfter
            uint256 _oldSubEnd = (oldLocked_.end != 0 && _ta < oldLocked_.end) ? _ta : oldLocked_.end;
            uint256 _newSubEnd = (newLocked_.end != 0 && _ta < newLocked_.end) ? _ta : newLocked_.end;

            _scheduleSubcurveSlopeChanges(
                _oldFlags, _newFlags, _oldSubEnd, _newSubEnd,
                _oldUserPoint.slope, _newUserPoint.slope
            );
        }
    }

    /**
     * @dev Schedules locked + forfeitable slope changes at subcurve-specific endpoints.
     *      Separated to manage stack depth.
     */
    function _scheduleSubcurveSlopeChanges(
        uint8 oldFlags_,
        uint8 newFlags_,
        uint256 oldSubEnd_,
        uint256 newSubEnd_,
        int128 oldSlope_,
        int128 newSlope_
    ) internal {
        // --- Locked curve slope changes ---
        if (oldFlags_ >= 1 && oldSubEnd_ > block.timestamp) {
            int128 _oldLockedDslope = lockedSlopeChanges[oldSubEnd_];
            _oldLockedDslope += oldSlope_;
            if (newFlags_ >= 1 && newSubEnd_ == oldSubEnd_) {
                _oldLockedDslope -= newSlope_;
            }
            lockedSlopeChanges[oldSubEnd_] = _oldLockedDslope;
        }

        if (newFlags_ >= 1 && newSubEnd_ > block.timestamp && newSubEnd_ > oldSubEnd_) {
            int128 _newLockedDslope = lockedSlopeChanges[newSubEnd_];
            _newLockedDslope -= newSlope_;
            lockedSlopeChanges[newSubEnd_] = _newLockedDslope;
        }

        // --- Forfeitable curve slope changes (same logic, only for flags == 2) ---
        if (oldFlags_ == 2 && oldSubEnd_ > block.timestamp) {
            int128 _oldForfDslope = forfeitableSlopeChanges[oldSubEnd_];
            _oldForfDslope += oldSlope_;
            if (newFlags_ == 2 && newSubEnd_ == oldSubEnd_) {
                _oldForfDslope -= newSlope_;
            }
            forfeitableSlopeChanges[oldSubEnd_] = _oldForfDslope;
        }

        if (newFlags_ == 2 && newSubEnd_ > block.timestamp && newSubEnd_ > oldSubEnd_) {
            int128 _newForfDslope = forfeitableSlopeChanges[newSubEnd_];
            _newForfDslope -= newSlope_;
            forfeitableSlopeChanges[newSubEnd_] = _newForfDslope;
        }
    }

    /**
     * @dev Internal lock creation: validates params, mints NFT, sets transferableAfter/forfeitable
     *      BEFORE _depositFor (so _checkpoint can read them for subcurve membership), then deposits.
     *      Implicit invariant: forfeitable positions are always non-transferable (transferableAfter != 0).
     */
    function _createLock(
        uint256 amount_,
        uint256 lockDuration_,
        address account_,
        bool transferable_,
        bool forfeitable_
    ) internal returns (uint256 _tokenId) {
        if (lockDuration_ < 2 * SIX_DAYS) revert LockDurationTooShort();
        uint256 unlockTime = ((block.timestamp + lockDuration_) / SIX_DAYS) * SIX_DAYS; // Lock time is rounded down to SIX_DAYS

        if (amount_ == 0) revert AmountIsZero();
        if (amount_ < MIN_LOCK_AMOUNT) revert AmountTooSmall();
        if (unlockTime <= block.timestamp) revert LockDurationTooShort();
        if (unlockTime > block.timestamp + MAX_TIME) revert LockDurationTooLong();
        // A position cannot be both transferable and forfeitable: transferable positions
        // have transferableAfter == 0, which causes forfeit() to always revert with
        // ForfeitWindowExpired (block.timestamp >= 0 is always true).
        if (transferable_ && forfeitable_) revert InvalidConfiguration();

        _requireSeedingNotActiveForNonTransferable(!transferable_);

        _tokenId = nextTokenId++;
        _mint(account_, _tokenId);

        // V2: Set transferableAfter and forfeitable BEFORE _depositFor so that
        // _checkpoint can read them to determine locked/forfeitable curve membership.
        if (!transferable_) {
            transferableAfter[_tokenId] = unlockTime;
        }
        if (forfeitable_) forfeitable[_tokenId] = true;

        _depositFor(_tokenId, amount_, unlockTime.toUint64(), locked[_tokenId]);

        _delegate(_tokenId, _resolveAutoDelegate(account_));

        address _sender = _msgSender();

        provider[_tokenId] = _sender;

        emit Lock(
            _sender,
            account_,
            _tokenId,
            amount_,
            block.timestamp,
            lockDuration_,
            0,
            transferable_,
            forfeitable_
        );

        return _tokenId;
    }

    /**
     * @dev Internal deposit: pulls HEMI (if amount > 0), updates lock, checkpoints, re-delegates.
     *      Token transfer happens BEFORE state update (CEI for pull patterns: receiving tokens
     *      before updating books is correct; the nonReentrant modifier on all callers prevents
     *      re-entry during the pre-effects external call).
     */
    function _depositFor(
        uint256 tokenId_,
        uint256 amount_,
        uint64 unlockTime_,
        LockedBalance memory oldLocked_
    ) internal {
        _updateReward(tokenId_);

        // Pull tokens FIRST (CEI for pull patterns: interaction before effects
        // is correct when receiving tokens, not sending them).
        address from = _msgSender();
        if (amount_ != 0) {
            HEMI.safeTransferFrom(from, address(this), amount_);
        }

        totalLocked += amount_;

        // Set newLocked to _oldLocked without mangling memory
        LockedBalance memory _newLocked;
        (_newLocked.amount, _newLocked.end) = (oldLocked_.amount, oldLocked_.end);

        // Adding to existing lock, or if a lock is expired - creating a new one
        _newLocked.amount += amount_.toInt256().toInt128();
        if (unlockTime_ != 0) {
            _newLocked.end = unlockTime_;
        }
        locked[tokenId_] = _newLocked;

        // Possibilities:
        // Both _oldLocked.end could be current or expired (>/< block.timestamp)
        // value == 0 (extend lock) or value > 0 (add to lock or extend lock)
        // newLocked.end > block.timestamp (always)
        _checkpoint(tokenId_, oldLocked_, _newLocked);

        _reDelegate(tokenId_);
        emit Deposit(from, tokenId_, amount_, _newLocked.end, block.timestamp);
    }

    /// @dev Wrapped in try/catch so a broken voteDelegation contract cannot block
    ///      critical operations (deposit, transfer). The owner can replace
    ///      voteDelegation via updateVoteDelegation() to restore delegation.
    function _reDelegate(uint256 delegator_) internal virtual {
        try voteDelegation.delegation(delegator_) returns (
            IVeHemiVoteDelegation.Delegation memory d
        ) {
            if (d.delegatee != address(0)) {
                _delegate(delegator_, d.delegatee);
            }
        } catch {
            emit DelegationUpdateFailed(delegator_);
        }
    }

    /// @dev Revert with SeedingInProgress if the seeding window is open AND the
    ///      caller's operation targets a non-transferable position (the only
    ///      class whose state is reflected in the in-progress accumulator).
    function _requireSeedingNotActiveForNonTransferable(bool isNonTransferable) internal view {
        if (isNonTransferable && seedingStarted && !lockedSeedingFinalized) {
            revert SeedingInProgress();
        }
    }

    /// @dev Shared precondition for `seedBatch` and `finalizeSeeding`.
    ///      Factored so the two SLOADs and two reverts contribute their
    ///      bytecode once.
    ///
    ///      The seeding window spans arbitrarily many blocks, gated only by
    ///      the `seedingStarted` latch and the `!lockedSeedingFinalized`
    ///      invariant. Cross-block correctness rests on three immutability
    ///      properties holding for every seeded position throughout the
    ///      window:
    ///        * `_createLock` rejects new non-transferable mints
    ///          (`_requireSeedingNotActiveForNonTransferable(!transferable_)`),
    ///        * `forfeit` / `increaseAmount` / `increaseUnlockTime` reject
    ///          mutations on non-transferable positions (same guard at each
    ///          entry point),
    ///        * `withdraw` is harmless: by the time a non-transferable
    ///          position becomes withdrawable, `block.timestamp >= lock.end
    ///          >= subEnd`, so its seeded bias has already decayed to zero
    ///          via the `lockedSlopeChanges[subEnd]` write — the seeded
    ///          totals are insensitive to mid-window withdraws.
    ///      `transferableAfter[id]` is set once at mint and never updated,
    ///      so `(slope, subEnd)` is immutable for every scanned id between
    ///      its `seedBatch` and `finalizeSeeding`. The time-independent
    ///      accumulators (slope·subEnd, slope) therefore remain valid
    ///      regardless of how many blocks the scan spans, and the curve
    ///      materialized at finalize time is `Σ slope·(subEnd − tsFinalize)`
    ///      — identical to a single-block execution at `tsFinalize`.
    ///
    ///      Check order is UX-driven (revert clarity):
    ///        1. `lockedSeedingFinalized` first — `SeedingAlreadyFinalized`
    ///           is the most informative error when an operator calls the
    ///           batched entrypoints after the flow has completed.
    ///        2. `!seedingStarted` second — fires when the batched
    ///           entrypoints are called before `markSeedingStarted`.
    ///
    ///      The state `(finalized=true, started=false)` is unreachable:
    ///      `finalizeSeeding` calls this function first (so latch-flip
    ///      requires `seedingStarted = true`), and neither flag is ever
    ///      cleared. The order therefore matters only for revert clarity.
    function _requireSeedingActive() internal view {
        if (lockedSeedingFinalized) revert SeedingAlreadyFinalized();
        if (!seedingStarted) revert SeedingNotStarted();
    }

    /// @dev Returns the auto-delegate target for an account, or the account itself
    ///      if no auto-delegate is set. try/catch ensures backwards compatibility
    ///      if voteDelegation hasn't been upgraded to support autoDelegate yet.
    function _resolveAutoDelegate(address account_) internal view returns (address) {
        try voteDelegation.autoDelegate(account_) returns (address result) {
            if (result != address(0)) return result;
        } catch {}
        return account_;
    }

    /// @dev Wrapped in try/catch so a broken `voteDelegation` contract can
    ///      never block lock lifecycle operations.
    /// @dev The near-expiry skip below applies only to NEW delegations
    ///      (a checkpoint that takes effect AFTER the lock ends is
    ///      useless). The `delegatee_ == address(0)` carve-out routes
    ///      forfeit/withdraw cleanup calls through unconditionally;
    ///      `VeHemiVoteDelegation._delegate` handles `delegatee_ == 0`
    ///      expiry-tolerantly so cleanup always succeeds, even after
    ///      `lock.end` has passed.
    /// @dev The `1 hours` literal below MUST stay in sync with
    ///      `VeHemiVoteDelegation.CHECKPOINT_INTERVAL` and `EPOCH_OFFSET=0`
    ///      so the outer guard threshold matches the inner
    ///      `_checkpointTimestamp` formula. If either constant changes in
    ///      `VeHemiVoteDelegation`, update this expression in lock-step.
    function _delegate(uint256 delegator_, address delegatee_) internal {
        // Delegation changes take effect at the next hourly epoch boundary.
        // If the lock ends before that boundary the new delegation would
        // never take effect, so the call is skipped — except when
        // `delegatee_ == address(0)`, which is the forfeit/withdraw cleanup
        // path: it must always run so `delegations[tokenId]` is cleared even
        // when the lock is at or past expiry.
        uint256 _newDelegationStarts = ((block.timestamp / 1 hours) * 1 hours) + 1 hours;
        if (delegatee_ == address(0) || _newDelegationStarts < locked[delegator_].end) {
            try voteDelegation.delegate(delegator_, delegatee_) {} catch {
                emit DelegationUpdateFailed(delegator_);
            }
        }
    }

    // =========================================================================
    // V2: Non-transferrable position weight tracking
    // =========================================================================

    /**
     * @notice Open the seeding window and freeze the seeding range. Subsequent
     *         `seedBatch` calls iterate token IDs in `[1, seedingTargetId)`.
     *         While the window is open and `lockedSeedingFinalized` is false,
     *         `_createLock` rejects new non-transferable positions — without
     *         that guard a permissionless mint could extend `nextTokenId` past
     *         the snapshotted range and the new position would be silently
     *         dropped from the seeded set.
     *
     *         Idempotent against accidental re-call: reverts with
     *         `SeedingAlreadyStarted` once invoked. The `seedingStarted`
     *         latch is monotonic and never cleared, so the same revert
     *         fires after finalization too.
     *
     * @dev    Owner-only because the call snapshots `nextTokenId` into
     *         `seedingTargetId` (the scan upper bound). Once open the
     *         window stays open across blocks until `finalizeSeeding`
     *         completes the scan. While the window is open:
     *           - new non-transferable mints are blocked (`_createLock`),
     *           - non-transferable mutations are blocked (`forfeit`,
     *             `increaseAmount`, `increaseUnlockTime`),
     *           - `seedBatch(...)` and `finalizeSeeding()` are
     *             permissionless so any keeper / community caller can
     *             advance the cursor and finalize once the cursor reaches
     *             the target.
     *
     *         The `seedingStarted` latch is monotonic with no on-chain
     *         reset. The window closes exclusively when `finalizeSeeding`
     *         flips `lockedSeedingFinalized`, which itself requires the
     *         cursor to have reached `seedingTargetId - 1`. If the window
     *         is opened but never finalized, non-transferable mints stay
     *         blocked until an implementation upgrade clears the state;
     *         transferable mints and existing positions are unaffected.
     */
    function markSeedingStarted() external onlyOwner {
        if (seedingStarted) revert SeedingAlreadyStarted();
        seedingStarted = true;
        // `seedingStartedAt` is informational only; it records when the
        // window opened so off-chain monitors can observe progress. The
        // implicit narrowing of `block.timestamp` to uint64 is safe (uint64
        // covers ~584 billion years past the unix epoch).
        seedingStartedAt = uint64(block.timestamp);
        seedingTargetId = nextTokenId;
        emit SeedingStarted(nextTokenId);
    }

    /**
     * @notice Last token ID processed by `seedBatch`. Exposes the otherwise
     *         internal `_seedingProgress.lastProcessedId` so off-chain
     *         drivers (e.g., `scripts/run-seeding-loop.ts`) can detect
     *         cursor completion without depending on a private storage
     *         slot index.
     * @return The most recently processed token ID, or 0 if no batches
     *         have run yet.
     */
    function seedingCursor() external view returns (uint256) {
        return _seedingProgress.lastProcessedId;
    }

    /**
     * @notice Iterate up to `maxIterations` token IDs forward from the last
     *         processed cursor, accumulating slope/bias deltas for
     *         non-transferable positions and writing the matching
     *         slope-change entries on each subcurve.
     * @dev Permissionless: any caller may advance the cursor. The
     *      per-iteration math is a deterministic read of
     *      `(locked[id], transferableAfter[id], forfeitable[id])`; those
     *      values are immutable for non-transferable positions while the
     *      window is open, so totals accumulated across many callers and
     *      many blocks are identical to a hypothetical single-block scan.
     *      The latch only flips once the cursor reaches the target, so
     *      permissionless advancement cannot prematurely finalize an
     *      incomplete seed.
     *
     *      Each accepted position contributes:
     *        * `slope = lock.amount / MAX_TIME`
     *        * `bias += slope * subEnd` (time-independent; the bias-at-T
     *          is derived in `finalizeSeeding`)
     *        * `lockedSlopeChanges[subEnd] -= slope`
     *        * if `forfeitable[id]`: same accumulation against the
     *          forfeitable subcurve totals + `forfeitableSlopeChanges`.
     *
     *      Burned, transferable, expired, and already-mature positions are
     *      silently skipped. Slope-change writes during batches are
     *      invisible to `_checkpoint` because `lockedSeedingFinalized` is
     *      still false (the global epoch advance happens once, inside
     *      `finalizeSeeding`).
     *
     *      `maxIterations` has no upper bound: the caller picks the chunk
     *      size that fits the block gas limit, and the cursor is clamped
     *      to `seedingTargetId` so a generous value harmlessly converges.
     * @param maxIterations Maximum number of token IDs to scan in this call.
     */
    function seedBatch(uint256 maxIterations) external {
        _requireSeedingActive();

        SeedingProgress storage progress = _seedingProgress;
        uint256 startId = progress.lastProcessedId == 0 ? 1 : progress.lastProcessedId + 1;
        // Cursor at the end — no-op convergence. Callers can monitor
        // progress via the `seedingCursor()` view; `finalizeSeeding`
        // reverts `SeedingIncomplete(lastProcessedId, expectedEnd)` on an
        // unfinished scan, the practical end-of-flow signal.
        if (startId >= seedingTargetId) return;
        // Compute endIdExclusive without overflowing when callers pass
        // type(uint256).max as maxIterations. Clamp BEFORE the add.
        uint256 remaining = seedingTargetId - startId;
        uint256 step = maxIterations < remaining ? maxIterations : remaining;
        uint256 endIdExclusive = startId + step;

        // Accumulate per-batch in stack-locals to avoid one SSTORE per token.
        int128 batchSlope;
        int128 batchBias;
        int128 batchForfSlope;
        int128 batchForfBias;
        uint256 batchCount;
        // Earliest subEnd seen in this batch (used by finalizeSeeding to
        // detect and repair phantom carry — see _materializeFromAccumulator).
        // Sentinel 0 = "no positions included yet"; valid subEnds are always > 0.
        uint64 batchMinSubEnd;

        // IMPORTANT — skip-condition coupling: the same filter is duplicated
        // in `test/Invariant.t.sol` (`invariant_nonTransferableEqualsPerPositionSum`
        // and `invariant_forfeitableEqualsPerPositionSum`). Any change to the
        // skip predicates below (e.g., a future V3 slash-skip) MUST be
        // mirrored in both invariant reconstructions, otherwise both sides
        // diverge by the same amount and the invariant becomes a tautology.
        for (uint256 id = startId; id < endIdExclusive; ++id) {
            if (_ownerOf(id) == address(0)) continue;
            uint256 _ta = transferableAfter[id];
            // Skip transferable positions (transferableAfter == 0) and
            // positions whose transferability window has already opened
            // (no subcurve membership).
            if (_ta == 0 || _ta <= block.timestamp) continue;
            LockedBalance memory _lock = locked[id];
            if (_lock.amount <= 0 || _lock.end <= block.timestamp) continue;

            int128 slope = _lock.amount / MAX_TIME.toInt256().toInt128();
            uint256 _subEnd = _lock.end < _ta ? _lock.end : _ta;
            int128 _subEndI = uint256(_subEnd).toInt256().toInt128();

            batchSlope += slope;
            batchBias += slope * _subEndI;
            lockedSlopeChanges[_subEnd] -= slope;
            unchecked {
                ++batchCount;
            }

            if (forfeitable[id]) {
                batchForfSlope += slope;
                batchForfBias += slope * _subEndI;
                forfeitableSlopeChanges[_subEnd] -= slope;
            }

            // Track earliest subEnd across INCLUDED positions only. Placed
            // after the four skip predicates so filtered ids don't influence
            // the walk-back starting point at finalize.
            uint64 _subEnd64 = uint64(_subEnd);
            if (batchMinSubEnd == 0 || _subEnd64 < batchMinSubEnd) {
                batchMinSubEnd = _subEnd64;
            }
        }

        // Flush batch into the persistent accumulator.
        progress.lastProcessedId = endIdExclusive - 1;
        progress.totalSlope += batchSlope;
        progress.totalBias += batchBias;
        progress.totalForfeitableSlope += batchForfSlope;
        progress.totalForfeitableBias += batchForfBias;
        progress.count += batchCount;

        // Merge batch min into persistent min. Compare-and-swap pattern so
        // calls across many blocks/keepers converge to the global minimum.
        if (batchMinSubEnd != 0) {
            uint64 _existingMin = progress.minSubEnd;
            if (_existingMin == 0 || batchMinSubEnd < _existingMin) {
                progress.minSubEnd = batchMinSubEnd;
            }
        }
    }

    /**
     * @notice Materialize the accumulated totals into the locked +
     *         forfeitable `SupplyPoint`s and flip the seeding latch.
     *         Requires `seedBatch` to have advanced the cursor all the way
     *         to `seedingTargetId - 1`; an incomplete cursor reverts with
     *         `SeedingIncomplete` so the caller can finish the scan before
     *         finalizing.
     * @dev Permissionless: any caller may finalize once the cursor reaches
     *      `seedingTargetId - 1`. This is the "latch only unlatches at max
     *      position" property — `finalizeSeeding` reverts on an incomplete
     *      cursor, so an attacker cannot prematurely flip
     *      `lockedSeedingFinalized` regardless of caller identity. Once the
     *      cursor is complete, the resulting `LockedPoint` values are a
     *      deterministic function of the accumulator state and
     *      `block.timestamp` — identical no matter who calls.
     *
     *      Materialization advances the global epoch with `_checkpoint(0, …)`
     *      (subcurve logic stays skipped because `lockedSeedingFinalized` is
     *      still false at this point), writes both `LockedPoint`s at
     *      `block.timestamp`, flips the latch, and clears the accumulator.
     *      The aggregate math is identical regardless of how many
     *      `seedBatch` calls produced the totals or which blocks they
     *      spanned.
     *
     *      OPERATIONAL CONSTRAINT — finalize promptly. The materialized
     *      LockedPoint uses `bias = totalBias - totalSlope * tsFinal`. If
     *      `tsFinal >= subEnd` for any seeded position, that position
     *      contributes a negative term to the bias AND its slope change at
     *      `subEnd` has already been written by `seedBatch` — the
     *      post-finalize supply walk will not revisit that bucket, so the
     *      position is carried in the subcurve past its true subEnd.
     *      `_createLock` enforces `lockDuration_ >= 2 * SIX_DAYS`, and the
     *      `unlockTime = ((block.timestamp + lockDuration_) / SIX_DAYS) *
     *      SIX_DAYS` truncation can drop at most one SIX_DAYS bucket — so
     *      the worst-case floor for newly-minted positions is
     *      `subEnd >= mintTime + SIX_DAYS ≈ 6 days` (one bucket); the
     *      typical case is closer to two buckets (~12 days). Older
     *      positions consume part of that margin as they age, so the
     *      load-bearing margin at `markSeedingStarted` time is
     *      `min(subEnd) - now` across all live non-transferable
     *      positions. Realistic seeding windows at Hemi mainnet scale
     *      (~30K total IDs, ~3 Hemi blocks ≈ 36s end-to-end) are orders
     *      of magnitude shorter than any plausible margin. Operators
     *      MUST drive the multi-block flow to completion within hours of
     *      opening the window — not days — and SHOULD verify off-chain
     *      that no live non-transferable position has `subEnd` within
     *      the planned seeding window before calling
     *      `markSeedingStarted`.
     */
    function finalizeSeeding() external {
        _requireSeedingActive();

        SeedingProgress storage progress = _seedingProgress;
        // seedingTargetId is the EXCLUSIVE upper bound of the scan, so the
        // last scannable ID is seedingTargetId - 1. If seedingTargetId is 1
        // (i.e., markSeedingStarted ran before any mint), there is nothing
        // to scan and the cursor stays at 0 — that's still "complete".
        uint256 expectedEnd = seedingTargetId == 0 ? 0 : seedingTargetId - 1;
        if (progress.lastProcessedId < expectedEnd) {
            revert SeedingIncomplete(progress.lastProcessedId, expectedEnd);
        }

        // Snapshot totals before clearing the accumulator. SLOADs are
        // cheaper than re-deriving from per-position data.
        int128 _totalSlope = progress.totalSlope;
        int128 _totalBias = progress.totalBias;
        int128 _totalForfeitableSlope = progress.totalForfeitableSlope;
        int128 _totalForfeitableBias = progress.totalForfeitableBias;
        uint64 _minSubEnd = progress.minSubEnd;

        // Advance the global epoch to block.timestamp. Subcurve logic in
        // `_checkpoint` remains gated on `lockedSeedingFinalized`, which is
        // still false here, so the slope-change entries written by the
        // batches are invisible to the catchup walk.
        _checkpoint(0, LockedBalance(0, 0), LockedBalance(0, 0));

        uint256 _epoch = epoch;

        int128 _lockedBias;
        int128 _lockedSlope;
        int128 _forfeitableBias;
        int128 _forfeitableSlope;

        // Phantom-carry mitigation: if any seeded position's subEnd lapsed
        // during the seeding window (minSubEnd < block.timestamp), the
        // seedBatch-written slope-changes at those past buckets would be
        // stranded — the post-finalize forward walk only steps from tsFinal
        // onward and never revisits past buckets. Instead, materialize the
        // LockedPoints by walking from minSubEnd forward to block.timestamp
        // and consuming the stranded slope-changes along the way. On the
        // happy path (minSubEnd == 0 means nothing seeded, or minSubEnd >=
        // block.timestamp means every seeded position is still in its
        // non-transferable window) the direct formula is exact and the
        // walk is skipped.
        if (_minSubEnd == 0 || _minSubEnd >= block.timestamp) {
            int128 _tsInt = uint256(block.timestamp).toInt256().toInt128();
            _lockedBias = _totalBias - _totalSlope * _tsInt;
            _lockedSlope = _totalSlope;
            _forfeitableBias = _totalForfeitableBias - _totalForfeitableSlope * _tsInt;
            _forfeitableSlope = _totalForfeitableSlope;
        } else {
            (_lockedBias, _lockedSlope) = _materializeFromAccumulator(
                _totalBias,
                _totalSlope,
                uint256(_minSubEnd),
                block.timestamp,
                false
            );
            (_forfeitableBias, _forfeitableSlope) = _materializeFromAccumulator(
                _totalForfeitableBias,
                _totalForfeitableSlope,
                uint256(_minSubEnd),
                block.timestamp,
                true
            );
        }

        if (_lockedBias < 0) _lockedBias = 0;
        if (_forfeitableBias < 0) _forfeitableBias = 0;

        lockedGlobalPointHistory[_epoch] = LockedPoint({
            bias: _lockedBias,
            slope: _lockedSlope,
            timestamp: block.timestamp.toUint64(),
            blockNumber: block.number.toUint64()
        });

        // Forfeitable point: always write (even if zero) so timestamp != 0 for view functions.
        forfeitableGlobalPointHistory[_epoch] = LockedPoint({
            bias: _forfeitableBias,
            slope: _forfeitableSlope,
            timestamp: block.timestamp.toUint64(),
            blockNumber: block.number.toUint64()
        });

        lockedSeedingFinalized = true;
        delete _seedingProgress;

        emit LockedSeedingFinalized(_epoch);
    }

    /// @dev Walk a subcurve from `walkStart_` forward to `tsFinal_`,
    ///      applying slope-changes at each SIX_DAYS bucket. Used by
    ///      `finalizeSeeding` to materialize a LockedPoint that correctly
    ///      accounts for positions whose `subEnd` lapsed inside the seeding
    ///      window (the eagerly-written slope-changes at past buckets would
    ///      otherwise be stranded — see `SeedingProgress.minSubEnd` NatSpec).
    ///
    ///      All subEnds are on SIX_DAYS boundaries (since
    ///      `unlockTime = ((now + duration) / SIX_DAYS) * SIX_DAYS`), so a
    ///      SIX_DAYS-stride walk from `walkStart_` (= minSubEnd, itself on
    ///      a boundary) visits every subEnd bucket up to `tsFinal_`.
    /// @param totalBias_ Sum of `slope_i * subEnd_i` across seeded positions.
    /// @param totalSlope_ Sum of `slope_i` across seeded positions.
    /// @param walkStart_ Earliest seeded `subEnd` (must be > 0 and < tsFinal_).
    /// @param tsFinal_ Target timestamp at which to materialize (block.timestamp).
    /// @param isForfeitable_ True for forfeitable subcurve, false for locked.
    function _materializeFromAccumulator(
        int128 totalBias_,
        int128 totalSlope_,
        uint256 walkStart_,
        uint256 tsFinal_,
        bool isForfeitable_
    ) internal view returns (int128 bias, int128 slope) {
        uint256 ts = walkStart_;
        // bias just BEFORE drop-off at walkStart: positions with
        // subEnd_i > walkStart_ contribute positively; positions with
        // subEnd_i == walkStart_ contribute 0 (slope * 0).
        bias = totalBias_ - totalSlope_ * uint256(ts).toInt256().toInt128();
        slope = totalSlope_;

        // Apply slope-change at walkStart (drops slopes of positions
        // ending at exactly minSubEnd).
        int128 dSlope = isForfeitable_
            ? forfeitableSlopeChanges[ts]
            : lockedSlopeChanges[ts];
        slope += dSlope;
        if (slope < 0) slope = 0;

        uint256 t_i = ts;
        // Cap matches `_subcurveSupplyAtFromPoint` and `_supplyAt` (255).
        // In practice the walk runs only as long as
        // `(tsFinal_ - walkStart_) / SIX_DAYS`, which is bounded by the
        // operator's seeding window duration (hours, not years).
        for (uint256 i; i < 255; ++i) {
            t_i += SIX_DAYS;
            if (t_i >= tsFinal_) {
                bias -= slope * (tsFinal_ - ts).toInt256().toInt128();
                if (bias < 0) bias = 0;
                return (bias, slope);
            }
            dSlope = isForfeitable_
                ? forfeitableSlopeChanges[t_i]
                : lockedSlopeChanges[t_i];
            bias -= slope * (t_i - ts).toInt256().toInt128();
            if (bias < 0) bias = 0;
            slope += dSlope;
            if (slope < 0) slope = 0;
            ts = t_i;
        }
    }

    /**
     * @notice Get the total non-transferrable veHEMI supply at the current timestamp.
     * @return The voting weight of all non-transferrable positions
     */
    function nonTransferableTotalVeHemiSupply() public view returns (uint256) {
        return _subcurveSupplyAt(block.timestamp, false);
    }

    /**
     * @notice Get the total non-transferrable veHEMI supply at a specific timestamp.
     * @param timestamp_ The timestamp to query
     * @return The voting weight of all non-transferrable positions at that time
     */
    function nonTransferableTotalVeHemiSupplyAt(uint256 timestamp_) public view returns (uint256) {
        return _subcurveSupplyAt(timestamp_, false);
    }

    /**
     * @notice Get the total forfeitable (non-transferrable) veHEMI supply at the current timestamp.
     * @return The voting weight of all forfeitable positions
     */
    function forfeitableTotalVeHemiSupply() public view returns (uint256) {
        return _subcurveSupplyAt(block.timestamp, true);
    }

    /**
     * @notice Get the total forfeitable veHEMI supply at a specific timestamp.
     * @param timestamp_ The timestamp to query
     * @return The voting weight of all forfeitable positions at that time
     */
    function forfeitableTotalVeHemiSupplyAt(uint256 timestamp_) public view returns (uint256) {
        return _subcurveSupplyAt(timestamp_, true);
    }

    /**
     * @notice Combined supply breakdown avoiding redundant binary searches.
     * @dev Invariant: forfeitable_ <= locked_ <= total (enforced by defensive caps).
     *      In normal operation the three curves are accumulated from the same set of
     *      positions and can never violate the ordering. The defensive caps exist as a
     *      belt-and-suspenders guard against:
     *        (a) integer-rounding skew between curves (subcurves use min(end, transferableAfter)
     *            and a separate slope-changes mapping, so their truncation behavior under
     *            the linear-decay formula can drift by a few wei),
     *        (b) the period before `finalizeSeeding` runs, where the locked
     *            and forfeitable LockedPoints are unwritten (timestamp == 0) and therefore
     *            return 0 — without the cap a subsequent off-by-one in seeding could surface
     *            as `locked > total` to downstream consumers,
     *        (c) any future bug that violates the algebraic invariant; the caps keep the
     *            return shape sane (`transferable = total - locked` underflows otherwise).
     *      Consumers should treat the caps as defense-in-depth, not as authoritative reconciliation.
     * @return total Total veHEMI supply
     * @return locked_ Non-transferrable veHEMI supply (capped at total)
     * @return forfeitable_ Forfeitable non-transferrable veHEMI supply (capped at locked_)
     * @return transferable Transferrable veHEMI supply (total - locked_)
     */
    function supplyBreakdown() external view returns (uint256 total, uint256 locked_, uint256 forfeitable_, uint256 transferable) {
        uint256 _epoch = _getPastGlobalPointIndex(epoch, block.timestamp);
        if (_epoch == 0) return (0, 0, 0, 0);
        total = _supplyAt(globalPointHistory[_epoch], block.timestamp);

        LockedPoint memory _lp = lockedGlobalPointHistory[_epoch];
        if (_lp.timestamp != 0) {
            locked_ = _subcurveSupplyAtFromPoint(_lp, block.timestamp, false);
        }

        LockedPoint memory _rp = forfeitableGlobalPointHistory[_epoch];
        if (_rp.timestamp != 0) {
            forfeitable_ = _subcurveSupplyAtFromPoint(_rp, block.timestamp, true);
        }

        // Defense-in-depth: enforce forfeitable_ <= locked_ <= total
        if (locked_ > total) locked_ = total;
        if (forfeitable_ > locked_) forfeitable_ = locked_;
        transferable = total - locked_;
    }

    /**
     * @dev Parameterized subcurve supply-at query. Reads from either
     *      locked or forfeitable point history and slope changes.
     * @param timestamp_ The timestamp to query
     * @param isForfeitable_ true = forfeitable curve, false = locked curve
     */
    function _subcurveSupplyAt(uint256 timestamp_, bool isForfeitable_) internal view returns (uint256) {
        uint256 _epoch = _getPastGlobalPointIndex(epoch, timestamp_);
        if (_epoch == 0) return 0;
        LockedPoint memory _point = isForfeitable_
            ? forfeitableGlobalPointHistory[_epoch]
            : lockedGlobalPointHistory[_epoch];
        // Pre-V2 epochs have all-zero points (timestamp == 0)
        if (_point.timestamp == 0) return 0;
        return _subcurveSupplyAtFromPoint(_point, timestamp_, isForfeitable_);
    }

    /**
     * @dev Walk forward from a LockedPoint applying slope changes to compute supply at timestamp_.
     *      Shared between locked and forfeitable curves — differs only in which slope change mapping is read.
     */
    function _subcurveSupplyAtFromPoint(LockedPoint memory point_, uint256 timestamp_, bool isForfeitable_) internal view returns (uint256) {
        int128 bias = point_.bias;
        int128 slope = point_.slope;
        uint256 ts = point_.timestamp;

        uint256 t_i = (ts / SIX_DAYS) * SIX_DAYS;
        for (uint256 i; i < 255; ++i) {
            t_i += SIX_DAYS;
            int128 dSlope = 0;
            if (t_i > timestamp_) {
                t_i = timestamp_;
            } else {
                dSlope = isForfeitable_ ? forfeitableSlopeChanges[t_i] : lockedSlopeChanges[t_i];
            }
            bias -= slope * (t_i - ts).toInt256().toInt128();
            if (t_i == timestamp_) {
                break;
            }
            slope += dSlope;
            if (slope < 0) slope = 0;
            ts = t_i;
        }

        if (bias < 0) {
            bias = 0;
        }
        return bias.toUint256();
    }

    function _supplyAt(uint256 timestamp_) internal view returns (uint256) {
        uint256 _epoch = _getPastGlobalPointIndex(epoch, timestamp_);
        // epoch 0 is an empty point
        if (_epoch == 0) return 0;
        Point memory _point = globalPointHistory[_epoch];
        return _supplyAt(_point, timestamp_);
    }

    function _supplyAt(Point memory point_, uint256 timestamp_) internal view returns (uint256) {
        int128 bias = point_.bias;
        int128 slope = point_.slope;
        uint256 ts = point_.timestamp;

        uint256 t_i = (ts / SIX_DAYS) * SIX_DAYS;
        for (uint256 i; i < 255; ++i) {
            t_i += SIX_DAYS;
            int128 dSlope = 0;
            if (t_i > timestamp_) {
                t_i = timestamp_;
            } else {
                dSlope = slopeChanges[t_i];
            }
            bias -= slope * (t_i - ts).toInt256().toInt128();
            if (t_i == timestamp_) {
                break;
            }
            slope += dSlope;
            if (slope < 0) slope = 0;
            ts = t_i;
        }

        if (bias < 0) {
            bias = 0;
        }
        return bias.toUint256();
    }

    /// @dev Notifies the reward distributor of a position change. Fails silently (try/catch)
    ///      so a broken distributor cannot block core operations.
    function _updateReward(uint256 tokenId_) internal {
        if (address(rewardDistributor) != address(0)) {
            try rewardDistributor.updateRewards(tokenId_) {} catch {
                emit RewardUpdateFailed(tokenId_);
            }
        }
    }

    /**
     * @dev Internal withdraw: clears lock, checkpoints curves, burns NFT, transfers HEMI to msg.sender.
     *      Used by both withdraw() (owner receives HEMI) and forfeit() (forfeit admin receives HEMI).
     *      Checkpoint is called BEFORE burn so the final user point records the real owner.
     *      transferableAfter/forfeitable/provider are deleted AFTER checkpoint (which reads them).
     */
    function _withdraw(uint256 tokenId_) internal {
        _updateReward(tokenId_);
        LockedBalance memory _oldLocked = locked[tokenId_];
        uint256 _amount = _oldLocked.amount.toUint256();
        delete locked[tokenId_];
        totalLocked -= _amount;
        // Checkpoint BEFORE burn so the final user point records the real owner
        // (not address(0)). newLocked is zero, so _checkpoint correctly subtracts
        // the old position's bias/slope from the global curve. For expired locks,
        // the old bias/slope are already zero. For forfeit (non-expired), the
        // subtraction is necessary to maintain global curve correctness.
        // NOTE: transferableAfter must NOT be deleted before this call — _checkpoint
        // reads it to determine locked-curve membership for non-transferrable positions.
        _checkpoint(tokenId_, _oldLocked, LockedBalance(0, 0));
        // Clean up remaining state AFTER checkpoint.
        // forfeitable must also be deleted here (not just in forfeit()) so that
        // naturally-expired forfeitable positions are properly cleaned up on withdraw.
        delete transferableAfter[tokenId_];
        delete forfeitable[tokenId_];
        delete provider[tokenId_];
        _burn(tokenId_);

        address _sender = _msgSender();
        if (_amount > 0) {
            HEMI.safeTransfer(_sender, _amount);
        }

        emit Withdraw(_sender, tokenId_, _amount, block.timestamp);
    }

    /**
     * @notice ERC721 transfer override with veHEMI-specific semantics.
     * @dev Transfer re-delegation: the NFT's delegation is reset on every transfer via
     *      `_resolveAutoDelegate(to_)`. If the recipient has set an auto-delegate target
     *      via `VeHemiVoteDelegation.delegateAllFor` (typically through the Aragon
     *      adapter's `delegate(address)`), the position is delegated to that target;
     *      otherwise it self-delegates to the recipient. This means a transfer into an
     *      account that has already chosen a governance delegatee does NOT silently
     *      re-point voting power at the new owner — it tracks their declared delegate.
     *
     *      Mints (from_ == address(0)) skip both the transferability check and the
     *      re-delegation step; initial delegation for minted positions happens inside
     *      the mint flow (`createLock` / `createLockFor`) via `_resolveAutoDelegate`.
     */
    function transferFrom(
        address from_,
        address to_,
        uint256 tokenId_
    ) public override(ERC721Upgradeable, IERC721) nonReentrant {
        if (from_ != address(0)) {
            if (!isTransferable(tokenId_)) revert NotTransferable();
            _updateReward(tokenId_);
        }

        // ERC721 ownership transfer happens BEFORE _delegate so that the
        // notifyDelegateChanged hook (which resolves ownerOf(tokenId) inside
        // VeHemiVoteDelegation._delegate) sees `to_` as the current owner.
        // Without this ordering, the IVotes-shaped DelegateChanged event would
        // incorrectly attribute the delegation change to the SELLER (from_),
        // silently corrupting subgraphs that reconstruct delegation state from
        // the event stream. Math is unaffected: locked[tokenId] is unchanged
        // across the ERC721 transfer and the cached delegation values used by
        // _delegate are identical pre- and post-super.transferFrom.
        super.transferFrom(from_, to_, tokenId_);

        if (from_ != address(0)) {
            _delegate(tokenId_, _resolveAutoDelegate(to_));
            LockedBalance memory _locked = locked[tokenId_];
            _checkpoint(tokenId_, _locked, _locked);
        }
    }
}
