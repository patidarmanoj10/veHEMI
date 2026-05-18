// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import "forge-std/Test.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {VeHemi} from "src/VeHemi.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {VeHemiVoteDelegation} from "src/VeHemiVoteDelegation.sol";
import {IVeHemi} from "src/interfaces/IVeHemi.sol";
import {IVeHemiVoteDelegation} from "src/interfaces/IVeHemiVoteDelegation.sol";
import {InvariantHandler, CountingAdapter} from "./InvariantHandler.sol";

contract InvariantTest is Test {
    using SafeCast for int128;

    /// @dev MAX_TIME from VeHemi.sol: 4 * YEAR = 4 * 365.25 days. Hardcoded
    ///      because the contract constant is private. If this value changes
    ///      in the contract, the per-position invariant reconstruction below
    ///      will silently drift — update both together.
    uint256 internal constant MAX_TIME = 4 * 365.25 days;

    address admin = makeAddr("admin");
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address carl = makeAddr("carl");
    address dan = makeAddr("dan");
    address earl = makeAddr("earl");

    InvariantHandler handler;
    VeHemi veHemi;
    VeHemiVoteDelegation public delegation;
    MockERC20 public hemi;

    function setUp() public {
        handler = new InvariantHandler(admin, [alice, bob, carl, dan, earl]);
        veHemi = handler.veHemi();
        hemi = handler.hemi();
        delegation = handler.delegation();

        targetContract(address(handler));

        for (uint i = 0; i < 5; i++) {
            targetSender(handler.users(i));
        }
    }

    function invariant_veHemiSupply() public view {
        uint256 sumOfBalances;

        for (uint i; i < 5; i++) {
            address user = handler.users(i);

            uint256 nfts = veHemi.balanceOf(user);
            for (uint256 j; j < nfts; j++) {
                uint256 tokenId = veHemi.tokenOfOwnerByIndex(user, j);
                sumOfBalances += veHemi.balanceOfNFT(tokenId);
            }
        }

        assertEq(sumOfBalances, veHemi.totalVeHemiSupply(), "sum of balances != total supply");
    }

    function invariant_votingPower() public {
        // Warp to next hourly epoch boundary (delegation takes effect at hour boundaries),
        // then restore timestamp so we don't pollute handler state.
        uint256 savedTimestamp = block.timestamp;
        vm.warp(((block.timestamp / 1 hours) * 1 hours) + 1 hours);

        uint256 sumOfBalances;
        uint256 sumOfVotes;

        for (uint i; i < 5; i++) {
            address user = handler.users(i);

            sumOfVotes += delegation.getVotes(user);

            uint256 nfts = veHemi.balanceOf(user);
            for (uint256 j; j < nfts; j++) {
                uint256 tokenId = veHemi.tokenOfOwnerByIndex(user, j);
                sumOfBalances += veHemi.balanceOfNFT(tokenId);
            }
        }

        assertEq(sumOfBalances, sumOfVotes, "sum of balances != sum of votes");

        vm.warp(savedTimestamp);
    }

    /// @dev V2: The aggregate non-transferable supply curve must equal the sum
    ///      reconstructed from per-position primitives. The existing
    ///      `invariant_supplyBreakdownConsistency` only proves the curve is
    ///      self-consistent across its own getters; it cannot detect a drift
    ///      between the cached `lockedGlobalPointHistory` and the underlying
    ///      positions (e.g., a missed slope-change write, a wrong `_subEnd`
    ///      choice in seedBatch, a missed forfeit cleanup, a double-decrement).
    ///      This invariant reconstructs the truth from the same primitives the
    ///      contract reads and demands byte-equality — no tolerance.
    function invariant_nonTransferableEqualsPerPositionSum() public {
        if (!handler.seeded()) return;

        uint256 nowTs = block.timestamp;
        uint256 expected;
        uint256 nextId = veHemi.nextTokenId();

        for (uint256 id = 1; id < nextId; ++id) {
            if (handler._ownerOf(id) == address(0)) continue; // burned
            uint256 ta = veHemi.transferableAfter(id);
            if (ta == 0) continue;          // transferable — not in subcurve
            if (ta <= nowTs) continue;      // subcurve membership already exited
            IVeHemi.LockedBalance memory lb = veHemi.getLockedBalance(id);
            if (lb.end <= nowTs) continue;  // expired
            uint256 subEnd = lb.end < ta ? lb.end : ta;
            if (subEnd <= nowTs) continue;
            // slope uses integer truncation matching `_checkpoint` math:
            //   slope = amount / MAX_TIME  (int128 ops, but always non-negative here)
            uint256 slope = uint256(uint128(lb.amount)) / MAX_TIME;
            expected += slope * (subEnd - nowTs);
        }
        assertEq(
            expected,
            veHemi.nonTransferableTotalVeHemiSupply(),
            "non-transferable subcurve diverged from per-position reconstruction"
        );
    }

    /// @dev V2: Companion to `invariant_nonTransferableEqualsPerPositionSum`
    ///      for the forfeitable subset. Forfeitable positions are a strict
    ///      subset of non-transferable, so the reconstruction filter adds the
    ///      `forfeitable[id]` check.
    function invariant_forfeitableEqualsPerPositionSum() public {
        if (!handler.seeded()) return;

        uint256 nowTs = block.timestamp;
        uint256 expected;
        uint256 nextId = veHemi.nextTokenId();

        for (uint256 id = 1; id < nextId; ++id) {
            if (handler._ownerOf(id) == address(0)) continue;
            if (!veHemi.forfeitable(id)) continue;
            uint256 ta = veHemi.transferableAfter(id);
            if (ta == 0 || ta <= nowTs) continue;
            IVeHemi.LockedBalance memory lb = veHemi.getLockedBalance(id);
            if (lb.end <= nowTs) continue;
            uint256 subEnd = lb.end < ta ? lb.end : ta;
            if (subEnd <= nowTs) continue;
            uint256 slope = uint256(uint128(lb.amount)) / MAX_TIME;
            expected += slope * (subEnd - nowTs);
        }
        assertEq(
            expected,
            veHemi.forfeitableTotalVeHemiSupply(),
            "forfeitable subcurve diverged from per-position reconstruction"
        );
    }

    /// @dev VACUITY GUARD: `seed()` increments `handler.seedAttempts` BEFORE
    ///      running `markSeedingStarted`/`seedBatch`/`finalizeSeeding`, and
    ///      sets `handler.seeded` AFTER. With `fail_on_revert = true` the
    ///      handler can never partial-complete `seed()` — it either reverts
    ///      (failing the run) or runs cleanly to set the latch. Therefore
    ///      EVERY observation of `seedAttempts > 0` MUST coincide with
    ///      `seeded == true` at this invariant check point.
    ///
    ///      Defends against the regression class where `markSeedingStarted`
    ///      silently fails to set the latch (e.g., MUT-Q7 of N4-A2's
    ///      mutation analysis: `seedingStartedAt = block.timestamp - 1`):
    ///      `seedAttempts` would increment but the immediate cross-block
    ///      revert from `_requireSeedingActive` would either fail the run
    ///      under fail_on_revert (catching the bug) or leave `seeded ==
    ///      false` (caught by THIS invariant).
    function invariant_seedingAttemptCounterAndSeededLatchAreCoherent() public view {
        if (handler.seedAttempts() > 0) {
            assertTrue(
                handler.seeded(),
                "seedAttempts > 0 but seeded latch never flipped - markSeedingStarted broken?"
            );
        }
    }

    /// @dev V2: After seeding, forfeitable <= locked <= total must always hold.
    function invariant_subcurveOrdering() public view {
        if (!handler.seeded()) return; // Subcurves not active yet

        uint256 total = veHemi.totalVeHemiSupply();
        uint256 locked = veHemi.nonTransferableTotalVeHemiSupply();
        uint256 forfeitable_ = veHemi.forfeitableTotalVeHemiSupply();

        assertLe(forfeitable_, locked, "forfeitable > locked");
        assertLe(locked, total, "locked > total");
    }

    /// @dev The global epoch counter must only increase, and globalPointHistory timestamps
    ///      must be non-decreasing. The binary search in _getPastGlobalPointIndex relies on
    ///      this ordering invariant. Checks a sliding window of the most recent epochs to
    ///      keep invariant runs fast while still catching regressions.
    function invariant_epochMonotonicity() public view {
        uint256 currentEpoch = veHemi.epoch();
        if (currentEpoch < 2) return;

        // Sample the most recent 8 epochs (or fewer if epoch < 8)
        uint256 start = currentEpoch > 8 ? currentEpoch - 8 : 1;
        uint256 prevTimestamp = veHemi.getGlobalPoint(start).timestamp;
        for (uint256 i = start + 1; i <= currentEpoch; ++i) {
            uint256 ts = veHemi.getGlobalPoint(i).timestamp;
            assertGe(ts, prevTimestamp, "globalPointHistory timestamps must be non-decreasing");
            prevTimestamp = ts;
        }
    }

    /// @dev Token conservation: the HEMI balance held by VeHemi must equal totalLocked.
    ///      If these diverge, either HEMI has leaked out or totalLocked is miscounted.
    ///      This is the most fundamental safety invariant — any violation is critical.
    function invariant_tokenConservation() public view {
        assertEq(
            hemi.balanceOf(address(veHemi)),
            veHemi.totalLocked(),
            "HEMI.balanceOf(veHemi) must equal totalLocked"
        );
    }

    /// @dev V2: supplyBreakdown must be internally consistent AND match individual functions.
    function invariant_supplyBreakdownConsistency() public view {
        if (!handler.seeded()) return;

        (uint256 total, uint256 locked_, uint256 forfeitable_, uint256 transferable) = veHemi.supplyBreakdown();

        // Internal consistency
        assertLe(forfeitable_, locked_, "breakdown: forfeitable > locked");
        assertLe(locked_, total, "breakdown: locked > total");
        assertEq(transferable, total - locked_, "breakdown: transferable != total - locked");

        // Cross-check against individual supply functions. These MUST be
        // exactly equal — supplyBreakdown and the individual getters read the
        // same underlying curves at the same timestamp. Any tolerance would
        // mask a real accounting divergence.
        assertEq(total, veHemi.totalVeHemiSupply(), "breakdown total != totalVeHemiSupply");
        assertEq(locked_, veHemi.nonTransferableTotalVeHemiSupply(), "breakdown locked != nonTransferableTotalVeHemiSupply");
        assertEq(forfeitable_, veHemi.forfeitableTotalVeHemiSupply(), "breakdown forfeitable != forfeitableTotalVeHemiSupply");
    }

    /// @dev Storage-layout anchor invariant: assert that critical V1 value-type slots still
    ///      read through their public getters, and the V2 `__gapV2` region remains zeroed.
    ///      Catches any exotic sequence of handler operations that somehow corrupts the
    ///      mapping between public getters and their expected storage slots.
    ///      The slots checked here are the same ones asserted in VeHemiStorageLayout.t.sol,
    ///      but the invariant runner exercises them under fuzz-driven state transitions.
    function invariant_storageLayoutAnchors() public view {
        // Slot 0: totalLocked must equal the getter.
        assertEq(
            uint256(vm.load(address(veHemi), bytes32(uint256(0)))),
            veHemi.totalLocked(),
            "slot 0 (totalLocked) decoupled from getter"
        );
        // Slot 1: epoch.
        assertEq(
            uint256(vm.load(address(veHemi), bytes32(uint256(1)))),
            veHemi.epoch(),
            "slot 1 (epoch) decoupled from getter"
        );
        // Slot 2: nextTokenId.
        assertEq(
            uint256(vm.load(address(veHemi), bytes32(uint256(2)))),
            veHemi.nextTokenId(),
            "slot 2 (nextTokenId) decoupled from getter"
        );
        // Slot 5: forfeitAdmin (address at offset 0). The handler mutates
        // forfeit but never re-points forfeitAdmin, so this slot should
        // remain set to the value installed during handler construction.
        assertEq(
            address(uint160(uint256(vm.load(address(veHemi), bytes32(uint256(5)))))),
            veHemi.forfeitAdmin(),
            "slot 5 (forfeitAdmin) decoupled from getter"
        );
        // Slot 18: lockedSeedingFinalized (bool at offset 0, low byte only).
        // Masking to the low byte makes this assertion robust to a future
        // pack that adds another small field into the same slot.
        bool rawSeedFlag = (uint256(vm.load(address(veHemi), bytes32(uint256(18)))) & 0xff) != 0;
        assertEq(rawSeedFlag, veHemi.lockedSeedingFinalized(), "slot 18 (lockedSeedingFinalized) decoupled");
    }

    /// @dev V2 reserved slots 14 and 15 (`__reservedSlot0/1`) are declared
    ///      private and never written by any code path. Under arbitrary
    ///      handler sequences they MUST remain zero — a non-zero value here
    ///      indicates a write ran off the end of a V1 field or through a
    ///      misaligned mapping.
    function invariant_reservedSlotsZero() public view {
        assertEq(
            vm.load(address(veHemi), bytes32(uint256(14))),
            bytes32(0),
            "V2 reserved slot 14 corrupted"
        );
        assertEq(
            vm.load(address(veHemi), bytes32(uint256(15))),
            bytes32(0),
            "V2 reserved slot 15 corrupted"
        );
    }

    /// @dev Storage-gap integrity: V2's `__gapV2[36]` occupies slots 28–63.
    ///      They must remain zero under all handler operations. Any non-zero
    ///      slot in this range indicates a write ran off the end of a named
    ///      field (would happen if a struct size calculation were wrong or
    ///      storage was written beyond a mapping's expected layout).
    function invariant_gapSlotsZero() public view {
        for (uint256 i = 28; i <= 63; ++i) {
            assertEq(
                vm.load(address(veHemi), bytes32(i)),
                bytes32(0),
                string.concat("V2 gap slot ", vm.toString(i), " corrupted")
            );
        }
    }

    /// @dev `_seedingProgress` occupies slots 23-27 (5 slots:
    ///      lastProcessedId, packed slope/bias pair, packed forfeitable pair,
    ///      count, minSubEnd). While seeding is in flight (between
    ///      `markSeedingStarted` and `finalizeSeeding`) these slots carry the
    ///      accumulator; after `finalizeSeeding` runs the
    ///      `delete _seedingProgress` clears them back to zero. The invariant
    ///      runner evaluates between handler calls, when seeding is either
    ///      not yet started or fully finalized — so the accumulator MUST be
    ///      zero in every observed state.
    function invariant_seedingProgressAccumulatorIsCleanAtRest() public view {
        for (uint256 i = 23; i <= 27; ++i) {
            assertEq(
                vm.load(address(veHemi), bytes32(i)),
                bytes32(0),
                string.concat("_seedingProgress slot ", vm.toString(i), " not cleared")
            );
        }
    }

    // -------------------------------------------------------------------------
    // Delegation behavior invariants
    //
    // These pin runtime properties of the VeHemi ↔ VeHemiVoteDelegation
    // surface under fuzz-driven sequences of mints, transfers, forfeits,
    // delegations, setAutoDelegate and clearAutoDelegate calls. Companion
    // unit coverage lives in test/DelegationBehavior.t.sol; the invariants
    // here exercise compositions the unit tests can't cover.
    // -------------------------------------------------------------------------

    /// @dev `getVotes(address(0))` and `getPastVotes(address(0), t)` must
    ///      always read 0. Forfeit cleanup is the only path that drives the
    ///      delegation contract's `_delegate(_, address(0))` helper, and
    ///      that helper must not push a checkpoint or expirations entry
    ///      under the zero-address key. The fuzz handler exercises
    ///      `forfeit()` so this invariant catches any regression that
    ///      re-introduces an address(0) checkpoint write via a side path.
    function invariant_zeroAddressNeverAccrues() public view {
        assertEq(delegation.getVotes(address(0)), 0, "getVotes(address(0)) must be 0");
        if (block.timestamp > 0) {
            assertEq(
                delegation.getPastVotes(address(0), block.timestamp - 1), 0, "getPastVotes(address(0), t) must be 0"
            );
        }
    }

    /// @dev Direct storage probe: `delegateCheckpoints[address(0)]` must
    ///      remain a length-0 array under all handler sequences. This
    ///      catches the regression class where someone pushes a checkpoint
    ///      under the zero-address key from a new code path even if
    ///      `getVotes` still returns 0 at the moment of assertion (e.g.
    ///      before decay catches up).
    function invariant_zeroAddressCheckpointsEmpty() public view {
        // delegateCheckpoints lives at slot 1 of VeHemiDelegationStorageV1.
        // The dynamic-array length for `mapping(address => DelegateCheckpoint[])`
        // is at keccak256(key, slot).
        bytes32 lengthSlot = keccak256(abi.encode(address(0), uint256(1)));
        uint256 len = uint256(vm.load(address(delegation), lengthSlot));
        assertEq(len, 0, "delegateCheckpoints[address(0)].length must be 0");
    }

    /// @dev Every minted, live token must have a non-zero cached delegatee.
    ///      Every mint path (createLock / createLockFor) and every transfer
    ///      path runs `_delegate` against `_resolveAutoDelegate`, which
    ///      falls back to the recipient itself when their autoDelegate is
    ///      unset. The only legal way for `delegations[tokenId].delegatee`
    ///      to be address(0) is on a burned tokenId (`ownerOf` reverts /
    ///      returns 0 in that case).
    function invariant_ownershipDelegateConsistency() public {
        uint256 nextId = veHemi.nextTokenId();
        for (uint256 id = 1; id < nextId; ++id) {
            address tokenOwner = handler._ownerOf(id);
            if (tokenOwner == address(0)) continue; // burned — delegations cleared by forfeit
            IVeHemiVoteDelegation.Delegation memory d = delegation.delegation(id);
            assertTrue(
                d.delegatee != address(0), string.concat("live tokenId ", vm.toString(id), " has zero delegatee")
            );
        }
    }

    /// @dev Forfeit cleanup must zero out `delegations[tokenId]` entirely.
    ///      The handler tracks forfeited tokenIds explicitly so this
    ///      invariant asserts only on the forfeit path — natural
    ///      `withdraw` cleanup is out of scope and intentionally not
    ///      checked here. If withdraw cleanup is added later, widen this
    ///      loop to scan all burned tokens via `_ownerOf`.
    function invariant_forfeitClearsDelegations() public view {
        uint256 n = handler.forfeitedTokenIdsLength();
        for (uint256 i; i < n; ++i) {
            uint256 id = handler.forfeitedTokenIds(i);
            IVeHemiVoteDelegation.Delegation memory d = delegation.delegation(id);
            assertEq(d.delegatee, address(0), "forfeited tokenId retains stale delegatee");
            assertEq(uint256(d.bias), 0, "forfeited tokenId retains stale bias");
            assertEq(uint256(d.amount), 0, "forfeited tokenId retains stale amount");
            assertEq(uint256(d.slope), 0, "forfeited tokenId retains stale slope");
        }
    }

    /// @dev `setAutoDelegate` must NEVER mutate any per-tokenId cached
    ///      delegation — it only changes the account-level autoDelegate
    ///      slot that future mints / transfers consult. We can't snapshot
    ///      before every handler call, but we can pin a strictly weaker
    ///      structural property: no live tokenId's
    ///      `delegations[tokenId].delegatee` may equal address(0). (If
    ///      `setAutoDelegate` ever erroneously cleared a per-tokenId cache,
    ///      the cache would become 0 and this would fail.) Composes with
    ///      `invariant_ownershipDelegateConsistency` above as
    ///      defense-in-depth on the same property.
    function invariant_autoDelegateDoesNotMutateExistingDelegations() public {
        uint256 nextId = veHemi.nextTokenId();
        for (uint256 id = 1; id < nextId; ++id) {
            address tokenOwner = handler._ownerOf(id);
            if (tokenOwner == address(0)) continue;
            // Live token: delegatee must be non-zero (set at mint and only
            // ever rewritten by delegate / transferFrom-induced _delegate).
            IVeHemiVoteDelegation.Delegation memory d = delegation.delegation(id);
            assertTrue(
                d.delegatee != address(0), "live tokenId acquired a 0 delegatee - setAutoDelegate must not mutate cache"
            );
        }
    }

    /// @notice `getPastVotes(addr, t)` is the load-bearing Aragon governance
    ///         read: once a proposal is created at block `t`, the quorum and
    ///         vote-weight calculation MUST return the same value for any
    ///         future re-query at the SAME `t`. Any retroactive mutation
    ///         (a delegate / forfeit / transfer / extend that goes back and
    ///         rewrites the historical curve) would silently invalidate
    ///         finalized proposals.
    ///
    ///         The handler captures `(account, timestamp, votes)` tuples
    ///         throughout the fuzz sequence; this invariant re-queries
    ///         `getPastVotes(account, timestamp)` after every tick and
    ///         asserts byte-equality against the captured `votes`. Any
    ///         drift fails the invariant.
    function invariant_pastVotesImmutability() public {
        // Advance time by 1 second so EVERY sampled timestamp is strictly
        // in the past relative to the query — including samples taken at
        // the most recent handler tick (where `sample.timestamp ==
        // block.timestamp` at sample time). The pre-polish version of
        // this invariant skipped same-block samples to avoid querying
        // `getPastVotes(_, block.timestamp)`; that skip left a tail-
        // coverage hole when no `warp` action lands between
        // `samplePastVotes` and the invariant tick. The +1s warp closes
        // that gap and exercises the strictly-historical binary-search
        // branch on `delegateCheckpoints` for every captured sample.
        // Same warp+restore idiom as `invariant_votingPower` above
        // (line 66).
        uint256 savedTimestamp = block.timestamp;
        vm.warp(savedTimestamp + 1);

        uint256 n = handler.pastVotesSamplesLength();
        for (uint256 i; i < n; ++i) {
            (address account, uint256 timestamp, uint256 expected) = handler.pastVotesSamples(i);
            // Every sample is now strictly in the past (timestamp <= savedTimestamp < now).
            uint256 actual = delegation.getPastVotes(account, timestamp);
            assertEq(
                actual,
                expected,
                "getPastVotes retroactively mutated - historical curve must be immutable"
            );
        }

        vm.warp(savedTimestamp);
    }

    /// @notice The IAdapterNotify relay paths (`notifyDelegateChanged` and
    ///         `notifyVotesChanged` callbacks from `VeHemiVoteDelegation`
    ///         to the configured `trustedAdapter`) were previously DEAD
    ///         under fuzz — `setTrustedAdapter` was never called by any
    ///         handler action, so the three relay sites in
    ///         `VeHemiVoteDelegation._delegate` / `_moveVotingPowerTo*` /
    ///         `refreshVotingPower*` had zero fuzz exposure.
    ///
    ///         The handler now installs a `CountingAdapter` at construction
    ///         time. This invariant asserts:
    ///           (a) the adapter received at LEAST one notify call per
    ///               forfeited token (every forfeit fires
    ///               `notifyDelegateChanged(_, _, address(0))`), and
    ///           (b) once any delegation mutation has occurred, the
    ///               `notifyVotesChanged` counter is non-zero (proving
    ///               the votes-changed relay path is live).
    function invariant_adapterRelayParity() public view {
        CountingAdapter adapter = CountingAdapter(handler.adapter());
        uint256 forfeitCount = handler.forfeitedTokenIdsLength();
        assertGe(
            adapter.notifyDelegateChangedCount(),
            forfeitCount,
            "adapter received fewer DelegateChanged relays than forfeits - relay path is broken or skipped"
        );
        // If any token has ever been minted, at least one mint-time
        // delegate auto-fires `_moveVotingPowerToNewDelegate` which calls
        // `notifyVotesChanged`. So nextTokenId > 1 implies the votes-relay
        // counter is non-zero.
        if (veHemi.nextTokenId() > 1) {
            assertGt(
                adapter.notifyVotesChangedCount(),
                0,
                "adapter received zero VotesChanged relays despite minted positions - relay path is dead"
            );
        }
    }
}
