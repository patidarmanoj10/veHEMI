// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import "./NonTransferableCurveTestBase.sol";
import "../src/storage/VeHemiStorageV2.sol";

/// @title VeHemiNonTransferableCurveTest
/// @notice Tests for VeHemi V2 non-transferable curve: non-transferrable position weight tracking.
///
/// Test categories:
///   1. Initialization & Seeding (seedAndFinalizeNonTransferablePositions)
///   2. Basic Locked Supply (nonTransferableTotalVeHemiSupply, supplyBreakdown)
///   3. increaseAmount (non-transferable curve updated for non-transferrable positions)
///   4. increaseUnlockTime (non-transferable curve unchanged, global curve extended)
///   5. (Slash tests removed -- require restaking infrastructure, tested separately)
///   6. Withdraw & Forfeit (non-transferable curve decremented on position exit)
///   7. Historical Queries (nonTransferableTotalVeHemiSupplyAt)
///   8. Catchup Loop (non-transferable curve tracks across SIX_DAYS boundaries)
///   9. Edge Cases & Reverts
contract VeHemiNonTransferableCurveTest is NonTransferableCurveTestBase {
    // ── Constants ────────────────────────────────────────────────────────
    uint256 constant LOCK_2Y = 2 * 365 days;
    uint256 constant LOCK_3Y = 3 * 365 days;

    // ── Helper: create a non-transferrable lock ──────────────────────────
    function createNonTransferablePosition(
        address account_,
        uint256 amount_,
        uint256 duration_
    ) public returns (uint256 _tokenId, uint256 _slope, uint256 _end) {
        vm.startPrank(account_);
        hemi.mint(account_, amount_);
        hemi.approve(address(veHemi), type(uint256).max);
        _tokenId = veHemi.createLockFor(amount_, duration_, account_, false, false);
        vm.stopPrank();
        _slope = amount_ / MAX_TIME;
        _end = veHemi.getLockedBalance(_tokenId).end;
    }

    // ── Helper: create a non-transferrable forfeitable lock ──────────────
    function createNonTransferableForfeitablePosition(
        address account_,
        uint256 amount_,
        uint256 duration_
    ) public returns (uint256 _tokenId, uint256 _slope, uint256 _end) {
        vm.startPrank(account_);
        hemi.mint(account_, amount_);
        hemi.approve(address(veHemi), type(uint256).max);
        _tokenId = veHemi.createLockFor(amount_, duration_, account_, false, true);
        vm.stopPrank();
        _slope = amount_ / MAX_TIME;
        _end = veHemi.getLockedBalance(_tokenId).end;
    }

    // ── Helper: seed and finalize a set of non-transferable positions ──────────────
    function seedAndFinalize(uint256[] memory tokenIds_) public {
        veHemi.seedAndFinalizeNonTransferablePositions(tokenIds_);
    }

    // ── Helper: build a single-element array ─────────────────────────────
    function _toArray(uint256 a) internal pure returns (uint256[] memory arr) {
        arr = new uint256[](1);
        arr[0] = a;
    }

    function _toArray(uint256 a, uint256 b) internal pure returns (uint256[] memory arr) {
        arr = new uint256[](2);
        arr[0] = a;
        arr[1] = b;
    }

    function _toArray(uint256 a, uint256 b, uint256 c) internal pure returns (uint256[] memory arr) {
        arr = new uint256[](3);
        arr[0] = a;
        arr[1] = b;
        arr[2] = c;
    }

    // ═════════════════════════════════════════════════════════════════════
    //  1. INITIALIZATION & SEEDING
    // ═════════════════════════════════════════════════════════════════════

    function test_SeedAndFinalize_Basic() public {
        (uint256 t1,,) = createNonTransferablePosition(alice, 100 ether, LOCK_2Y);

        assertFalse(veHemi.nonTransferableSeedingFinalized(), "Should not be finalized yet");

        veHemi.seedAndFinalizeNonTransferablePositions(_toArray(t1));

        assertTrue(veHemi.nonTransferableSeedingFinalized(), "Should be finalized");
    }

    function test_SeedAndFinalize_MultiplePositions() public {
        (uint256 t1, uint256 s1, uint256 e1) = createNonTransferablePosition(alice, 100 ether, LOCK_2Y);
        (uint256 t2, uint256 s2, uint256 e2) = createNonTransferablePosition(bob, 200 ether, MAX_TIME);

        seedAndFinalize(_toArray(t1, t2));

        // Non-transferable supply should reflect both positions
        uint256 nonTransferableSupply = veHemi.nonTransferableTotalVeHemiSupply();
        uint256 expectedBias = s1 * (e1 - block.timestamp) + s2 * (e2 - block.timestamp);
        assertEq(nonTransferableSupply, expectedBias, "Non-transferable supply should match seeded positions");
    }

    function test_SeedAndFinalize_SkipsExpiredPositions() public {
        // Create a position that will expire before seeding
        (uint256 t1,,) = createNonTransferablePosition(alice, 100 ether, 2 * SIX_DAYS);
        (uint256 t2, uint256 s2, uint256 e2) = createNonTransferablePosition(bob, 200 ether, LOCK_2Y);

        // Warp past t1's expiry
        uint256 newTime = veHemi.getLockedBalance(t1).end + 1;
        vm.warp(newTime);

        seedAndFinalize(_toArray(t1, t2));

        // Only t2 should be counted
        uint256 nonTransferableSupply = veHemi.nonTransferableTotalVeHemiSupply();
        uint256 expectedBias = s2 * (e2 - block.timestamp);
        assertEq(nonTransferableSupply, expectedBias, "Expired position should be skipped");
    }

    function test_SeedAndFinalize_RevertsIfTransferable() public {
        // Create a transferable lock
        (uint256 tokenId,,) = createLock(alice, 100 ether, LOCK_2Y);

        vm.expectRevert(VeHemi.NotNonTransferrable.selector);
        veHemi.seedAndFinalizeNonTransferablePositions(_toArray(tokenId));
    }

    function test_SeedAndFinalize_RevertsIfEmpty() public {
        uint256[] memory empty = new uint256[](0);
        vm.expectRevert(VeHemi.EmptyArray.selector);
        veHemi.seedAndFinalizeNonTransferablePositions(empty);
    }

    function test_SeedAndFinalize_RevertsAfterFinalized() public {
        (uint256 t1,,) = createNonTransferablePosition(alice, 100 ether, LOCK_2Y);
        seedAndFinalize(_toArray(t1));

        (uint256 t2,,) = createNonTransferablePosition(bob, 200 ether, LOCK_2Y);
        vm.expectRevert(VeHemi.SeedingAlreadyFinalized.selector);
        veHemi.seedAndFinalizeNonTransferablePositions(_toArray(t2));
    }

    function test_SeedAndFinalize_RevertsIfNotOwner() public {
        (uint256 t1,,) = createNonTransferablePosition(alice, 100 ether, LOCK_2Y);

        vm.prank(alice);
        vm.expectRevert();
        veHemi.seedAndFinalizeNonTransferablePositions(_toArray(t1));
    }

    function test_SeedAndFinalize_EmitsEvent() public {
        (uint256 t1,,) = createNonTransferablePosition(alice, 100 ether, LOCK_2Y);

        // _checkpoint inside seedAndFinalize may advance the epoch
        veHemi.checkpoint(); // ensure epoch is current
        uint256 expectedEpoch = veHemi.epoch();

        vm.expectEmit();
        emit IVeHemi.NonTransferableSeedingFinalized(expectedEpoch);
        veHemi.seedAndFinalizeNonTransferablePositions(_toArray(t1));
    }

    function test_SeedAndFinalize_WritesNonTransferableSlopeChanges() public {
        (uint256 t1, uint256 s1, uint256 e1) = createNonTransferablePosition(alice, 100 ether, LOCK_2Y);
        (uint256 t2, uint256 s2, uint256 e2) = createNonTransferablePosition(bob, 200 ether, MAX_TIME);

        seedAndFinalize(_toArray(t1, t2));

        // nonTransferableSlopeChanges should have negative slope at each lock end
        assertEq(
            veHemi.nonTransferableSlopeChanges(e1),
            -int128(int256(s1)),
            "nonTransferableSlopeChanges at t1 end"
        );

        // If both end at same time they stack; otherwise separate
        if (e1 == e2) {
            assertEq(
                veHemi.nonTransferableSlopeChanges(e1),
                -int128(int256(s1 + s2)),
                "nonTransferableSlopeChanges at shared end"
            );
        } else {
            assertEq(
                veHemi.nonTransferableSlopeChanges(e2),
                -int128(int256(s2)),
                "nonTransferableSlopeChanges at t2 end"
            );
        }
    }

    // ═════════════════════════════════════════════════════════════════════
    //  2. BASIC LOCKED SUPPLY
    // ═════════════════════════════════════════════════════════════════════

    function test_NonTransferableTotalVeHemiSupply_ZeroBeforeFinalization() public view {
        // Before finalization, non-transferable supply should be 0
        assertEq(
            veHemi.nonTransferableTotalVeHemiSupply(),
            0,
            "Non-transferable supply should be 0 before finalization"
        );
    }

    function test_NonTransferableTotalVeHemiSupply_AfterFinalization() public {
        (uint256 t1, uint256 s1, uint256 e1) = createNonTransferablePosition(alice, 100 ether, LOCK_2Y);
        seedAndFinalize(_toArray(t1));

        uint256 nonTransferableSupply = veHemi.nonTransferableTotalVeHemiSupply();
        uint256 expectedBias = s1 * (e1 - block.timestamp);
        assertEq(nonTransferableSupply, expectedBias, "Non-transferable supply should match seeded bias");
    }

    function test_SupplyBreakdown_OnlyTransferable() public {
        // Create only transferable positions
        createLock(alice, 100 ether, LOCK_2Y);

        // Seed and finalize with a dummy non-transferable position first to enable tracking
        (uint256 t1,,) = createNonTransferablePosition(bob, 10 ether, LOCK_2Y);
        seedAndFinalize(_toArray(t1));

        (uint256 total, uint256 locked_, uint256 forfeitable_, uint256 transferable) = veHemi.supplyBreakdown();
        assertEq(forfeitable_, 0, "No forfeitable positions in this test");
        assertGt(total, 0, "Total should be positive");
        assertGt(locked_, 0, "Non-transferable should include bob's position");
        assertEq(transferable, total - locked_, "transferable = total - locked");
        assertGt(transferable, 0, "Transferable should be positive");
    }

    function test_SupplyBreakdown_MixedPositions() public {
        (uint256 t1,,) = createNonTransferablePosition(alice, 100 ether, LOCK_2Y);
        createLock(bob, 100 ether, LOCK_2Y); // transferable
        seedAndFinalize(_toArray(t1));

        (uint256 total, uint256 locked_, uint256 forfeitable_, uint256 transferable) = veHemi.supplyBreakdown();
        assertEq(forfeitable_, 0, "No forfeitable positions in this test");
        assertGt(total, 0, "Total should be positive");
        assertGt(locked_, 0, "Non-transferable should be positive");
        assertGt(transferable, 0, "Transferable should be positive");
        assertEq(total, locked_ + transferable, "total = locked + transferable");
    }

    function test_SupplyBreakdown_NonTransferableCappedAtTotal() public {
        // Edge case: with rounding, locked could theoretically exceed total.
        // The contract caps locked <= total.
        (uint256 t1,,) = createNonTransferablePosition(alice, 100 ether, LOCK_2Y);
        seedAndFinalize(_toArray(t1));

        (uint256 total, uint256 locked_, uint256 forfeitable_,) = veHemi.supplyBreakdown();
        assertEq(forfeitable_, 0, "No forfeitable positions in this test");
        assertLe(locked_, total, "Locked must not exceed total");
    }

    function test_NonTransferableTotalVeHemiSupply_DecaysOverTime() public {
        (uint256 t1,,) = createNonTransferablePosition(alice, 100 ether, LOCK_2Y);
        seedAndFinalize(_toArray(t1));

        uint256 supplyNow = veHemi.nonTransferableTotalVeHemiSupply();

        vm.warp(block.timestamp + 365 days);
        veHemi.checkpoint();

        uint256 supplyLater = veHemi.nonTransferableTotalVeHemiSupply();
        assertLt(supplyLater, supplyNow, "Non-transferable supply should decay over time");
    }

    function test_NonTransferableTotalVeHemiSupply_GoesToZeroAtExpiry() public {
        (uint256 t1,, uint256 e1) = createNonTransferablePosition(alice, 100 ether, LOCK_2Y);
        seedAndFinalize(_toArray(t1));

        vm.warp(e1 + 1);
        veHemi.checkpoint();

        assertEq(
            veHemi.nonTransferableTotalVeHemiSupply(),
            0,
            "Non-transferable supply should be 0 after all positions expire"
        );
    }

    // ═════════════════════════════════════════════════════════════════════
    //  3. increaseAmount — LOCKED CURVE UPDATES
    // ═════════════════════════════════════════════════════════════════════

    function test_IncreaseAmount_UpdatesNonTransferableCurve() public {
        (uint256 t1,,) = createNonTransferablePosition(alice, 100 ether, LOCK_2Y);
        seedAndFinalize(_toArray(t1));

        uint256 nonTransferableSupplyBefore = veHemi.nonTransferableTotalVeHemiSupply();

        // Increase amount — alice adds 50 HEMI
        vm.startPrank(alice);
        hemi.mint(alice, 50 ether);
        hemi.approve(address(veHemi), type(uint256).max);
        veHemi.increaseAmount(t1, 50 ether);
        vm.stopPrank();

        uint256 nonTransferableSupplyAfter = veHemi.nonTransferableTotalVeHemiSupply();
        assertGt(nonTransferableSupplyAfter, nonTransferableSupplyBefore, "Non-transferable supply should increase after increaseAmount");
    }

    function test_IncreaseAmount_TransferableDoesNotAffectNonTransferableCurve() public {
        (uint256 tNonTransferable,,) = createNonTransferablePosition(alice, 100 ether, LOCK_2Y);
        (uint256 tTransferable,,) = createLock(bob, 100 ether, LOCK_2Y);
        seedAndFinalize(_toArray(tNonTransferable));

        uint256 nonTransferableSupplyBefore = veHemi.nonTransferableTotalVeHemiSupply();

        // Bob increases his transferable lock
        vm.startPrank(bob);
        hemi.mint(bob, 50 ether);
        hemi.approve(address(veHemi), type(uint256).max);
        veHemi.increaseAmount(tTransferable, 50 ether);
        vm.stopPrank();

        uint256 nonTransferableSupplyAfter = veHemi.nonTransferableTotalVeHemiSupply();
        assertEq(nonTransferableSupplyAfter, nonTransferableSupplyBefore, "Non-transferable supply should NOT change for transferable position");
    }

    function test_IncreaseAmount_NonTransferableCurveMatchesExpected() public {
        (uint256 t1,,) = createNonTransferablePosition(alice, 100 ether, LOCK_2Y);
        seedAndFinalize(_toArray(t1));

        vm.startPrank(alice);
        hemi.mint(alice, 50 ether);
        hemi.approve(address(veHemi), type(uint256).max);
        veHemi.increaseAmount(t1, 50 ether);
        vm.stopPrank();

        uint256 lockEnd = veHemi.getLockedBalance(t1).end;
        uint256 expectedSlope = 150 ether / MAX_TIME;
        uint256 expectedBias = expectedSlope * (lockEnd - block.timestamp);
        assertEq(
            veHemi.nonTransferableTotalVeHemiSupply(),
            expectedBias,
            "Non-transferable supply should match new slope * remaining time"
        );
    }

    // ═════════════════════════════════════════════════════════════════════
    //  4. increaseUnlockTime — LOCKED CURVE UNCHANGED, GLOBAL CURVE EXTENDED
    // ═════════════════════════════════════════════════════════════════════

    function test_IncreaseUnlockTime_NonTransferableSupplyUnchanged() public {
        (uint256 t1,,) = createNonTransferablePosition(alice, 100 ether, LOCK_2Y);
        seedAndFinalize(_toArray(t1));

        uint256 nonTransferableSupplyBefore = veHemi.nonTransferableTotalVeHemiSupply();
        uint256 globalBefore = veHemi.totalVeHemiSupply();

        vm.prank(alice);
        veHemi.increaseUnlockTime(t1, LOCK_3Y);

        uint256 nonTransferableSupplyAfter = veHemi.nonTransferableTotalVeHemiSupply();
        uint256 globalAfter = veHemi.totalVeHemiSupply();

        // Non-transferable supply should NOT change — subcurve is bounded by transferableAfter (original end)
        assertEq(nonTransferableSupplyAfter, nonTransferableSupplyBefore, "Non-transferable supply should NOT change when extending lock");

        // Global supply SHOULD increase — global curve uses lock.end
        assertGt(globalAfter, globalBefore, "Global supply should increase after longer lock");
    }

    function test_IncreaseUnlockTime_TransferableAfterUnchanged() public {
        (uint256 t1,,) = createNonTransferablePosition(alice, 100 ether, LOCK_2Y);
        seedAndFinalize(_toArray(t1));

        uint256 originalTransferableAfter = veHemi.transferableAfter(t1);
        uint256 oldEnd = veHemi.getLockedBalance(t1).end;
        assertEq(originalTransferableAfter, oldEnd, "transferableAfter should equal original lock end");

        vm.prank(alice);
        veHemi.increaseUnlockTime(t1, LOCK_3Y);

        uint256 newEnd = veHemi.getLockedBalance(t1).end;
        assertGt(newEnd, oldEnd, "Lock end should increase");

        // transferableAfter should NOT change
        assertEq(veHemi.transferableAfter(t1), originalTransferableAfter, "transferableAfter should NOT change");

        // Position becomes transferable after original transferableAfter
        vm.warp(originalTransferableAfter + 1);
        assertTrue(veHemi.isTransferable(t1), "Should be transferable after original transferableAfter");

        // But the lock is still active (voting power remains until newEnd)
        uint256 votingPower = veHemi.balanceOfNFT(t1);
        assertGt(votingPower, 0, "Voting power should remain until new lock end");
    }

    function test_IncreaseUnlockTime_DoesNotEmitTransferableAfterUpdated() public {
        (uint256 t1,,) = createNonTransferablePosition(alice, 100 ether, LOCK_2Y);
        seedAndFinalize(_toArray(t1));

        // Record all logs emitted during increaseUnlockTime
        vm.recordLogs();
        vm.prank(alice);
        veHemi.increaseUnlockTime(t1, LOCK_3Y);

        Vm.Log[] memory logs = vm.getRecordedLogs();

        // Verify TransferableAfterUpdated was NOT emitted
        bytes32 transferableAfterUpdatedSig = keccak256("TransferableAfterUpdated(uint256,uint256,uint256)");
        for (uint256 i; i < logs.length; ++i) {
            assertTrue(
                logs[i].topics[0] != transferableAfterUpdatedSig,
                "TransferableAfterUpdated should NOT be emitted"
            );
        }
    }

    function test_IncreaseUnlockTime_TransferablePositionNoTransferableAfterEvent() public {
        (uint256 tTransferable,,) = createLock(alice, 100 ether, LOCK_2Y);
        (uint256 tNonTransferable,,) = createNonTransferablePosition(bob, 10 ether, LOCK_2Y);
        seedAndFinalize(_toArray(tNonTransferable));

        // Transferable position: transferableAfter is 0, so no event emitted
        // We just verify it doesn't revert and the lock end is updated
        vm.prank(alice);
        veHemi.increaseUnlockTime(tTransferable, LOCK_3Y);

        assertTrue(veHemi.isTransferable(tTransferable), "Should still be transferable");
    }

    function test_IncreaseUnlockTime_NonTransferableSlopeChangeStaysAtOriginalEnd() public {
        (uint256 t1, uint256 s1,) = createNonTransferablePosition(alice, 100 ether, LOCK_2Y);
        seedAndFinalize(_toArray(t1));

        uint256 oldEnd = veHemi.getLockedBalance(t1).end;

        vm.prank(alice);
        veHemi.increaseUnlockTime(t1, LOCK_3Y);

        uint256 newEnd = veHemi.getLockedBalance(t1).end;
        assertGt(newEnd, oldEnd, "Lock end should have moved forward");

        // Non-transferable slope change should REMAIN at the original end (transferableAfter)
        int128 nonTransferableSlopeAtOldEnd = veHemi.nonTransferableSlopeChanges(oldEnd);
        assertLt(nonTransferableSlopeAtOldEnd, 0, "nonTransferableSlopeChanges at original end should still be negative");

        // NO non-transferable slope change should exist at the new end
        int128 nonTransferableSlopeAtNewEnd = veHemi.nonTransferableSlopeChanges(newEnd);
        assertEq(nonTransferableSlopeAtNewEnd, 0, "nonTransferableSlopeChanges at new end should be 0");
    }

    // ═════════════════════════════════════════════════════════════════════
    //  5. SLASH — LOCKED CURVE UPDATES
    // ═════════════════════════════════════════════════════════════════════

    // NOTE: Slash tests removed — they require restaking infrastructure (MockRestakeManager,
    // VeHemi.slash). They will be restored when the restaking feature branch is merged.
    // See the full test suite in the backup stash for the 6 removed slash tests.

    // ═════════════════════════════════════════════════════════════════════
    //  6. WITHDRAW & FORFEIT — LOCKED CURVE DECREMENTED
    // ═════════════════════════════════════════════════════════════════════

    function test_Withdraw_ReducesNonTransferableCurve() public {
        (uint256 t1,, uint256 e1) = createNonTransferablePosition(alice, 100 ether, LOCK_2Y);
        (uint256 t2,,) = createNonTransferablePosition(bob, 100 ether, MAX_TIME);
        seedAndFinalize(_toArray(t1, t2));

        uint256 nonTransferableSupplyBefore = veHemi.nonTransferableTotalVeHemiSupply();

        // Wait for t1 to expire
        vm.warp(e1 + 1);

        // Withdraw — non-transferable curve already decayed to 0 for this position,
        // but the checkpoint still runs
        vm.prank(alice);
        veHemi.withdraw(t1);

        // Supply should be bob's position only (decayed to current time)
        uint256 nonTransferableSupplyAfter = veHemi.nonTransferableTotalVeHemiSupply();
        assertLt(nonTransferableSupplyAfter, nonTransferableSupplyBefore, "Non-transferable supply should decrease after time + withdraw");
    }

    function test_Forfeit_ReducesNonTransferableCurve() public {
        // Set forfeit admin
        veHemi.updateForfeitAdmin(admin);

        (uint256 t1,,) = createNonTransferableForfeitablePosition(alice, 100 ether, LOCK_2Y);
        (uint256 t2,,) = createNonTransferablePosition(bob, 100 ether, MAX_TIME);
        seedAndFinalize(_toArray(t1, t2));

        uint256 nonTransferableSupplyBefore = veHemi.nonTransferableTotalVeHemiSupply();

        // Forfeit t1 (still active, not expired)
        veHemi.forfeit(t1);

        uint256 nonTransferableSupplyAfter = veHemi.nonTransferableTotalVeHemiSupply();
        assertLt(nonTransferableSupplyAfter, nonTransferableSupplyBefore, "Non-transferable supply should decrease after forfeit");
    }

    // ═════════════════════════════════════════════════════════════════════
    //  7. HISTORICAL QUERIES
    // ═════════════════════════════════════════════════════════════════════

    function test_NonTransferableTotalVeHemiSupplyAt_PastTimestamp() public {
        (uint256 t1,,) = createNonTransferablePosition(alice, 100 ether, LOCK_2Y);
        seedAndFinalize(_toArray(t1));

        uint256 tCreate = block.timestamp;
        uint256 supplyAtCreate = veHemi.nonTransferableTotalVeHemiSupply();

        // Warp forward and checkpoint to record history
        vm.warp(block.timestamp + 30 days);
        veHemi.checkpoint();

        // Query the past supply
        uint256 pastSupply = veHemi.nonTransferableTotalVeHemiSupplyAt(tCreate);
        assertEq(pastSupply, supplyAtCreate, "Past non-transferable supply should match snapshot");
    }

    function test_NonTransferableTotalVeHemiSupplyAt_FutureDecay() public {
        (uint256 t1,, uint256 e1) = createNonTransferablePosition(alice, 100 ether, LOCK_2Y);
        seedAndFinalize(_toArray(t1));

        uint256 supplyNow = veHemi.nonTransferableTotalVeHemiSupply();

        // Query future (before expiry) — should show decayed value
        uint256 futureTime = block.timestamp + 365 days;
        uint256 supplyFuture = veHemi.nonTransferableTotalVeHemiSupplyAt(futureTime);
        assertLt(supplyFuture, supplyNow, "Future non-transferable supply should be less (decay)");

        // Query after expiry — should be 0
        uint256 supplyAfterExpiry = veHemi.nonTransferableTotalVeHemiSupplyAt(e1 + 1);
        assertEq(supplyAfterExpiry, 0, "Non-transferable supply after expiry should be 0");
    }

    function test_NonTransferableTotalVeHemiSupplyAt_BeforeV2IsZero() public {
        // Query timestamp 0 (pre-V2)
        assertEq(
            veHemi.nonTransferableTotalVeHemiSupplyAt(0),
            0,
            "Pre-V2 non-transferable supply should be 0"
        );
    }

    // ═════════════════════════════════════════════════════════════════════
    //  8. CATCHUP LOOP — LOCKED CURVE ACROSS BOUNDARIES
    // ═════════════════════════════════════════════════════════════════════

    function test_CatchupLoop_NonTransferableCurveTracksAcrossBoundaries() public {
        (uint256 t1,,) = createNonTransferablePosition(alice, 100 ether, LOCK_2Y);
        seedAndFinalize(_toArray(t1));

        // Warp past multiple SIX_DAYS boundaries
        vm.warp(block.timestamp + 30 days);
        veHemi.checkpoint();

        // Non-transferable supply should still be consistent with global tracking
        uint256 totalSupply = veHemi.totalVeHemiSupply();
        uint256 nonTransferableSupply = veHemi.nonTransferableTotalVeHemiSupply();
        assertGt(nonTransferableSupply, 0, "Non-transferable supply should be positive after catchup");
        assertLe(nonTransferableSupply, totalSupply, "Non-transferable supply should not exceed total");
    }

    function test_CatchupLoop_NonTransferableCurveConsistentWithGlobal() public {
        // Only non-transferable positions — non-transferable supply should equal total supply
        (uint256 t1,,) = createNonTransferablePosition(alice, 100 ether, LOCK_2Y);
        seedAndFinalize(_toArray(t1));

        // Multiple checkpoints across time
        for (uint256 i; i < 5; ++i) {
            vm.warp(block.timestamp + 7 days);
            veHemi.checkpoint();

            uint256 total = veHemi.totalVeHemiSupply();
            uint256 locked_ = veHemi.nonTransferableTotalVeHemiSupply();
            assertEq(locked_, total, "Non-transferable should equal total when only non-transferable positions exist");
        }
    }

    function test_CatchupLoop_MixedPositionsConsistency() public {
        (uint256 tNonTransferable,,) = createNonTransferablePosition(alice, 100 ether, LOCK_2Y);
        createLock(bob, 100 ether, LOCK_2Y); // transferable
        seedAndFinalize(_toArray(tNonTransferable));

        for (uint256 i; i < 5; ++i) {
            vm.warp(block.timestamp + 7 days);
            veHemi.checkpoint();

            (uint256 total, uint256 locked_, uint256 forfeitable_, uint256 transferable) = veHemi.supplyBreakdown();
        assertEq(forfeitable_, 0, "No forfeitable positions in this test");
            assertEq(total, locked_ + transferable, "total = locked + transferable");
            assertGt(locked_, 0, "Non-transferable should be positive during lock");
            assertGt(transferable, 0, "Transferable should be positive during lock");
        }
    }

    function test_CatchupLoop_LargeTimeGap() public {
        (uint256 t1,,) = createNonTransferablePosition(alice, 100 ether, MAX_TIME);
        seedAndFinalize(_toArray(t1));

        // Warp 2 years — will trigger many iterations in the catchup loop
        vm.warp(block.timestamp + 2 * 365 days);
        veHemi.checkpoint();

        uint256 total = veHemi.totalVeHemiSupply();
        uint256 locked_ = veHemi.nonTransferableTotalVeHemiSupply();
        assertEq(locked_, total, "Non-transferable should equal total with only non-transferable positions");
        assertGt(locked_, 0, "Non-transferable should still be positive (lock not expired)");
    }

    // ═════════════════════════════════════════════════════════════════════
    //  9. EDGE CASES & REVERTS
    // ═════════════════════════════════════════════════════════════════════

    function test_NewNonTransferablePosition_AfterFinalization_TrackedInNonTransferableCurve() public {
        // Seed and finalize with one position
        (uint256 t1,,) = createNonTransferablePosition(alice, 100 ether, LOCK_2Y);
        seedAndFinalize(_toArray(t1));

        uint256 nonTransferableSupplyBefore = veHemi.nonTransferableTotalVeHemiSupply();

        // Create a new non-transferable position after finalization
        (uint256 t2,,) = createNonTransferablePosition(bob, 200 ether, MAX_TIME);

        uint256 nonTransferableSupplyAfter = veHemi.nonTransferableTotalVeHemiSupply();
        assertGt(nonTransferableSupplyAfter, nonTransferableSupplyBefore, "New non-transferable position should be tracked");
    }

    function test_NewTransferablePosition_AfterFinalization_NotInNonTransferableCurve() public {
        (uint256 t1,,) = createNonTransferablePosition(alice, 100 ether, LOCK_2Y);
        seedAndFinalize(_toArray(t1));

        uint256 nonTransferableSupplyBefore = veHemi.nonTransferableTotalVeHemiSupply();

        // Create a transferable position
        createLock(bob, 200 ether, MAX_TIME);

        uint256 nonTransferableSupplyAfter = veHemi.nonTransferableTotalVeHemiSupply();
        assertEq(nonTransferableSupplyAfter, nonTransferableSupplyBefore, "Transferable position should not affect non-transferable supply");
    }

    function test_NonTransferableCurve_BeforeFinalization_NoTracking() public {
        // Create positions but don't finalize
        (uint256 t1,,) = createNonTransferablePosition(alice, 100 ether, LOCK_2Y);

        // Non-transferable supply should be 0 — tracking not active
        assertEq(veHemi.nonTransferableTotalVeHemiSupply(), 0, "No tracking before finalization");

        // Create another position
        createNonTransferablePosition(bob, 200 ether, MAX_TIME);
        assertEq(veHemi.nonTransferableTotalVeHemiSupply(), 0, "Still no tracking");
    }

    function test_Checkpoint_DoesNotAffectNonTransferableCurve_BeforeFinalization() public {
        createNonTransferablePosition(alice, 100 ether, LOCK_2Y);

        vm.warp(block.timestamp + 30 days);
        veHemi.checkpoint();

        assertEq(
            veHemi.nonTransferableTotalVeHemiSupply(),
            0,
            "Checkpoint before finalization should not create non-transferable curve"
        );
    }

    function test_SeedAndFinalize_WorksAfterCheckpointAdvancesEpoch() public {
        // Test that atomic seeding works correctly even when a checkpoint has
        // advanced the epoch (the internal _checkpoint call handles this).
        (uint256 t1, uint256 s1, uint256 e1) = createNonTransferablePosition(alice, 100 ether, LOCK_2Y);
        (uint256 t2, uint256 s2, uint256 e2) = createNonTransferablePosition(bob, 200 ether, MAX_TIME);

        // Trigger new epoch via checkpoint (warp to next boundary)
        vm.warp(block.timestamp + SIX_DAYS);
        veHemi.checkpoint();
        uint256 epochBefore = veHemi.epoch();

        seedAndFinalize(_toArray(t1, t2));

        // Non-transferable supply should be correct at the current timestamp
        uint256 nonTransferableSupply = veHemi.nonTransferableTotalVeHemiSupply();
        uint256 expectedBias = s1 * (e1 - block.timestamp) + s2 * (e2 - block.timestamp);
        assertEq(nonTransferableSupply, expectedBias, "Non-transferable supply should match after epoch advance");
    }

    function test_NonTransferableSupplyBreakdown_AllPositionsExpired() public {
        (uint256 t1,, uint256 e1) = createNonTransferablePosition(alice, 100 ether, 2 * SIX_DAYS);
        seedAndFinalize(_toArray(t1));

        vm.warp(e1 + 1);
        veHemi.checkpoint();

        (uint256 total, uint256 locked_, uint256 forfeitable_, uint256 transferable) = veHemi.supplyBreakdown();
        assertEq(forfeitable_, 0, "No forfeitable positions in this test");
        assertEq(total, 0, "Total should be 0");
        assertEq(locked_, 0, "Non-transferable should be 0");
        assertEq(transferable, 0, "Transferable should be 0");
    }

    // ═════════════════════════════════════════════════════════════════════
    //  10. FUZZ TESTS
    // ═════════════════════════════════════════════════════════════════════

    function testFuzz_NonTransferableSupplyLeTotalSupply(
        uint256 lockedAmount,
        uint256 transferableAmount,
        uint256 duration,
        uint256 timeAdvance
    ) public {
        lockedAmount = bound(lockedAmount, 11 ether, 500 ether);
        transferableAmount = bound(transferableAmount, 11 ether, 500 ether);
        duration = bound(duration, 2 * SIX_DAYS, MAX_TIME);
        timeAdvance = bound(timeAdvance, 0, duration);

        (uint256 tNonTransferable,,) = createNonTransferablePosition(alice, lockedAmount, duration);
        createLock(bob, transferableAmount, duration);
        seedAndFinalize(_toArray(tNonTransferable));

        vm.warp(block.timestamp + timeAdvance);
        veHemi.checkpoint();

        (uint256 total, uint256 locked_, uint256 forfeitable_, uint256 transferable) = veHemi.supplyBreakdown();
        assertEq(forfeitable_, 0, "No forfeitable positions in this test");
        assertLe(locked_, total, "Locked must never exceed total");
        assertEq(total, locked_ + transferable, "total = locked + transferable");
    }

    function testFuzz_NonTransferableCurveDecaysMonotonically(
        uint256 amount,
        uint256 duration
    ) public {
        amount = bound(amount, 11 ether, 500 ether);
        duration = bound(duration, 4 * SIX_DAYS, MAX_TIME);

        (uint256 t1,,) = createNonTransferablePosition(alice, amount, duration);
        seedAndFinalize(_toArray(t1));

        uint256 prevSupply = veHemi.nonTransferableTotalVeHemiSupply();

        // Check that supply only goes down
        for (uint256 i; i < 5; ++i) {
            vm.warp(block.timestamp + SIX_DAYS);
            veHemi.checkpoint();

            uint256 currentSupply = veHemi.nonTransferableTotalVeHemiSupply();
            assertLe(currentSupply, prevSupply, "Non-transferable supply must be monotonically non-increasing");
            prevSupply = currentSupply;
        }
    }

    function testFuzz_IncreaseAmount_NonTransferableCurveIncrease(
        uint256 initialAmount,
        uint256 extraAmount,
        uint256 duration
    ) public {
        initialAmount = bound(initialAmount, 11 ether, 400 ether);
        extraAmount = bound(extraAmount, 11 ether, 400 ether);
        duration = bound(duration, 2 * SIX_DAYS, MAX_TIME);

        (uint256 t1,,) = createNonTransferablePosition(alice, initialAmount, duration);
        seedAndFinalize(_toArray(t1));

        uint256 supplyBefore = veHemi.nonTransferableTotalVeHemiSupply();

        vm.startPrank(alice);
        hemi.mint(alice, extraAmount);
        hemi.approve(address(veHemi), type(uint256).max);
        veHemi.increaseAmount(t1, extraAmount);
        vm.stopPrank();

        uint256 supplyAfter = veHemi.nonTransferableTotalVeHemiSupply();
        assertGt(supplyAfter, supplyBefore, "Non-transferable supply must increase after increaseAmount");
    }

    // testFuzz_Slash_ReducesNonTransferableCurve removed — requires restaking infrastructure

    // ═════════════════════════════════════════════════════════════════════
    //  11. ATOMICITY & IDEMPOTENCY
    // ═════════════════════════════════════════════════════════════════════

    function test_SeedAndFinalize_AllExpired_ZeroNonTransferableSupply() public {
        // All positions expired before seeding — non-transferable supply should be 0
        (uint256 t1,,) = createNonTransferablePosition(alice, 100 ether, 2 * SIX_DAYS);
        (uint256 t2,,) = createNonTransferablePosition(bob, 200 ether, 2 * SIX_DAYS);

        uint256 expiry = veHemi.getLockedBalance(t2).end;
        vm.warp(expiry + 1);

        seedAndFinalize(_toArray(t1, t2));

        assertTrue(veHemi.nonTransferableSeedingFinalized(), "Should be finalized");
        assertEq(veHemi.nonTransferableTotalVeHemiSupply(), 0, "All expired => non-transferable supply 0");
    }

    function test_SeedAndFinalize_DuplicateTokenId_Reverts() public {
        // Passing the same tokenId twice now reverts with UnsortedOrDuplicateTokenIds.
        (uint256 t1,,) = createNonTransferablePosition(alice, 100 ether, LOCK_2Y);

        vm.expectRevert(VeHemi.UnsortedOrDuplicateTokenIds.selector);
        seedAndFinalize(_toArray(t1, t1));
    }

    function test_SeedAndFinalize_SameBlockAsLockCreation() public {
        // Create and seed in the same block
        (uint256 t1, uint256 s1, uint256 e1) = createNonTransferablePosition(alice, 100 ether, LOCK_2Y);

        seedAndFinalize(_toArray(t1));

        uint256 nonTransferableSupply = veHemi.nonTransferableTotalVeHemiSupply();
        uint256 expectedBias = s1 * (e1 - block.timestamp);
        assertEq(nonTransferableSupply, expectedBias, "Same-block seed should work correctly");
    }

    function test_SeedAndFinalize_OnlyOwnerCanCall() public {
        (uint256 t1,,) = createNonTransferablePosition(alice, 100 ether, LOCK_2Y);

        // alice is not the owner
        vm.prank(alice);
        vm.expectRevert();
        veHemi.seedAndFinalizeNonTransferablePositions(_toArray(t1));

        // bob is not the owner
        vm.prank(bob);
        vm.expectRevert();
        veHemi.seedAndFinalizeNonTransferablePositions(_toArray(t1));
    }

    // ═════════════════════════════════════════════════════════════════════
    //  12. LOCKED CURVE + GLOBAL CURVE CONSISTENCY
    // ═════════════════════════════════════════════════════════════════════

    function test_NonTransferableEqualsGlobal_WhenOnlyNonTransferablePositions() public {
        // When ALL positions are non-transferrable, locked == global at every epoch
        (uint256 t1,,) = createNonTransferablePosition(alice, 100 ether, LOCK_2Y);
        (uint256 t2,,) = createNonTransferablePosition(bob, 200 ether, LOCK_3Y);
        seedAndFinalize(_toArray(t1, t2));

        for (uint256 i; i < 10; ++i) {
            vm.warp(block.timestamp + SIX_DAYS);
            veHemi.checkpoint();

            uint256 total = veHemi.totalVeHemiSupply();
            uint256 locked_ = veHemi.nonTransferableTotalVeHemiSupply();
            assertEq(locked_, total, "All-locked: locked == total");
        }
    }

    function test_TransferableEqualsGlobal_WhenNoNonTransferablePositions() public {
        // When ALL positions are transferable, locked == 0 and transferable == total
        createLock(alice, 100 ether, LOCK_2Y);
        createLock(bob, 200 ether, LOCK_3Y);

        // Seed with no non-transferable positions isn't possible (EmptyArray),
        // so we create a minimal non-transferable position to enable tracking
        (uint256 tMinimal,,) = createNonTransferablePosition(charlie, 11 ether, 2 * SIX_DAYS);
        seedAndFinalize(_toArray(tMinimal));

        for (uint256 i; i < 5; ++i) {
            vm.warp(block.timestamp + SIX_DAYS);
            veHemi.checkpoint();

            (uint256 total, uint256 locked_, uint256 forfeitable_, uint256 transferable) = veHemi.supplyBreakdown();
        assertEq(forfeitable_, 0, "No forfeitable positions in this test");
            assertEq(total, locked_ + transferable, "total = locked + transferable");
            // Transferable positions dominate
            assertGt(transferable, locked_, "Transferable should dominate");
        }
    }

    function test_NonTransferableCurve_MultiplePositionsSameLockEnd() public {
        // Two non-transferable positions with same lock end — slopes should stack
        (uint256 t1, uint256 s1,) = createNonTransferablePosition(alice, 100 ether, LOCK_2Y);
        (uint256 t2, uint256 s2, uint256 e2) = createNonTransferablePosition(bob, 200 ether, LOCK_2Y);

        seedAndFinalize(_toArray(t1, t2));

        // Both end at same SIX_DAYS boundary
        uint256 e1 = veHemi.getLockedBalance(t1).end;
        assertEq(e1, e2, "Same duration => same lock end");

        int128 slopeChange = veHemi.nonTransferableSlopeChanges(e1);
        assertEq(slopeChange, -int128(int256(s1 + s2)), "Slopes should stack at same end");
    }

    function test_NonTransferableCurve_PositionExpiryMidCatchupLoop() public {
        // Position that expires during the catchup loop (between SIX_DAYS boundaries)
        (uint256 t1,, uint256 e1) = createNonTransferablePosition(alice, 100 ether, 4 * SIX_DAYS);
        (uint256 t2,,) = createNonTransferablePosition(bob, 200 ether, MAX_TIME);
        seedAndFinalize(_toArray(t1, t2));

        // Warp past t1's expiry + extra to trigger catchup across the expiry boundary
        vm.warp(e1 + 2 * SIX_DAYS);
        veHemi.checkpoint();

        // Non-transferable supply should only be bob's position now
        uint256 nonTransferableSupply = veHemi.nonTransferableTotalVeHemiSupply();
        assertGt(nonTransferableSupply, 0, "Bob's position should still have weight");

        // Verify it matches bob's expected weight
        uint256 bobEnd = veHemi.getLockedBalance(t2).end;
        uint256 bobSlope = 200 ether / MAX_TIME;
        uint256 expectedBias = bobSlope * (bobEnd - block.timestamp);
        assertEq(nonTransferableSupply, expectedBias, "Should match bob-only expected bias");
    }

    // ═════════════════════════════════════════════════════════════════════
    //  13. HISTORICAL QUERY CONSISTENCY
    // ═════════════════════════════════════════════════════════════════════

    function test_HistoricalNonTransferableSupply_MonotonicallyDecreasing() public {
        (uint256 t1,,) = createNonTransferablePosition(alice, 100 ether, LOCK_2Y);
        seedAndFinalize(_toArray(t1));

        uint256[] memory timestamps = new uint256[](6);
        uint256[] memory supplies = new uint256[](6);

        timestamps[0] = block.timestamp;
        supplies[0] = veHemi.nonTransferableTotalVeHemiSupply();

        for (uint256 i = 1; i < 6; ++i) {
            vm.warp(block.timestamp + 30 days);
            veHemi.checkpoint();
            timestamps[i] = block.timestamp;
            supplies[i] = veHemi.nonTransferableTotalVeHemiSupply();
        }

        // Verify historical queries match snapshots
        for (uint256 i; i < 6; ++i) {
            uint256 historical = veHemi.nonTransferableTotalVeHemiSupplyAt(timestamps[i]);
            assertEq(historical, supplies[i], "Historical should match snapshot");
        }

        // Verify monotonically decreasing
        for (uint256 i = 1; i < 6; ++i) {
            assertLe(supplies[i], supplies[i - 1], "Supply must decrease over time");
        }
    }

    function test_HistoricalNonTransferableSupply_AfterIncreaseAmount() public {
        (uint256 t1,,) = createNonTransferablePosition(alice, 100 ether, LOCK_2Y);
        seedAndFinalize(_toArray(t1));

        uint256 supplyBeforeIncrease = veHemi.nonTransferableTotalVeHemiSupply();
        uint256 tsBefore = block.timestamp;

        vm.warp(block.timestamp + 7 days);

        vm.startPrank(alice);
        hemi.mint(alice, 50 ether);
        hemi.approve(address(veHemi), type(uint256).max);
        veHemi.increaseAmount(t1, 50 ether);
        vm.stopPrank();

        uint256 supplyAfterIncrease = veHemi.nonTransferableTotalVeHemiSupply();
        uint256 tsAfter = block.timestamp;

        // Advance further to enable historical queries
        vm.warp(block.timestamp + 7 days);
        veHemi.checkpoint();

        // Historical query before increase should match original snapshot
        uint256 historicalBefore = veHemi.nonTransferableTotalVeHemiSupplyAt(tsBefore);
        assertEq(historicalBefore, supplyBeforeIncrease, "Pre-increase historical should match");

        // Historical query after increase should reflect the increase
        uint256 historicalAfter = veHemi.nonTransferableTotalVeHemiSupplyAt(tsAfter);
        assertEq(historicalAfter, supplyAfterIncrease, "Post-increase historical should match");
        assertGt(historicalAfter, historicalBefore, "Increase should show in history");
    }

    // ═════════════════════════════════════════════════════════════════════
    //  14. SAME-BLOCK OVERWRITE LOGIC
    // ═════════════════════════════════════════════════════════════════════

    function test_SameBlockCheckpoints_SupplyPointOverwritten() public {
        (uint256 t1,,) = createNonTransferablePosition(alice, 100 ether, LOCK_2Y);
        seedAndFinalize(_toArray(t1));

        // Multiple operations in the same block should overwrite, not append
        vm.startPrank(alice);
        hemi.mint(alice, 50 ether);
        hemi.approve(address(veHemi), type(uint256).max);
        veHemi.increaseAmount(t1, 50 ether);
        vm.stopPrank();

        // Another checkpoint in the same block
        veHemi.checkpoint();

        // Supply should be consistent (no double-counting from same-block overwrites)
        uint256 lockEnd = veHemi.getLockedBalance(t1).end;
        uint256 expectedSlope = 150 ether / MAX_TIME;
        uint256 expectedBias = expectedSlope * (lockEnd - block.timestamp);
        assertEq(
            veHemi.nonTransferableTotalVeHemiSupply(),
            expectedBias,
            "Same-block overwrites should produce consistent supply"
        );
    }

    function test_SameBlockSeedAndModify() public {
        // Seed, then modify a position in the same block
        (uint256 t1,,) = createNonTransferablePosition(alice, 100 ether, LOCK_2Y);

        seedAndFinalize(_toArray(t1));

        // Increase amount in the same block
        vm.startPrank(alice);
        hemi.mint(alice, 50 ether);
        hemi.approve(address(veHemi), type(uint256).max);
        veHemi.increaseAmount(t1, 50 ether);
        vm.stopPrank();

        uint256 lockEnd = veHemi.getLockedBalance(t1).end;
        uint256 expectedSlope = 150 ether / MAX_TIME;
        uint256 expectedBias = expectedSlope * (lockEnd - block.timestamp);
        assertEq(
            veHemi.nonTransferableTotalVeHemiSupply(),
            expectedBias,
            "Seed + modify in same block should be consistent"
        );
    }

    // ═════════════════════════════════════════════════════════════════════
    //  15. STORAGE DEPRECATION
    // ═════════════════════════════════════════════════════════════════════

    function test_DeprecatedStorageVarsNotExposed() public {
        // Verify deprecated storage vars (seedingDeadline, lastSeededTokenId, seededBias,
        // seededSlope) are not accessible as public getters by confirming their selectors
        // revert when called.
        bytes4[4] memory deprecatedSelectors = [
            bytes4(keccak256("seedingDeadline()")),
            bytes4(keccak256("lastSeededTokenId()")),
            bytes4(keccak256("seededBias()")),
            bytes4(keccak256("seededSlope()"))
        ];
        for (uint i = 0; i < deprecatedSelectors.length; i++) {
            (bool success,) = address(veHemi).staticcall(abi.encodePacked(deprecatedSelectors[i]));
            assertFalse(success, "Deprecated getter should not be accessible");
        }

        // nonTransferableSeedingFinalized should still be public
        (bool ok,) = address(veHemi).staticcall(
            abi.encodeWithSignature("nonTransferableSeedingFinalized()")
        );
        assertTrue(ok, "nonTransferableSeedingFinalized should still be public");
    }

    // ═════════════════════════════════════════════════════════════════════
    //  16. INCREASEUNLOCKTIME AFTER SEEDING
    // ═════════════════════════════════════════════════════════════════════

    function test_IncreaseUnlockTime_MultipleTimes_NonTransferableSupplyUnchanged() public {
        (uint256 t1,,) = createNonTransferablePosition(alice, 100 ether, LOCK_2Y);
        seedAndFinalize(_toArray(t1));

        uint256 nonTransferableAtCreation = veHemi.nonTransferableTotalVeHemiSupply();
        uint256 originalTransferableAfter = veHemi.transferableAfter(t1);

        // First extension
        vm.prank(alice);
        veHemi.increaseUnlockTime(t1, LOCK_3Y);

        uint256 supply1 = veHemi.nonTransferableTotalVeHemiSupply();
        assertEq(supply1, nonTransferableAtCreation, "First extension should NOT change non-transferable supply");

        // Second extension to max
        vm.prank(alice);
        veHemi.increaseUnlockTime(t1, MAX_TIME);

        uint256 supply2 = veHemi.nonTransferableTotalVeHemiSupply();
        assertEq(supply2, nonTransferableAtCreation, "Second extension should NOT change non-transferable supply");

        // transferableAfter should still be the original value
        assertEq(veHemi.transferableAfter(t1), originalTransferableAfter, "transferableAfter should not change across extensions");

        // Non-transferable supply should be bounded by transferableAfter (original end), not lock.end
        uint256 expectedSlope = 100 ether / MAX_TIME;
        uint256 expectedBias = expectedSlope * (originalTransferableAfter - block.timestamp);
        assertEq(supply2, expectedBias, "Non-transferable supply should be bounded by original transferableAfter");

        // Global supply should reflect the new lock.end (MAX_TIME)
        uint256 lockEnd = veHemi.getLockedBalance(t1).end;
        uint256 expectedGlobalBias = expectedSlope * (lockEnd - block.timestamp);
        assertEq(veHemi.totalVeHemiSupply(), expectedGlobalBias, "Global supply should use new lock.end");
        assertGt(veHemi.totalVeHemiSupply(), supply2, "Global supply should exceed non-transferable supply");
    }

    function test_IncreaseUnlockTime_NonTransferableSlopeChangeRemainsAtTransferableAfter() public {
        (uint256 t1, uint256 s1,) = createNonTransferablePosition(alice, 100 ether, LOCK_2Y);
        seedAndFinalize(_toArray(t1));

        uint256 oldEnd = veHemi.getLockedBalance(t1).end;
        int128 slopeChangeBeforeExtension = veHemi.nonTransferableSlopeChanges(oldEnd);

        vm.prank(alice);
        veHemi.increaseUnlockTime(t1, LOCK_3Y);

        uint256 newEnd = veHemi.getLockedBalance(t1).end;
        assertGt(newEnd, oldEnd, "Lock end should have increased");

        // Old end (transferableAfter) should STILL have the non-transferable slope change — NOT cleared
        int128 slopeChangeAfterExtension = veHemi.nonTransferableSlopeChanges(oldEnd);
        assertEq(
            slopeChangeAfterExtension,
            slopeChangeBeforeExtension,
            "Non-transferable slope change at transferableAfter should be unchanged"
        );
        assertEq(
            slopeChangeAfterExtension,
            -int128(int256(s1)),
            "Non-transferable slope change should equal position's negative slope"
        );

        // New end should have NO non-transferable slope change
        assertEq(veHemi.nonTransferableSlopeChanges(newEnd), 0, "New end should have no non-transferable slope change");
    }

    // ═════════════════════════════════════════════════════════════════════
    //  17. ADDITIONAL FUZZ TESTS
    // ═════════════════════════════════════════════════════════════════════

    function testFuzz_NonTransferableEqualsTotalMinusTransferable(
        uint256 lockedAmt,
        uint256 transferableAmt,
        uint256 duration
    ) public {
        lockedAmt = bound(lockedAmt, 11 ether, 500 ether);
        transferableAmt = bound(transferableAmt, 11 ether, 500 ether);
        duration = bound(duration, 2 * SIX_DAYS, MAX_TIME);

        (uint256 tNonTransferable,,) = createNonTransferablePosition(alice, lockedAmt, duration);
        createLock(bob, transferableAmt, duration);
        seedAndFinalize(_toArray(tNonTransferable));

        (uint256 total, uint256 locked_, uint256 forfeitable_, uint256 transferable) = veHemi.supplyBreakdown();
        assertEq(forfeitable_, 0, "No forfeitable positions in this test");
        assertEq(transferable, total - locked_, "transferable must equal total - locked");
    }

    function testFuzz_SeedAndFinalize_VariousAmountsAndDurations(
        uint256 amount1,
        uint256 amount2,
        uint256 dur1,
        uint256 dur2
    ) public {
        amount1 = bound(amount1, 11 ether, 500 ether);
        amount2 = bound(amount2, 11 ether, 500 ether);
        dur1 = bound(dur1, 2 * SIX_DAYS, MAX_TIME);
        dur2 = bound(dur2, 2 * SIX_DAYS, MAX_TIME);

        (uint256 t1, uint256 s1, uint256 e1) = createNonTransferablePosition(alice, amount1, dur1);
        (uint256 t2, uint256 s2, uint256 e2) = createNonTransferablePosition(bob, amount2, dur2);

        seedAndFinalize(_toArray(t1, t2));

        uint256 nonTransferableSupply = veHemi.nonTransferableTotalVeHemiSupply();
        uint256 expectedBias = s1 * (e1 - block.timestamp) + s2 * (e2 - block.timestamp);
        assertEq(nonTransferableSupply, expectedBias, "Non-transferable supply should match sum of biases");
    }

    // ═════════════════════════════════════════════════════════════════════
    //  ADDITIONAL TESTS (from review findings)
    // ═════════════════════════════════════════════════════════════════════

    /// @notice Unsorted (but non-duplicate) token IDs should revert.
    function test_SeedAndFinalize_UnsortedTokenIds_Reverts() public {
        (uint256 t1,,) = createNonTransferablePosition(alice, 100 ether, LOCK_2Y);
        (uint256 t2,,) = createNonTransferablePosition(bob, 200 ether, LOCK_3Y);

        // t1 < t2, so passing [t2, t1] is unsorted
        uint256[] memory unsorted = new uint256[](2);
        unsorted[0] = t2;
        unsorted[1] = t1;

        vm.expectRevert(VeHemi.UnsortedOrDuplicateTokenIds.selector);
        veHemi.seedAndFinalizeNonTransferablePositions(unsorted);
    }

    /// @notice Non-existent token ID should revert with a clear error.
    function test_SeedAndFinalize_NonExistentTokenId_Reverts() public {
        uint256[] memory ids = new uint256[](1);
        ids[0] = 99999; // never minted

        vm.expectRevert(VeHemi.TokenDoesNotExist.selector);
        veHemi.seedAndFinalizeNonTransferablePositions(ids);
    }

    /// @notice After seeding, a new non-transferable position should update nonTransferableSlopeChanges.
    function test_NewNonTransferablePosition_AfterFinalization_UpdatesSlopeChanges() public {
        (uint256 t1,,) = createNonTransferablePosition(alice, 100 ether, LOCK_2Y);
        seedAndFinalize(_toArray(t1));

        // Create a new non-transferable position AFTER seeding
        (uint256 t2,, uint256 e2) = createNonTransferablePosition(bob, 200 ether, LOCK_3Y);

        // The new position's lock end should have a nonTransferableSlopeChange entry
        int128 slopeChange = veHemi.nonTransferableSlopeChanges(e2);
        assertLt(slopeChange, 0, "nonTransferableSlopeChanges should have negative delta at new position's lock end");

        // After warping past SIX_DAYS boundaries and checkpointing,
        // the non-transferable supply should decay correctly
        uint256 supplyBefore = veHemi.nonTransferableTotalVeHemiSupply();
        vm.warp(block.timestamp + 30 days);
        veHemi.checkpoint();
        uint256 supplyAfter = veHemi.nonTransferableTotalVeHemiSupply();
        assertLt(supplyAfter, supplyBefore, "Non-transferable supply should decay after time warp with new position");
    }

    /// @notice Verify transferableAfter is cleaned up after withdraw.
    function test_Withdraw_CleansUpTransferableAfter() public {
        (uint256 t1,, uint256 e1) = createNonTransferablePosition(alice, 100 ether, LOCK_2Y);
        seedAndFinalize(_toArray(t1));

        // transferableAfter should be set (non-zero) before withdraw
        assertGt(veHemi.transferableAfter(t1), 0, "transferableAfter should be set before withdraw");

        // Warp past expiry and withdraw
        vm.warp(e1 + 1);
        vm.prank(alice);
        veHemi.withdraw(t1);

        // transferableAfter should be cleaned up (zeroed)
        assertEq(veHemi.transferableAfter(t1), 0, "transferableAfter should be 0 after withdraw");
    }

    /// @notice Verify transferableAfter is cleaned up after forfeit.
    function test_Forfeit_CleansUpTransferableAfter() public {
        veHemi.updateForfeitAdmin(admin);

        (uint256 t1,,) = createNonTransferableForfeitablePosition(alice, 100 ether, LOCK_2Y);
        seedAndFinalize(_toArray(t1));

        // transferableAfter should be set before forfeit
        assertGt(veHemi.transferableAfter(t1), 0, "transferableAfter should be set before forfeit");

        // Forfeit (still active, not expired)
        veHemi.forfeit(t1);

        // transferableAfter should be cleaned up
        assertEq(veHemi.transferableAfter(t1), 0, "transferableAfter should be 0 after forfeit");
    }

    /// @notice Fuzz: increaseUnlockTime on non-transferable positions does NOT change non-transferable supply.
    function testFuzz_IncreaseUnlockTime_NonTransferableCurveUnchanged(
        uint256 lockAmount,
        uint256 initialDuration,
        uint256 additionalDuration
    ) public {
        lockAmount = bound(lockAmount, 11 ether, 500 ether);
        initialDuration = bound(initialDuration, 2 * SIX_DAYS, MAX_TIME / 2);
        additionalDuration = bound(additionalDuration, SIX_DAYS, MAX_TIME / 2);

        (uint256 t1,,) = createNonTransferablePosition(alice, lockAmount, initialDuration);
        seedAndFinalize(_toArray(t1));

        uint256 nonTransferableSupplyBefore = veHemi.nonTransferableTotalVeHemiSupply();
        uint256 globalBefore = veHemi.totalVeHemiSupply();

        // Extend the lock
        vm.prank(alice);
        veHemi.increaseUnlockTime(t1, initialDuration + additionalDuration);

        uint256 nonTransferableSupplyAfter = veHemi.nonTransferableTotalVeHemiSupply();
        uint256 globalAfter = veHemi.totalVeHemiSupply();

        // Non-transferable supply should NOT change — bounded by original transferableAfter
        assertEq(nonTransferableSupplyAfter, nonTransferableSupplyBefore, "Non-transferable supply must NOT change after extending lock");

        // Global supply SHOULD increase — global curve uses lock.end
        assertGt(globalAfter, globalBefore, "Global supply must increase after extending lock");
    }
}
