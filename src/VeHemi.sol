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
 * @dev V2 adds parallel non-transferable + forfeitable subcurves tracking non-transferable and
 *      forfeitable stake weight alongside the global curve. The subcurves are gated
 *      behind `nonTransferableSeedingFinalized`, which is a ONE-WAY latch:
 *
 *        - `nonTransferableSeedingFinalized == false` (V1 behavior): `_checkpoint` skips all
 *          subcurve accumulation. Contract is bytecode-upgradeable from V1 with
 *          zero behavioral divergence until seeding runs.
 *        - `seedAndFinalizeNonTransferablePositions(tokenIds)` (one-shot, owner-only): computes
 *          aggregate bias/slope for all existing non-transferable positions in memory,
 *          writes the non-transferable + forfeitable SupplyPoints, then flips the latch to true.
 *        - `nonTransferableSeedingFinalized == true` (V2 behavior): subcurve logic is live.
 *          There is NO un-finalize path. A missed position at seeding time permanently
 *          understates the non-transferable subcurve with no on-chain recovery.
 *
 *      V2 checkpoint math is strictly additive: the global curve produces identical
 *      values pre- and post-seeding. Only the NEW subcurve reads (supplyBreakdown,
 *      nonTransferableTotalVeHemiSupply, forfeitableTotalVeHemiSupply) depend on
 *      seeding having run.
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
    error EmptyArray();
    error NotNonTransferrable();
    error UnsortedOrDuplicateTokenIds();
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
     * @notice Check if a token is currently transferable
     * @dev Returns true for: (a) positions created with transferable=true (transferableAfter == 0),
     *      or (b) non-transferable positions whose transferableAfter timestamp has been reached.
     *      Uses <= so the position becomes transferable AT the exact transferableAfter timestamp.
     *      Note: returns true for non-existent/burned token IDs (transferableAfter defaults to 0).
     * @param tokenId_ The token ID
     * @return True if the token is transferable, false if still within non-transferability window
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
     * @notice Update the vote delegation contract address
     * @param newVoteDelegation_ The new vote delegation contract address
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
     * @dev V2: Maintains parallel non-transferable and forfeitable subcurves.
     *      - Non-transferable curve: all non-transferrable positions (transferableAfter != 0)
     *      - Forfeitable curve: forfeitable non-transferrable positions (strict subset of locked)
     *      Both share the same epoch counter as the global curve.
     *      All subcurve tracking is gated on `nonTransferableSeedingFinalized` to prevent corruption
     *      during the seeding window.
     *
     *      V1-COMPATIBILITY INVARIANT: the global-curve computations (Point arithmetic,
     *      `slopeChanges`, `globalPointHistory`, `userPointHistory`, `epoch`) are byte-for-byte
     *      identical to the V1 implementation. The V2 additions are strictly additive:
     *          (a) compute `_curveFlags` from `transferableAfter` / `forfeitable` — side-effect free,
     *          (b) compute `_oldSubcurveBias` / `_newSubcurveBias` using `min(lock.end, transferableAfter)`,
     *          (c) write to `nonTransferableGlobalPointHistory` / `forfeitableGlobalPointHistory` /
     *              `nonTransferableSlopeChanges` / `forfeitableSlopeChanges` — disjoint storage from V1,
     *          (d) every subcurve branch is guarded by `nonTransferableSeedingFinalized`, so pre-seeding
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

            if (nonTransferableSeedingFinalized && transferableAfter[tokenId_] != 0) {
                uint256 _ta = transferableAfter[tokenId_];
                bool _isForfeitable = forfeitable[tokenId_];

                // Old flags: position was in subcurves if it had active non-transferable data
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

            // V2: Load non-transferable + forfeitable points (only after seeding is finalized)
            SupplyPoint memory _lastNonTransferablePoint;
            SupplyPoint memory _lastForfeitablePoint;
            if (_epoch > 0 && nonTransferableSeedingFinalized) {
                _lastNonTransferablePoint = nonTransferableGlobalPointHistory[_epoch];
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

                    // V2: Non-transferable + forfeitable curve decay (parallel tracking)
                    // Slope changes read inline (no temp vars) to avoid stack-too-deep.
                    if (nonTransferableSeedingFinalized) {
                        _lastNonTransferablePoint.bias -= _lastNonTransferablePoint.slope * _dt;
                        if (_atBoundary) _lastNonTransferablePoint.slope += nonTransferableSlopeChanges[t_i];
                        if (_lastNonTransferablePoint.bias < 0) _lastNonTransferablePoint.bias = 0;
                        if (_lastNonTransferablePoint.slope < 0) _lastNonTransferablePoint.slope = 0;
                        _lastNonTransferablePoint.timestamp = t_i.toUint64();

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
                        if (nonTransferableSeedingFinalized) {
                            _lastNonTransferablePoint.blockNumber = block.number.toUint64();
                            _lastForfeitablePoint.blockNumber = block.number.toUint64();
                        }
                        break;
                    } else {
                        globalPointHistory[_epoch] = _lastPoint;
                        if (nonTransferableSeedingFinalized) {
                            _lastNonTransferablePoint.blockNumber = _lastPoint.blockNumber;
                            nonTransferableGlobalPointHistory[_epoch] = _lastNonTransferablePoint;
                            _lastForfeitablePoint.blockNumber = _lastPoint.blockNumber;
                            forfeitableGlobalPointHistory[_epoch] = _lastForfeitablePoint;
                        }
                    }
                }
            }

            // --- Phase C: Apply user delta to global + non-transferable + forfeitable points ---
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

                // V2: Non-transferable curve — apply old removal + new addition separately
                uint8 _oldFlags = _curveFlags & 0x0F;
                uint8 _newFlags = (_curveFlags >> 4) & 0x0F;
                if (_oldFlags >= 1 || _newFlags >= 1) {
                    // Slope delta is same as global (slope = amount/MAX_TIME, independent of end)
                    // Bias delta uses subcurve-specific values (bounded by transferableAfter)
                    int128 _slopeDelta;
                    if (_newFlags >= 1) _slopeDelta += _newUserPoint.slope;
                    if (_oldFlags >= 1) _slopeDelta -= _oldUserPoint.slope;
                    _lastNonTransferablePoint.slope += _slopeDelta;
                    _lastNonTransferablePoint.bias += (_newSubcurveBias - _oldSubcurveBias);
                    if (_lastNonTransferablePoint.slope < 0) _lastNonTransferablePoint.slope = 0;
                    if (_lastNonTransferablePoint.bias < 0) _lastNonTransferablePoint.bias = 0;

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

            // Write global + non-transferable + forfeitable points (same overwrite-vs-append logic)
            if (_epoch != 1 && globalPointHistory[_epoch - 1].timestamp == block.timestamp) {
                _writtenEpoch = _epoch - 1;
                globalPointHistory[_writtenEpoch] = _lastPoint;
                if (nonTransferableSeedingFinalized) {
                    nonTransferableGlobalPointHistory[_writtenEpoch] = _lastNonTransferablePoint;
                    forfeitableGlobalPointHistory[_writtenEpoch] = _lastForfeitablePoint;
                }
            } else {
                _writtenEpoch = _epoch;
                epoch = _epoch;
                globalPointHistory[_epoch] = _lastPoint;
                if (nonTransferableSeedingFinalized) {
                    nonTransferableGlobalPointHistory[_epoch] = _lastNonTransferablePoint;
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
     *                                  1 = non-transferable (global + non-transferable subcurve),
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
     * @dev Schedules non-transferable + forfeitable slope changes at subcurve-specific endpoints.
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
        // --- Non-transferable curve slope changes ---
        if (oldFlags_ >= 1 && oldSubEnd_ > block.timestamp) {
            int128 _oldNonTransferableDslope = nonTransferableSlopeChanges[oldSubEnd_];
            _oldNonTransferableDslope += oldSlope_;
            if (newFlags_ >= 1 && newSubEnd_ == oldSubEnd_) {
                _oldNonTransferableDslope -= newSlope_;
            }
            nonTransferableSlopeChanges[oldSubEnd_] = _oldNonTransferableDslope;
        }

        if (newFlags_ >= 1 && newSubEnd_ > block.timestamp && newSubEnd_ > oldSubEnd_) {
            int128 _newNonTransferableDslope = nonTransferableSlopeChanges[newSubEnd_];
            _newNonTransferableDslope -= newSlope_;
            nonTransferableSlopeChanges[newSubEnd_] = _newNonTransferableDslope;
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

    /// @dev Returns the auto-delegate target for an account, or the account itself
    ///      if no auto-delegate is set. try/catch ensures backwards compatibility
    ///      if voteDelegation hasn't been upgraded to support autoDelegate yet.
    function _resolveAutoDelegate(address account_) internal view returns (address) {
        try voteDelegation.autoDelegate(account_) returns (address result) {
            if (result != address(0)) return result;
        } catch {}
        return account_;
    }

    /// @dev Wrapped in try/catch for the same defensive reason as _reDelegate.
    function _delegate(uint256 delegator_, address delegatee_) internal {
        // Delegation changes take effect at the next epoch boundary. If lock ends before that, skip delegation.
        // Example: User is increasing amount or transferring just before lock ends.
        uint256 _newDelegationStarts = ((block.timestamp / 1 hours) * 1 hours) + 1 hours;
        if (_newDelegationStarts < locked[delegator_].end) {
            try voteDelegation.delegate(delegator_, delegatee_) {} catch {
                emit DelegationUpdateFailed(delegator_);
            }
        }
    }

    // =========================================================================
    // V2: Non-transferrable position weight tracking
    // =========================================================================

    /**
     * @notice Seeds all non-transferrable positions and finalizes the non-transferable + forfeitable curves atomically.
     * @dev Computes bias/slope entirely in memory for both non-transferable and forfeitable subsets.
     *      Calls _checkpoint to advance the epoch while nonTransferableSeedingFinalized is still false
     *      (so subcurve logic is skipped), then writes both SupplyPoints.
     *      Forfeitable positions are those where forfeitable[tokenId] == true.
     *      Callable once. Gas: ~4-7M depending on forfeitable count.
     *
     *      Slope-write timing: `nonTransferableSlopeChanges[_subEnd]` and `forfeitableSlopeChanges[_subEnd]`
     *      are written during Phase 1 at each position's effective subcurve end
     *      (`min(lock.end, transferableAfter)`), which is always >= block.timestamp (positions
     *      with `_ta <= block.timestamp` are skipped). The Phase 3 SupplyPoint is written at
     *      `block.timestamp`, NOT at a SIX_DAYS-rounded timestamp. This is safe because
     *      `_subcurveSupplyAt` reads the most recent SupplyPoint at or before the query
     *      timestamp and walks forward on the SIX_DAYS grid, picking up the just-written
     *      future slope changes without revisiting `block.timestamp`.
     *
     *      Input constraints: `tokenIds_` MUST be strictly ascending and contain every
     *      active non-transferable position. Missed positions permanently understate the
     *      non-transferable subcurve (no retroactive seeding path).
     * @param tokenIds_ Array of non-transferrable token IDs (must not be empty)
     */
    function seedAndFinalizeNonTransferablePositions(uint256[] calldata tokenIds_) external onlyOwner {
        if (nonTransferableSeedingFinalized) revert SeedingAlreadyFinalized();
        if (tokenIds_.length == 0) revert EmptyArray();

        // Require strictly ascending token IDs to prevent double-counting.
        // Duplicate IDs would permanently corrupt the curves since this
        // function can only be called once (nonTransferableSeedingFinalized gate).
        for (uint256 i = 1; i < tokenIds_.length; ++i) {
            if (tokenIds_[i] <= tokenIds_[i - 1]) revert UnsortedOrDuplicateTokenIds();
        }

        // --- Phase 1: Accumulate bias/slope in memory for locked AND forfeitable ---
        int128 _totalSlope;
        int128 _totalBias; // stores sum(slope_i * end_i), time-independent
        int128 _totalForfeitableSlope;
        int128 _totalForfeitableBias;

        for (uint256 i; i < tokenIds_.length; ++i) {
            uint256 tokenId = tokenIds_[i];
            if (_ownerOf(tokenId) == address(0)) revert TokenDoesNotExist();
            if (transferableAfter[tokenId] == 0) revert NotNonTransferrable();
            LockedBalance memory _lock = locked[tokenId];
            if (_lock.end <= block.timestamp || _lock.amount <= 0) continue;

            int128 slope = _lock.amount / MAX_TIME.toInt256().toInt128();
            // V2: Subcurve endpoint is min(lock.end, transferableAfter).
            // Skip subcurve accumulation if the transferability window has already opened
            // (the position is no longer in the locked/forfeitable subcurves).
            uint256 _ta = transferableAfter[tokenId];
            if (_ta > block.timestamp) {
                uint256 _subEnd = _lock.end < _ta ? _lock.end : _ta;
                _totalSlope += slope;
                _totalBias += slope * uint256(_subEnd).toInt256().toInt128();
                nonTransferableSlopeChanges[_subEnd] -= slope;

                // Forfeitable subset
                if (forfeitable[tokenId]) {
                    _totalForfeitableSlope += slope;
                    _totalForfeitableBias += slope * uint256(_subEnd).toInt256().toInt128();
                    forfeitableSlopeChanges[_subEnd] -= slope;
                }
            }
            // Note: positions with _ta <= block.timestamp are still valid non-transferrable
            // positions (they pass the transferableAfter[tokenId] != 0 check above), but
            // their transferability window has opened so they are excluded from subcurves.
        }

        // --- Phase 2: Advance global epoch to block.timestamp ---
        // nonTransferableSeedingFinalized is still false, so _checkpoint skips all subcurve
        // logic. The already-written slope changes are invisible to the catchup loop.
        _checkpoint(0, LockedBalance(0, 0), LockedBalance(0, 0));

        // --- Phase 3: Write non-transferable + forfeitable points at current epoch ---
        uint256 _epoch = epoch;
        int128 _tsInt = uint256(block.timestamp).toInt256().toInt128();

        // Non-transferable point: derive bias at block.timestamp
        int128 _nonTransferableBias = _totalBias - _totalSlope * _tsInt;
        if (_nonTransferableBias < 0) _nonTransferableBias = 0;

        nonTransferableGlobalPointHistory[_epoch] = SupplyPoint({
            bias: _nonTransferableBias,
            slope: _totalSlope,
            timestamp: block.timestamp.toUint64(),
            blockNumber: block.number.toUint64()
        });

        // Forfeitable point: always write (even if zero) so timestamp != 0 for view functions
        int128 _forfeitableBias = _totalForfeitableBias - _totalForfeitableSlope * _tsInt;
        if (_forfeitableBias < 0) _forfeitableBias = 0;

        forfeitableGlobalPointHistory[_epoch] = SupplyPoint({
            bias: _forfeitableBias,
            slope: _totalForfeitableSlope,
            timestamp: block.timestamp.toUint64(),
            blockNumber: block.number.toUint64()
        });

        // --- Phase 4: Finalize ---
        nonTransferableSeedingFinalized = true;
        emit NonTransferableSeedingFinalized(_epoch);
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
     *        (b) the period before `seedAndFinalizeNonTransferablePositions` runs, where the locked
     *            and forfeitable SupplyPoints are unwritten (timestamp == 0) and therefore
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

        SupplyPoint memory _lp = nonTransferableGlobalPointHistory[_epoch];
        if (_lp.timestamp != 0) {
            locked_ = _subcurveSupplyAtFromPoint(_lp, block.timestamp, false);
        }

        SupplyPoint memory _rp = forfeitableGlobalPointHistory[_epoch];
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
     * @param isForfeitable_ true = forfeitable curve, false = non-transferable curve
     */
    function _subcurveSupplyAt(uint256 timestamp_, bool isForfeitable_) internal view returns (uint256) {
        uint256 _epoch = _getPastGlobalPointIndex(epoch, timestamp_);
        if (_epoch == 0) return 0;
        SupplyPoint memory _point = isForfeitable_
            ? forfeitableGlobalPointHistory[_epoch]
            : nonTransferableGlobalPointHistory[_epoch];
        // Pre-V2 epochs have all-zero points (timestamp == 0)
        if (_point.timestamp == 0) return 0;
        return _subcurveSupplyAtFromPoint(_point, timestamp_, isForfeitable_);
    }

    /**
     * @dev Walk forward from a SupplyPoint applying slope changes to compute supply at timestamp_.
     *      Shared between non-transferable and forfeitable curves — differs only in which slope change mapping is read.
     */
    function _subcurveSupplyAtFromPoint(SupplyPoint memory point_, uint256 timestamp_, bool isForfeitable_) internal view returns (uint256) {
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
                dSlope = isForfeitable_ ? forfeitableSlopeChanges[t_i] : nonTransferableSlopeChanges[t_i];
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
            _delegate(tokenId_, _resolveAutoDelegate(to_));
        }

        super.transferFrom(from_, to_, tokenId_);

        if (from_ != address(0)) {
            LockedBalance memory _locked = locked[tokenId_];
            _checkpoint(tokenId_, _locked, _locked);
        }
    }
}
