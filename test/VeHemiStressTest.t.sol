// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import "./NonTransferableCurveTestBase.sol";
import "../src/storage/VeHemiStorageV2.sol";

/// @title VeHemiStressTest
/// @notice Large-scale stress test that creates hundreds of positions across all three types
///         (transferable, locked non-forfeitable, forfeitable) and verifies the contract's
///         supply functions against independent shadow calculations at multiple timestamps.
///
///         The shadow accounting tracks each position's slope and end time, then computes
///         expected supply by summing individual biases: sum(slope_i * max(0, end_i - t))
///         for all active positions at time t. This is a completely independent calculation
///         from the contract's bias/slope catchup loop, so exact agreement proves correctness.
///
///         All comparisons use assertEq (exact equality). The shadow and contract produce
///         identical results because both use the same integer division for slopes and the
///         contract's aggregate tracking is algebraically equivalent to per-position summation.
contract VeHemiStressTest is NonTransferableCurveTestBase {
    uint256 constant MIN_AMOUNT = 11 ether;

    // ── Shadow accounting ────────────────────────────────────────────────

    enum PosType { Transferable, Locked, Forfeitable }
    // Filter sentinel: use uint8 cast > 2 for "all positions"
    uint8 constant FILTER_ALL = 255;
    uint8 constant FILTER_LOCKED = 1;
    uint8 constant FILTER_FORFEITABLE = 2;

    struct ShadowPosition {
        uint256 tokenId;
        PosType posType;
        uint256 slope;       // amount / MAX_TIME (integer division, matches contract)
        uint256 end;         // lock end (SIX_DAYS-rounded, read from contract)
        uint256 subcurveEnd; // min(end, transferableAfter) — subcurve exit point
        bool alive;          // false after withdraw or forfeit
    }

    ShadowPosition[] internal shadows;
    uint256[] internal nonTransferableTokenIds; // for seeding (only non-transferable + forfeitable)

    // Users beyond alice/bob/charlie
    address[] internal testUsers;

    function setUp() public override {
        super.setUp();

        // Create a pool of 10 user addresses
        for (uint256 i = 1; i <= 10; i++) {
            address user = address(uint160(0xAA00 + i));
            testUsers.push(user);
            vm.startPrank(user);
            hemi.mint(user, 100_000 ether);
            hemi.approve(address(veHemi), type(uint256).max);
            vm.stopPrank();
        }

        veHemi.updateForfeitAdmin(admin);
    }

    // ── Position creation helpers ────────────────────────────────────────

    function _createPos(
        address user,
        uint256 amount,
        uint256 duration,
        PosType posType
    ) internal returns (uint256 tokenId) {
        vm.startPrank(posType == PosType.Transferable ? user : admin);
        hemi.mint(posType == PosType.Transferable ? user : admin, amount);
        hemi.approve(address(veHemi), type(uint256).max);

        if (posType == PosType.Transferable) {
            tokenId = veHemi.createLock(amount, duration);
        } else if (posType == PosType.Locked) {
            tokenId = veHemi.createLockFor(amount, duration, user, false, false);
        } else {
            tokenId = veHemi.createLockFor(amount, duration, user, false, true);
        }
        vm.stopPrank();

        uint256 slope = amount / MAX_TIME;
        uint256 end = veHemi.getLockedBalance(tokenId).end;
        // For subcurves, effective end is min(end, transferableAfter)
        uint256 ta = veHemi.transferableAfter(tokenId);
        uint256 subcurveEnd = (posType != PosType.Transferable && ta > 0 && ta < end) ? ta : end;

        shadows.push(ShadowPosition({
            tokenId: tokenId,
            posType: posType,
            slope: slope,
            end: end,
            subcurveEnd: subcurveEnd,
            alive: true
        }));

        if (posType != PosType.Transferable) {
            nonTransferableTokenIds.push(tokenId);
        }
    }

    function _markDead(uint256 tokenId) internal {
        for (uint256 i; i < shadows.length; i++) {
            if (shadows[i].tokenId == tokenId) {
                shadows[i].alive = false;
                return;
            }
        }
    }

    // ── Independent supply calculation ────────────────────────────────────

    /// @dev Compute expected supply by summing individual position biases.
    ///      For FILTER_ALL (global): bias_i = slope_i * max(0, end_i - t)
    ///      For FILTER_LOCKED/FORFEITABLE: bias_i = slope_i * max(0, subcurveEnd_i - t)
    ///      The subcurve uses min(end, transferableAfter) as the effective endpoint.
    function _expectedSupply(uint256 t, uint8 filter) internal view returns (uint256 total) {
        for (uint256 i; i < shadows.length; i++) {
            ShadowPosition memory s = shadows[i];
            if (!s.alive) continue;

            uint256 effectiveEnd;
            if (filter == FILTER_ALL) {
                effectiveEnd = s.end; // global curve uses lock.end
            } else if (filter == FILTER_LOCKED) {
                if (s.posType == PosType.Transferable) continue;
                effectiveEnd = s.subcurveEnd; // subcurves use min(end, transferableAfter)
            } else {
                if (s.posType != PosType.Forfeitable) continue;
                effectiveEnd = s.subcurveEnd;
            }

            if (effectiveEnd <= t) continue; // expired/exited at time t
            total += s.slope * (effectiveEnd - t);
        }
    }

    function _expectedTotalSupply(uint256 t) internal view returns (uint256) {
        return _expectedSupply(t, FILTER_ALL);
    }

    function _expectedNonTransferableSupply(uint256 t) internal view returns (uint256) {
        return _expectedSupply(t, FILTER_LOCKED);
    }

    function _expectedForfeitableSupply(uint256 t) internal view returns (uint256) {
        return _expectedSupply(t, FILTER_FORFEITABLE);
    }

    function _aliveCount() internal view returns (uint256 count) {
        for (uint256 i; i < shadows.length; i++) {
            if (shadows[i].alive) count++;
        }
    }

    // ── Verification helpers ─────────────────────────────────────────────

    /// @dev Full verification: exact equality against shadow + breakdown cross-check + token conservation.
    function _verify(string memory label) internal view {
        uint256 t = block.timestamp;

        uint256 expectedTotal = _expectedTotalSupply(t);
        uint256 expectedNonTransferable = _expectedNonTransferableSupply(t);
        uint256 expectedForfeitable = _expectedForfeitableSupply(t);

        // Exact equality against shadow accounting
        uint256 actualTotal = veHemi.totalVeHemiSupply();
        uint256 actualNonTransferable = veHemi.nonTransferableTotalVeHemiSupply();
        uint256 actualForfeitable = veHemi.forfeitableTotalVeHemiSupply();

        assertEq(actualTotal, expectedTotal, string.concat(label, ": total"));
        assertEq(actualNonTransferable, expectedNonTransferable, string.concat(label, ": locked"));
        assertEq(actualForfeitable, expectedForfeitable, string.concat(label, ": forfeitable"));

        // Ordering invariants
        assertLe(actualForfeitable, actualNonTransferable, string.concat(label, ": forfeitable <= locked"));
        assertLe(actualNonTransferable, actualTotal, string.concat(label, ": locked <= total"));

        // supplyBreakdown cross-check against individual functions
        (uint256 bdTotal, uint256 bdNonTransferable, uint256 bdForf, uint256 bdTrans) = veHemi.supplyBreakdown();
        assertEq(bdTotal, actualTotal, string.concat(label, ": breakdown total"));
        assertEq(bdNonTransferable, actualNonTransferable, string.concat(label, ": breakdown locked"));
        assertEq(bdForf, actualForfeitable, string.concat(label, ": breakdown forfeitable"));
        assertEq(bdTrans, actualTotal - actualNonTransferable, string.concat(label, ": breakdown transferable"));

        // Token conservation: totalLocked == HEMI balance held by contract
        assertEq(hemi.balanceOf(address(veHemi)), veHemi.totalLocked(), string.concat(label, ": token conservation"));

        // ERC-721 totalSupply matches alive position count
        assertEq(veHemi.totalSupply(), _aliveCount(), string.concat(label, ": NFT count"));
    }

    /// @dev Historical query verification with exact equality + ordering invariants.
    function _verifyAt(string memory label, uint256 t) internal view {
        uint256 expectedTotal = _expectedTotalSupply(t);
        uint256 expectedNonTransferable = _expectedNonTransferableSupply(t);
        uint256 expectedForfeitable = _expectedForfeitableSupply(t);

        uint256 actualTotal = veHemi.totalVeHemiSupplyAt(t);
        uint256 actualNonTransferable = veHemi.nonTransferableTotalVeHemiSupplyAt(t);
        uint256 actualForfeitable = veHemi.forfeitableTotalVeHemiSupplyAt(t);

        assertEq(actualTotal, expectedTotal, string.concat(label, ": total"));
        assertEq(actualNonTransferable, expectedNonTransferable, string.concat(label, ": locked"));
        assertEq(actualForfeitable, expectedForfeitable, string.concat(label, ": forfeitable"));

        // Ordering must hold at all historical timestamps too
        assertLe(actualForfeitable, actualNonTransferable, string.concat(label, ": hist forfeitable <= locked"));
        assertLe(actualNonTransferable, actualTotal, string.concat(label, ": hist locked <= total"));
    }

    /// @dev Verify WITHOUT a preceding checkpoint — forces the view functions to execute
    ///      their catchup loops (walking forward from the last stored epoch to block.timestamp).
    function _verifyWithoutCheckpoint(string memory label) internal view {
        uint256 t = block.timestamp;

        uint256 expectedTotal = _expectedTotalSupply(t);
        uint256 expectedNonTransferable = _expectedNonTransferableSupply(t);
        uint256 expectedForfeitable = _expectedForfeitableSupply(t);

        assertEq(veHemi.totalVeHemiSupply(), expectedTotal, string.concat(label, ": total (no cp)"));
        assertEq(veHemi.nonTransferableTotalVeHemiSupply(), expectedNonTransferable, string.concat(label, ": locked (no cp)"));
        assertEq(veHemi.forfeitableTotalVeHemiSupply(), expectedForfeitable, string.concat(label, ": forfeitable (no cp)"));
    }

    // ── Sort helper for seeding ──────────────────────────────────────────

    function _sortedNonTransferableTokenIds() internal view returns (uint256[] memory sorted) {
        sorted = new uint256[](nonTransferableTokenIds.length);
        for (uint256 i; i < nonTransferableTokenIds.length; i++) {
            sorted[i] = nonTransferableTokenIds[i];
        }
        for (uint256 i = 1; i < sorted.length; i++) {
            uint256 key = sorted[i];
            uint256 j = i;
            while (j > 0 && sorted[j - 1] > key) {
                sorted[j] = sorted[j - 1];
                j--;
            }
            sorted[j] = key;
        }
    }

    // ═════════════════════════════════════════════════════════════════════
    //  STRESS TEST: 100 MIXED POSITIONS
    // ═════════════════════════════════════════════════════════════════════

    function test_Stress_100MixedPositions() public {
        for (uint256 i; i < 100; i++) {
            address user = testUsers[i % testUsers.length];
            uint256 amount = MIN_AMOUNT + (i * 5 ether);
            uint256 duration = 2 * SIX_DAYS + (i * SIX_DAYS * 3);
            if (duration > MAX_TIME) duration = MAX_TIME;

            PosType ptype;
            if (i % 3 == 0) ptype = PosType.Transferable;
            else if (i % 3 == 1) ptype = PosType.Locked;
            else ptype = PosType.Forfeitable;

            _createPos(user, amount, duration, ptype);
        }

        veHemi.seedAndFinalizeNonTransferablePositions(_sortedNonTransferableTokenIds());
        _verify("After 100 positions + seed");

        uint256 t0 = block.timestamp;

        // Warp WITHOUT checkpoint first — exercise view catchup loops
        vm.warp(block.timestamp + 180 days);
        _verifyWithoutCheckpoint("180 days no checkpoint");

        // Now checkpoint and verify
        veHemi.checkpoint();
        _verify("After 180 day warp + checkpoint");

        // Historical query at t0
        _verifyAt("Historical at t0", t0);

        // Warp again
        uint256 t1 = block.timestamp;
        vm.warp(block.timestamp + 180 days);
        _verifyWithoutCheckpoint("360 days no checkpoint");
        veHemi.checkpoint();
        _verify("After 360 day warp");
        _verifyAt("Historical at t1", t1);
    }

    // ═════════════════════════════════════════════════════════════════════
    //  STRESS TEST: 200 POSITIONS WITH ALL MUTATIONS
    // ═════════════════════════════════════════════════════════════════════

    function test_Stress_200PositionsWithMutations() public {
        // Phase 1: Create 200 positions
        for (uint256 i; i < 200; i++) {
            address user = testUsers[i % testUsers.length];
            uint256 amount = MIN_AMOUNT + (i * 3 ether);
            uint256 duration = 2 * SIX_DAYS + (i * SIX_DAYS * 2);
            if (duration > MAX_TIME / 2) duration = MAX_TIME / 2;

            PosType ptype;
            if (i % 5 == 0) ptype = PosType.Transferable;
            else if (i % 5 <= 2) ptype = PosType.Locked;
            else ptype = PosType.Forfeitable;

            _createPos(user, amount, duration, ptype);
        }

        // Phase 2: Seed and snapshot
        veHemi.seedAndFinalizeNonTransferablePositions(_sortedNonTransferableTokenIds());
        _verify("After 200 positions + seed");

        // Snapshot t0 expected values BEFORE any mutations
        uint256 t0 = block.timestamp;
        uint256 t0ExpTotal = _expectedTotalSupply(t0);
        uint256 t0ExpNonTransferable = _expectedNonTransferableSupply(t0);
        uint256 t0ExpForf = _expectedForfeitableSupply(t0);

        // Phase 3: Warp 90 days
        vm.warp(block.timestamp + 90 days);
        _verifyWithoutCheckpoint("90 days no checkpoint");
        veHemi.checkpoint();
        _verify("After 90 day warp");

        // Phase 4: Forfeit 10 forfeitable positions
        uint256 forfeitCount;
        for (uint256 i; i < shadows.length && forfeitCount < 10; i++) {
            if (shadows[i].posType == PosType.Forfeitable && shadows[i].alive) {
                uint256 tid = shadows[i].tokenId;
                IVeHemi.LockedBalance memory lock = veHemi.getLockedBalance(tid);
                if (lock.end <= block.timestamp) continue;
                veHemi.forfeit(tid);
                _markDead(tid);
                forfeitCount++;
            }
        }
        _verify("After 10 forfeitures");

        // Phase 5: Create 50 more positions post-seeding
        for (uint256 i; i < 50; i++) {
            address user = testUsers[i % testUsers.length];
            uint256 amount = 50 ether + (i * 2 ether);
            uint256 duration = YEAR + (i * SIX_DAYS * 4);
            if (duration > MAX_TIME) duration = MAX_TIME;

            PosType ptype;
            if (i % 3 == 0) ptype = PosType.Transferable;
            else if (i % 3 == 1) ptype = PosType.Locked;
            else ptype = PosType.Forfeitable;

            _createPos(user, amount, duration, ptype);
        }
        _verify("After 50 post-seeding positions");

        // Phase 6: Increase amount on 20 positions
        uint256 increaseCount;
        for (uint256 i; i < shadows.length && increaseCount < 20; i++) {
            ShadowPosition storage s = shadows[i];
            if (!s.alive) continue;
            if (s.end <= block.timestamp) continue;

            uint256 addAmount = 25 ether;
            address owner = veHemi.ownerOf(s.tokenId);

            vm.startPrank(owner);
            hemi.mint(owner, addAmount);
            hemi.approve(address(veHemi), type(uint256).max);
            veHemi.increaseAmount(s.tokenId, addAmount);
            vm.stopPrank();

            // Update shadow slope from contract (avoids integer division mismatch)
            uint256 newAmount = uint256(int256(veHemi.getLockedBalance(s.tokenId).amount));
            s.slope = newAmount / MAX_TIME;

            increaseCount++;
        }
        _verify("After 20 increaseAmounts");

        // Phase 7: Increase unlock time on 15 positions
        uint256 extendCount;
        for (uint256 i; i < shadows.length && extendCount < 15; i++) {
            ShadowPosition storage s = shadows[i];
            if (!s.alive) continue;
            if (s.end <= block.timestamp) continue;

            uint256 currentDuration = s.end - block.timestamp;
            if (currentDuration + SIX_DAYS > MAX_TIME) continue; // can't extend further

            uint256 newDuration = currentDuration + YEAR / 2;
            if (newDuration > MAX_TIME) newDuration = MAX_TIME;

            address owner = veHemi.ownerOf(s.tokenId);
            vm.prank(owner);
            veHemi.increaseUnlockTime(s.tokenId, newDuration);

            // Update shadow end from contract
            s.end = veHemi.getLockedBalance(s.tokenId).end;

            extendCount++;
        }
        _verify("After 15 increaseUnlockTimes");

        // Phase 8: Warp 1 year
        vm.warp(block.timestamp + 365 days);
        _verifyWithoutCheckpoint("1 year no checkpoint");
        veHemi.checkpoint();
        _verify("After 1 year warp (some expired)");

        // Phase 9: Withdraw all expired positions
        for (uint256 i; i < shadows.length; i++) {
            ShadowPosition storage s = shadows[i];
            if (!s.alive) continue;
            if (s.end > block.timestamp) continue;

            address owner;
            try veHemi.ownerOf(s.tokenId) returns (address o) {
                owner = o;
            } catch {
                s.alive = false;
                continue;
            }

            vm.prank(owner);
            veHemi.withdraw(s.tokenId);
            s.alive = false;
        }
        _verify("After withdrawing all expired");

        // Phase 10: Verify historical queries at t0 using snapshotted expected values
        // (shadow was mutated by increaseAmount/increaseUnlockTime, so we use pre-mutation snapshots)
        assertEq(veHemi.totalVeHemiSupplyAt(t0), t0ExpTotal, "Historical total at t0");
        assertEq(veHemi.nonTransferableTotalVeHemiSupplyAt(t0), t0ExpNonTransferable, "Historical non-transferable at t0");
        assertEq(veHemi.forfeitableTotalVeHemiSupplyAt(t0), t0ExpForf, "Historical forfeitable at t0");

        // Phase 11: Final breakdown check
        (uint256 total, uint256 locked_, uint256 forfeitable_, uint256 transferable) = veHemi.supplyBreakdown();
        assertLe(forfeitable_, locked_, "Final: forfeitable <= locked");
        assertLe(locked_, total, "Final: locked <= total");
        assertEq(transferable, total - locked_, "Final: transferable = total - locked");
        assertEq(hemi.balanceOf(address(veHemi)), veHemi.totalLocked(), "Final: token conservation");
    }

    // ═════════════════════════════════════════════════════════════════════
    //  STRESS TEST: EXACT MULTI-BOUNDARY DECAY VERIFICATION
    // ═════════════════════════════════════════════════════════════════════

    function test_Stress_ExactDecayAtBoundaries() public {
        for (uint256 i; i < 30; i++) {
            address user = testUsers[i % testUsers.length];
            uint256 amount = 100 ether + (i * 10 ether);
            uint256 duration = (i + 1) * 2 * SIX_DAYS * 5;
            if (duration > MAX_TIME) duration = MAX_TIME;

            PosType ptype;
            if (i % 3 == 0) ptype = PosType.Transferable;
            else if (i % 3 == 1) ptype = PosType.Locked;
            else ptype = PosType.Forfeitable;

            _createPos(user, amount, duration, ptype);
        }

        veHemi.seedAndFinalizeNonTransferablePositions(_sortedNonTransferableTokenIds());
        _verify("Initial");

        // Check at every 30-day interval for 2 years
        // Alternate: checkpoint first vs verify without checkpoint
        uint256 startTime = block.timestamp;
        for (uint256 month = 1; month <= 24; month++) {
            vm.warp(startTime + month * 30 days);

            // Odd months: verify WITHOUT checkpoint (exercises view catchup loop)
            if (month % 2 == 1) {
                _verifyWithoutCheckpoint(string.concat("Month ", vm.toString(month), " (no cp)"));
            }

            // Then checkpoint and full verify
            veHemi.checkpoint();
            _verify(string.concat("Month ", vm.toString(month)));
        }
    }

    // ═════════════════════════════════════════════════════════════════════
    //  STRESS TEST: SAME-EXPIRY BOUNDARY ACCUMULATION
    // ═════════════════════════════════════════════════════════════════════

    /// @notice Multiple positions with the SAME expiry boundary. Verifies slope change
    ///         accumulation and exact supply drop at that boundary.
    function test_Stress_SameExpiryBoundary() public {
        // Create 20 positions all with LOCK_2Y — they'll all expire at the same SIX_DAYS boundary
        uint256 lockDuration = 2 * 365 days;
        for (uint256 i; i < 20; i++) {
            address user = testUsers[i % testUsers.length];
            uint256 amount = 50 ether + (i * 10 ether);

            PosType ptype;
            if (i % 3 == 0) ptype = PosType.Transferable;
            else if (i % 3 == 1) ptype = PosType.Locked;
            else ptype = PosType.Forfeitable;

            _createPos(user, amount, lockDuration, ptype);
        }

        veHemi.seedAndFinalizeNonTransferablePositions(_sortedNonTransferableTokenIds());
        _verify("After same-expiry creation");

        // All positions should share the same end time
        uint256 sharedEnd = shadows[0].end;
        for (uint256 i = 1; i < shadows.length; i++) {
            assertEq(shadows[i].end, sharedEnd, "All should share the same end");
        }

        // Warp to just before expiry
        vm.warp(sharedEnd - 1);
        veHemi.checkpoint();
        _verify("Just before shared expiry");
        assertGt(veHemi.totalVeHemiSupply(), 0, "Should still have supply");

        // Warp to exactly at expiry
        vm.warp(sharedEnd);
        veHemi.checkpoint();
        _verify("At shared expiry");
        assertEq(veHemi.totalVeHemiSupply(), 0, "All expired at same boundary");
        assertEq(veHemi.nonTransferableTotalVeHemiSupply(), 0, "Locked all expired");
        assertEq(veHemi.forfeitableTotalVeHemiSupply(), 0, "Forfeitable all expired");
    }

    // ═════════════════════════════════════════════════════════════════════
    //  FUZZ STRESS: RANDOM MIXED POSITIONS WITH VERIFICATION
    // ═════════════════════════════════════════════════════════════════════

    function testFuzz_Stress_MixedPositions(uint256 seed) public {
        seed = bound(seed, 1, type(uint128).max);

        uint256 numPositions = 20 + (seed % 31);
        uint256 rng = seed;

        for (uint256 i; i < numPositions; i++) {
            rng = uint256(keccak256(abi.encode(rng, i)));
            address user = testUsers[rng % testUsers.length];

            uint256 amount = MIN_AMOUNT + (rng % 490 ether);
            rng = uint256(keccak256(abi.encode(rng)));

            uint256 duration = 2 * SIX_DAYS + (rng % (MAX_TIME / 2));
            rng = uint256(keccak256(abi.encode(rng)));

            PosType ptype = PosType(rng % 3);
            rng = uint256(keccak256(abi.encode(rng)));

            _createPos(user, amount, duration, ptype);
        }

        if (nonTransferableTokenIds.length > 0) {
            veHemi.seedAndFinalizeNonTransferablePositions(_sortedNonTransferableTokenIds());
        }

        _verify("After fuzzed creation");

        // Warp WITHOUT checkpoint first (exercise view catchup)
        uint256 warpAmount = 1 days + (seed % 365 days);
        vm.warp(block.timestamp + warpAmount);
        _verifyWithoutCheckpoint("After fuzzed warp (no cp)");

        // Checkpoint and full verify
        veHemi.checkpoint();
        _verify("After fuzzed warp + checkpoint");
    }
}
