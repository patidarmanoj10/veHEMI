// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import "./NonTransferableCurveTestBase.sol";
import "../src/storage/VeHemiStorageV2.sol";

/// @title VeHemiForfeitableCurveTest
/// @notice Comprehensive tests for VeHemi V2 forfeitable subcurve tracking.
///
/// The forfeitable subcurve tracks positions that are BOTH non-transferrable
/// (transferableAfter != 0) AND forfeitable (forfeitable[tokenId] == true).
/// This is a strict subset of the non-transferable curve (all non-transferrable positions).
///
/// Test categories:
///   1. Seeding — forfeitable partition in seedAndFinalizeNonTransferablePositions
///   2. supplyBreakdown — 4-tuple correctness and defensive caps
///   3. forfeitableTotalVeHemiSupply — current and historical queries
///   4. increaseAmount — forfeitable curve updated for forfeitable positions
///   5. increaseUnlockTime — slope changes rescheduled in forfeitable map
///   6. Forfeit (mid-lock) — forfeitable curve correctly decremented
///   7. Natural expiry + withdraw — slope changes fire correctly
///   8. New forfeitable positions after seeding — tracked in forfeitable curve
///   9. Catchup loop — forfeitable curve decays across SIX_DAYS boundaries
///  10. Invariants — recallable <= locked <= total at all times
///  11. Edge cases — zero forfeitable at seeding, all forfeitable, same-block ops
///  12. Fuzz tests — randomized amounts, durations, and mixed position types
contract VeHemiForfeitableCurveTest is NonTransferableCurveTestBase {
    // ── Constants ────────────────────────────────────────────────────────
    uint256 constant LOCK_2Y = 2 * 365 days;
    uint256 constant LOCK_3Y = 3 * 365 days;
    uint256 constant MIN_AMOUNT = 11 ether; // must be >= VeHemi.MIN_LOCK_AMOUNT (10e18)

    // ── Helpers ──────────────────────────────────────────────────────────

    /// @dev Create a non-transferrable, non-forfeitable lock
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

    /// @dev Create a non-transferrable, forfeitable lock
    function createForfeitablePosition(
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

    /// @dev Create a transferable lock (not locked, not forfeitable for curve purposes)
    function createTransferablePosition(
        address account_,
        uint256 amount_,
        uint256 duration_
    ) public returns (uint256 _tokenId, uint256 _slope, uint256 _end) {
        vm.startPrank(account_);
        hemi.mint(account_, amount_);
        hemi.approve(address(veHemi), type(uint256).max);
        _tokenId = veHemi.createLock(amount_, duration_);
        vm.stopPrank();
        _slope = amount_ / MAX_TIME;
        _end = veHemi.getLockedBalance(_tokenId).end;
    }

    function seedAndFinalize(uint256[] memory tokenIds_) public {
        veHemi.seedAndFinalizeNonTransferablePositions(tokenIds_);
    }

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

    function _toArray(uint256 a, uint256 b, uint256 c, uint256 d) internal pure returns (uint256[] memory arr) {
        arr = new uint256[](4);
        arr[0] = a;
        arr[1] = b;
        arr[2] = c;
        arr[3] = d;
    }

    function _warpAndCheckpoint(uint256 duration_) internal {
        vm.warp(block.timestamp + duration_);
        veHemi.checkpoint();
    }

    function _enableForfeitAdmin() internal {
        veHemi.updateForfeitAdmin(admin);
    }

    // ═════════════════════════════════════════════════════════════════════
    //  1. SEEDING — FORFEITABLE PARTITION
    // ═════════════════════════════════════════════════════════════════════

    function test_Seeding_ForfeitablePositionTracked() public {
        (uint256 t1, uint256 s1, uint256 e1) = createForfeitablePosition(alice, 100 ether, LOCK_2Y);
        seedAndFinalize(_toArray(t1));

        uint256 forfeitableSupply = veHemi.forfeitableTotalVeHemiSupply();
        uint256 expected = s1 * (e1 - block.timestamp);
        assertEq(forfeitableSupply, expected, "Forfeitable supply should match seeded position");
    }

    function test_Seeding_NonForfeitableNotInForfeitableCurve() public {
        (uint256 t1,,) = createNonTransferablePosition(alice, 100 ether, LOCK_2Y);
        seedAndFinalize(_toArray(t1));

        assertEq(veHemi.forfeitableTotalVeHemiSupply(), 0, "Non-forfeitable should not be in forfeitable curve");
        assertGt(veHemi.nonTransferableTotalVeHemiSupply(), 0, "But should be in non-transferable curve");
    }

    function test_Seeding_MixedPartition() public {
        (uint256 t1, uint256 s1, uint256 e1) = createNonTransferablePosition(alice, 100 ether, LOCK_2Y);
        (uint256 t2, uint256 s2, uint256 e2) = createForfeitablePosition(bob, 200 ether, LOCK_2Y);
        seedAndFinalize(_toArray(t1, t2));

        uint256 nonTransferableSupply = veHemi.nonTransferableTotalVeHemiSupply();
        uint256 forfeitableSupply = veHemi.forfeitableTotalVeHemiSupply();

        uint256 expectedNonTransferable = s1 * (e1 - block.timestamp) + s2 * (e2 - block.timestamp);
        uint256 expectedForfeitable = s2 * (e2 - block.timestamp);

        assertEq(nonTransferableSupply, expectedNonTransferable, "Non-transferable should include both");
        assertEq(forfeitableSupply, expectedForfeitable, "Forfeitable should only include bob");
        assertGt(nonTransferableSupply, forfeitableSupply, "Locked must exceed forfeitable");
    }

    function test_Seeding_WritesForfeitableSlopeChanges() public {
        (uint256 t1, uint256 s1, uint256 e1) = createForfeitablePosition(alice, 100 ether, LOCK_2Y);
        (uint256 t2, uint256 s2, uint256 e2) = createNonTransferablePosition(bob, 200 ether, LOCK_2Y);
        assertEq(e1, e2, "Same duration same block => same end time");
        seedAndFinalize(_toArray(t1, t2));

        // forfeitableSlopeChanges should have slope only for alice (forfeitable)
        assertEq(
            veHemi.forfeitableSlopeChanges(e1),
            -int128(int256(s1)),
            "forfeitableSlopeChanges at forfeitable end"
        );

        // nonTransferableSlopeChanges should have slopes for both (more negative)
        assertEq(
            veHemi.nonTransferableSlopeChanges(e1),
            -int128(int256(s1 + s2)),
            "nonTransferableSlopeChanges at shared end (both positions)"
        );
    }

    function test_Seeding_ZeroForfeitablePositions() public {
        // All positions are non-transferable-only (not forfeitable)
        (uint256 t1,,) = createNonTransferablePosition(alice, 100 ether, LOCK_2Y);
        seedAndFinalize(_toArray(t1));

        // Forfeitable supply should be 0 but function should not revert
        assertEq(veHemi.forfeitableTotalVeHemiSupply(), 0, "Should be 0 with no forfeitable positions");

        // Supply breakdown should work
        (uint256 total, uint256 locked_, uint256 forfeitable_, uint256 transferable) = veHemi.supplyBreakdown();
        assertEq(forfeitable_, 0, "Forfeitable in breakdown should be 0");
        assertGt(locked_, 0, "Non-transferable should be positive");
        assertEq(transferable, 0, "No transferable positions");
        assertEq(total, locked_, "Total should equal locked");
    }

    function test_Seeding_SkipsExpiredForfeitablePositions() public {
        // Create forfeitable that will expire
        (uint256 t1,,) = createForfeitablePosition(alice, 100 ether, 2 * SIX_DAYS);
        (uint256 t2, uint256 s2, uint256 e2) = createForfeitablePosition(bob, 200 ether, LOCK_2Y);

        // Warp past t1's expiry
        vm.warp(veHemi.getLockedBalance(t1).end + 1);

        seedAndFinalize(_toArray(t1, t2));

        uint256 forfeitableSupply = veHemi.forfeitableTotalVeHemiSupply();
        uint256 expected = s2 * (e2 - block.timestamp);
        assertEq(forfeitableSupply, expected, "Expired forfeitable should be skipped");
    }

    // ═════════════════════════════════════════════════════════════════════
    //  2. SUPPLY BREAKDOWN — 4-TUPLE CORRECTNESS
    // ═════════════════════════════════════════════════════════════════════

    function test_SupplyBreakdown_AllThreePositionTypes() public {
        (uint256 t1,,) = createNonTransferablePosition(alice, 100 ether, LOCK_2Y);       // locked only
        (uint256 t2,,) = createForfeitablePosition(bob, 100 ether, LOCK_2Y);    // non-transferable + forfeitable
        createTransferablePosition(charlie, 100 ether, LOCK_2Y);                 // transferable

        seedAndFinalize(_toArray(t1, t2));

        (uint256 total, uint256 locked_, uint256 forfeitable_, uint256 transferable) = veHemi.supplyBreakdown();

        assertGt(total, 0, "Total should be positive");
        assertGt(locked_, 0, "Non-transferable should be positive");
        assertGt(forfeitable_, 0, "Forfeitable should be positive");
        assertGt(transferable, 0, "Transferable should be positive");
        assertEq(total, locked_ + transferable, "total = locked + transferable");
        assertLe(forfeitable_, locked_, "forfeitable <= locked");
        assertLt(forfeitable_, locked_, "forfeitable < non-transferable (alice is non-transferable-only)");
    }

    function test_SupplyBreakdown_ForfeitableLessThanOrEqualNonTransferable() public {
        (uint256 t1,,) = createForfeitablePosition(alice, 100 ether, LOCK_2Y);
        seedAndFinalize(_toArray(t1));

        (, uint256 locked_, uint256 forfeitable_,) = veHemi.supplyBreakdown();
        assertEq(forfeitable_, locked_, "When all locked are forfeitable, forfeitable == locked");
    }

    function test_SupplyBreakdown_ConsistencyWithIndividualFunctions() public {
        (uint256 t1,,) = createNonTransferablePosition(alice, 100 ether, LOCK_2Y);
        (uint256 t2,,) = createForfeitablePosition(bob, 200 ether, LOCK_2Y);
        createTransferablePosition(charlie, 150 ether, LOCK_2Y);
        seedAndFinalize(_toArray(t1, t2));

        (uint256 total, uint256 locked_, uint256 forfeitable_, uint256 transferable) = veHemi.supplyBreakdown();

        assertApproxEqRel(total, veHemi.totalVeHemiSupply(), 0.001e18, "total matches");
        assertApproxEqRel(locked_, veHemi.nonTransferableTotalVeHemiSupply(), 0.001e18, "locked matches");
        assertApproxEqRel(forfeitable_, veHemi.forfeitableTotalVeHemiSupply(), 0.001e18, "forfeitable matches");
        assertEq(transferable, total - locked_, "transferable = total - locked");
    }

    // ═════════════════════════════════════════════════════════════════════
    //  3. FORFEITABLE SUPPLY — CURRENT AND HISTORICAL QUERIES
    // ═════════════════════════════════════════════════════════════════════

    function test_ForfeitableSupply_DecaysOverTime() public {
        (uint256 t1,,) = createForfeitablePosition(alice, 100 ether, LOCK_2Y);
        seedAndFinalize(_toArray(t1));

        uint256 supplyNow = veHemi.forfeitableTotalVeHemiSupply();

        _warpAndCheckpoint(180 days);

        uint256 supplyLater = veHemi.forfeitableTotalVeHemiSupply();
        assertLt(supplyLater, supplyNow, "Forfeitable supply should decay over time");
    }

    function test_ForfeitableSupplyAt_HistoricalQuery() public {
        (uint256 t1,,) = createForfeitablePosition(alice, 100 ether, LOCK_2Y);
        seedAndFinalize(_toArray(t1));

        uint256 tCreate = block.timestamp;
        uint256 supplyAtCreate = veHemi.forfeitableTotalVeHemiSupply();

        _warpAndCheckpoint(30 days);

        uint256 pastSupply = veHemi.forfeitableTotalVeHemiSupplyAt(tCreate);
        assertEq(pastSupply, supplyAtCreate, "Past forfeitable supply should match snapshot");
    }

    function test_ForfeitableSupplyAt_PreSeedingReturnsZero() public {
        (uint256 t1,,) = createForfeitablePosition(alice, 100 ether, LOCK_2Y);

        // Record a pre-seeding timestamp
        veHemi.checkpoint();
        uint256 preSeedTime = block.timestamp;

        vm.warp(block.timestamp + 1 days);
        seedAndFinalize(_toArray(t1));

        // Query the pre-seeding timestamp
        assertEq(veHemi.forfeitableTotalVeHemiSupplyAt(preSeedTime), 0, "Pre-seeding should return 0");
    }

    function test_ForfeitableSupply_ZeroAfterExpiry() public {
        (uint256 t1,, uint256 e1) = createForfeitablePosition(alice, 100 ether, LOCK_2Y);
        seedAndFinalize(_toArray(t1));

        vm.warp(e1 + 1);
        veHemi.checkpoint();

        assertEq(veHemi.forfeitableTotalVeHemiSupply(), 0, "Should be 0 after all positions expired");
    }

    // ═════════════════════════════════════════════════════════════════════
    //  4. INCREASE AMOUNT — FORFEITABLE CURVE UPDATED
    // ═════════════════════════════════════════════════════════════════════

    function test_IncreaseAmount_UpdatesForfeitableCurve() public {
        (uint256 t1,,) = createForfeitablePosition(alice, 100 ether, LOCK_2Y);
        seedAndFinalize(_toArray(t1));

        uint256 before = veHemi.forfeitableTotalVeHemiSupply();

        vm.startPrank(alice);
        hemi.mint(alice, 50 ether);
        hemi.approve(address(veHemi), type(uint256).max);
        veHemi.increaseAmount(t1, 50 ether);
        vm.stopPrank();

        uint256 after_ = veHemi.forfeitableTotalVeHemiSupply();
        assertGt(after_, before, "Forfeitable supply should increase after increaseAmount");
    }

    function test_IncreaseAmount_NonTransferableOnlyDoesNotAffectForfeitable() public {
        (uint256 t1,,) = createNonTransferablePosition(alice, 100 ether, LOCK_2Y);
        (uint256 t2,,) = createForfeitablePosition(bob, 100 ether, LOCK_2Y);
        seedAndFinalize(_toArray(t1, t2));

        uint256 forfeitableBefore = veHemi.forfeitableTotalVeHemiSupply();

        // Increase amount on non-transferable-only (non-forfeitable) position
        vm.startPrank(alice);
        hemi.mint(alice, 50 ether);
        hemi.approve(address(veHemi), type(uint256).max);
        veHemi.increaseAmount(t1, 50 ether);
        vm.stopPrank();

        uint256 forfeitableAfter = veHemi.forfeitableTotalVeHemiSupply();
        assertEq(forfeitableAfter, forfeitableBefore, "Forfeitable should not change for non-transferable-only increase");
    }

    // ═════════════════════════════════════════════════════════════════════
    //  5. INCREASE UNLOCK TIME — SLOPE CHANGES RESCHEDULED
    // ═════════════════════════════════════════════════════════════════════

    /// @notice After increaseUnlockTime, the forfeitable curve should NOT increase.
    ///         The forfeitable subcurve is bounded by transferableAfter (the original end),
    ///         not the new extended lock.end. The global curve increases but the subcurve doesn't.
    function test_IncreaseUnlockTime_ForfeitableCurveUnchanged() public {
        (uint256 t1,, uint256 oldEnd) = createForfeitablePosition(alice, 100 ether, LOCK_2Y);
        seedAndFinalize(_toArray(t1));

        uint256 forfeitableBefore = veHemi.forfeitableTotalVeHemiSupply();
        uint256 totalBefore = veHemi.totalVeHemiSupply();

        vm.prank(alice);
        veHemi.increaseUnlockTime(t1, LOCK_3Y);

        uint256 forfeitableAfter = veHemi.forfeitableTotalVeHemiSupply();
        uint256 totalAfter = veHemi.totalVeHemiSupply();

        // Global curve increases (longer lock = more voting power)
        assertGt(totalAfter, totalBefore, "Global should increase");
        // Forfeitable curve does NOT increase (bounded by transferableAfter)
        assertEq(forfeitableAfter, forfeitableBefore, "Forfeitable should NOT change on time extension");

        // Lock end moved forward but transferableAfter stayed
        uint256 newEnd = veHemi.getLockedBalance(t1).end;
        assertGt(newEnd, oldEnd, "Lock end should increase");
        assertEq(veHemi.transferableAfter(t1), oldEnd, "transferableAfter should NOT change");
    }

    /// @notice The forfeitable slope change should stay at transferableAfter (the original end),
    ///         NOT move to the new lock.end. The position exits the forfeitable curve at the
    ///         original promised transferability time.
    function test_IncreaseUnlockTime_ForfeitableSlopeChangeStaysAtOriginalEnd() public {
        (uint256 t1, uint256 s1, uint256 oldEnd) = createForfeitablePosition(alice, 100 ether, LOCK_2Y);
        seedAndFinalize(_toArray(t1));

        // Slope change should exist at original end (= transferableAfter)
        assertEq(veHemi.forfeitableSlopeChanges(oldEnd), -int128(int256(s1)), "Slope change at original end");

        vm.prank(alice);
        veHemi.increaseUnlockTime(t1, LOCK_3Y);

        uint256 newEnd = veHemi.getLockedBalance(t1).end;

        // Slope change should REMAIN at original end (transferableAfter)
        assertEq(veHemi.forfeitableSlopeChanges(oldEnd), -int128(int256(s1)), "Slope change should stay at original end");
        // NO slope change at new end for forfeitable curve
        assertEq(veHemi.forfeitableSlopeChanges(newEnd), int128(0), "No forfeitable slope change at new end");
        // Global slope change SHOULD be at new end
        assertLt(veHemi.slopeChanges(newEnd), int128(0), "Global slope change should be at new end");
    }

    // ═════════════════════════════════════════════════════════════════════
    //  6. FORFEIT (MID-LOCK) — FORFEITABLE CURVE DECREMENTED
    // ═════════════════════════════════════════════════════════════════════

    function test_Forfeit_ReducesForfeitableCurve() public {
        _enableForfeitAdmin();

        (uint256 t1,,) = createForfeitablePosition(alice, 100 ether, LOCK_2Y);
        (uint256 t2,,) = createForfeitablePosition(bob, 200 ether, LOCK_2Y);
        seedAndFinalize(_toArray(t1, t2));

        uint256 forfeitableBefore = veHemi.forfeitableTotalVeHemiSupply();
        uint256 nonTransferableSupplyBefore = veHemi.nonTransferableTotalVeHemiSupply();

        veHemi.forfeit(t1);

        uint256 forfeitableAfter = veHemi.forfeitableTotalVeHemiSupply();
        uint256 nonTransferableSupplyAfter = veHemi.nonTransferableTotalVeHemiSupply();

        assertLt(forfeitableAfter, forfeitableBefore, "Forfeitable should decrease after forfeit");
        assertLt(nonTransferableSupplyAfter, nonTransferableSupplyBefore, "Non-transferable should also decrease after forfeit");
    }

    function test_Forfeit_UnwindsSlopeChanges() public {
        _enableForfeitAdmin();

        (uint256 t1,, uint256 e1) = createForfeitablePosition(alice, 100 ether, LOCK_2Y);
        seedAndFinalize(_toArray(t1));

        int128 slopeBefore = veHemi.forfeitableSlopeChanges(e1);
        assertLt(slopeBefore, int128(0), "Slope change should be negative before forfeit");

        veHemi.forfeit(t1);

        int128 slopeAfter = veHemi.forfeitableSlopeChanges(e1);
        assertEq(slopeAfter, int128(0), "Slope change should be unwound after forfeit");
    }

    function test_Forfeit_ZerosOutSinglePosition() public {
        _enableForfeitAdmin();

        (uint256 t1,,) = createForfeitablePosition(alice, 100 ether, LOCK_2Y);
        seedAndFinalize(_toArray(t1));

        assertGt(veHemi.forfeitableTotalVeHemiSupply(), 0, "Should be positive before");

        veHemi.forfeit(t1);

        assertEq(veHemi.forfeitableTotalVeHemiSupply(), 0, "Should be 0 after only position forfeited");
    }

    function test_Forfeit_NonTransferableOnlyNotAffected() public {
        _enableForfeitAdmin();

        (uint256 t1,,) = createForfeitablePosition(alice, 100 ether, LOCK_2Y);
        (uint256 t2,,) = createNonTransferablePosition(bob, 100 ether, LOCK_2Y);
        seedAndFinalize(_toArray(t1, t2));

        uint256 nonTransferableSupplyBefore = veHemi.nonTransferableTotalVeHemiSupply();

        veHemi.forfeit(t1);

        uint256 nonTransferableSupplyAfter = veHemi.nonTransferableTotalVeHemiSupply();

        // Non-transferable should decrease by alice's portion, but bob's remains
        assertGt(nonTransferableSupplyAfter, 0, "Bob's non-transferable position should remain");
        assertLt(nonTransferableSupplyAfter, nonTransferableSupplyBefore, "Total locked should decrease");
    }

    // ═════════════════════════════════════════════════════════════════════
    //  7. NATURAL EXPIRY + WITHDRAW
    // ═════════════════════════════════════════════════════════════════════

    function test_Withdraw_AfterExpiry_ForfeitableCurveZero() public {
        (uint256 t1,, uint256 e1) = createForfeitablePosition(alice, 100 ether, LOCK_2Y);
        seedAndFinalize(_toArray(t1));

        // Warp past expiry
        vm.warp(e1 + 1);
        veHemi.checkpoint();

        assertEq(veHemi.forfeitableTotalVeHemiSupply(), 0, "Should decay to 0 at expiry");

        // Withdraw
        vm.prank(alice);
        veHemi.withdraw(t1);

        assertEq(veHemi.forfeitableTotalVeHemiSupply(), 0, "Should remain 0 after withdraw");
    }

    function test_Withdraw_CleansUpForfeitable() public {
        (uint256 t1,, uint256 e1) = createForfeitablePosition(alice, 100 ether, LOCK_2Y);
        seedAndFinalize(_toArray(t1));

        vm.warp(e1 + 1);

        vm.prank(alice);
        veHemi.withdraw(t1);

        // forfeitable[tokenId] should be cleaned up (token burned, storage deleted)
        assertFalse(veHemi.forfeitable(t1), "forfeitable flag should be deleted after withdraw");
    }

    // ═════════════════════════════════════════════════════════════════════
    //  8. NEW FORFEITABLE POSITIONS AFTER SEEDING
    // ═════════════════════════════════════════════════════════════════════

    function test_NewForfeitableAfterSeeding_Tracked() public {
        (uint256 t1,,) = createNonTransferablePosition(alice, 100 ether, LOCK_2Y);
        seedAndFinalize(_toArray(t1));

        assertEq(veHemi.forfeitableTotalVeHemiSupply(), 0, "No forfeitable at seeding");

        // Create a new forfeitable position after seeding
        (uint256 t2, uint256 s2, uint256 e2) = createForfeitablePosition(bob, 200 ether, LOCK_2Y);

        uint256 forfeitableSupply = veHemi.forfeitableTotalVeHemiSupply();
        uint256 expected = s2 * (e2 - block.timestamp);
        assertEq(forfeitableSupply, expected, "New post-seeding forfeitable should be tracked");
    }

    function test_NewForfeitableAfterSeeding_NonTransferableAlsoUpdated() public {
        (uint256 t1,,) = createNonTransferablePosition(alice, 100 ether, LOCK_2Y);
        seedAndFinalize(_toArray(t1));

        uint256 nonTransferableSupplyBefore = veHemi.nonTransferableTotalVeHemiSupply();

        createForfeitablePosition(bob, 200 ether, LOCK_2Y);

        uint256 nonTransferableSupplyAfter = veHemi.nonTransferableTotalVeHemiSupply();
        assertGt(nonTransferableSupplyAfter, nonTransferableSupplyBefore, "Non-transferable should increase with new forfeitable position");
    }

    // ═════════════════════════════════════════════════════════════════════
    //  9. CATCHUP LOOP — FORFEITABLE CURVE DECAYS ACROSS BOUNDARIES
    // ═════════════════════════════════════════════════════════════════════

    function test_CatchupLoop_ForfeitableDecays() public {
        (uint256 t1,,) = createForfeitablePosition(alice, 100 ether, LOCK_2Y);
        seedAndFinalize(_toArray(t1));

        uint256 supply0 = veHemi.forfeitableTotalVeHemiSupply();

        // Warp across multiple SIX_DAYS boundaries
        vm.warp(block.timestamp + 5 * SIX_DAYS);
        veHemi.checkpoint();

        uint256 supply1 = veHemi.forfeitableTotalVeHemiSupply();
        assertLt(supply1, supply0, "Should decay across boundaries");

        // Warp more
        vm.warp(block.timestamp + 10 * SIX_DAYS);
        veHemi.checkpoint();

        uint256 supply2 = veHemi.forfeitableTotalVeHemiSupply();
        assertLt(supply2, supply1, "Should continue decaying");
    }

    function test_CatchupLoop_ForfeitableAndNonTransferableDecayInParallel() public {
        (uint256 t1,,) = createForfeitablePosition(alice, 100 ether, LOCK_2Y);
        seedAndFinalize(_toArray(t1));

        // When only forfeitable positions exist, locked == forfeitable
        uint256 nonTransferable0 = veHemi.nonTransferableTotalVeHemiSupply();
        uint256 forfeitable0 = veHemi.forfeitableTotalVeHemiSupply();
        assertEq(nonTransferable0, forfeitable0, "Should be equal when all locked are forfeitable");

        _warpAndCheckpoint(30 days);

        uint256 nonTransferable1 = veHemi.nonTransferableTotalVeHemiSupply();
        uint256 forfeitable1 = veHemi.forfeitableTotalVeHemiSupply();
        assertEq(nonTransferable1, forfeitable1, "Should remain equal after decay");
    }

    // ═════════════════════════════════════════════════════════════════════
    //  10. INVARIANTS — forfeitable <= locked <= total
    // ═════════════════════════════════════════════════════════════════════

    function test_Invariant_ForfeitableLeNonTransferable_AfterOperations() public {
        _enableForfeitAdmin();

        (uint256 t1,,) = createNonTransferablePosition(alice, 100 ether, LOCK_2Y);
        (uint256 t2,,) = createForfeitablePosition(bob, 200 ether, LOCK_2Y);
        createTransferablePosition(charlie, 150 ether, LOCK_2Y);
        seedAndFinalize(_toArray(t1, t2));

        _assertInvariant("After seeding");

        // increaseAmount on forfeitable
        vm.startPrank(bob);
        hemi.mint(bob, 50 ether);
        hemi.approve(address(veHemi), type(uint256).max);
        veHemi.increaseAmount(t2, 50 ether);
        vm.stopPrank();
        _assertInvariant("After increaseAmount on forfeitable");

        // increaseAmount on non-transferable-only
        vm.startPrank(alice);
        hemi.mint(alice, 50 ether);
        hemi.approve(address(veHemi), type(uint256).max);
        veHemi.increaseAmount(t1, 50 ether);
        vm.stopPrank();
        _assertInvariant("After increaseAmount on non-transferable-only");

        // Warp forward
        _warpAndCheckpoint(90 days);
        _assertInvariant("After 90 day warp");

        // Forfeit bob's position
        veHemi.forfeit(t2);
        _assertInvariant("After forfeit");

        // Create new positions
        createForfeitablePosition(charlie, 100 ether, LOCK_2Y);
        _assertInvariant("After new forfeitable position");
    }

    function _assertInvariant(string memory label) internal view {
        (uint256 total, uint256 locked_, uint256 forfeitable_, uint256 transferable) = veHemi.supplyBreakdown();
        assertLe(forfeitable_, locked_, string.concat(label, ": forfeitable <= locked"));
        assertLe(locked_, total, string.concat(label, ": locked <= total"));
        assertEq(transferable, total - locked_, string.concat(label, ": transferable = total - locked"));
        // Cross-check individual functions match supplyBreakdown
        assertApproxEqRel(total, veHemi.totalVeHemiSupply(), 0.001e18, string.concat(label, ": total cross-check"));
        assertApproxEqRel(locked_, veHemi.nonTransferableTotalVeHemiSupply(), 0.001e18, string.concat(label, ": locked cross-check"));
        assertApproxEqRel(forfeitable_, veHemi.forfeitableTotalVeHemiSupply(), 0.001e18, string.concat(label, ": forfeitable cross-check"));
    }

    // ═════════════════════════════════════════════════════════════════════
    //  11. EDGE CASES
    // ═════════════════════════════════════════════════════════════════════

    function test_EdgeCase_AllPositionsForfeitable() public {
        (uint256 t1,,) = createForfeitablePosition(alice, 100 ether, LOCK_2Y);
        (uint256 t2,,) = createForfeitablePosition(bob, 200 ether, LOCK_2Y);
        seedAndFinalize(_toArray(t1, t2));

        uint256 locked = veHemi.nonTransferableTotalVeHemiSupply();
        uint256 forfeitable_ = veHemi.forfeitableTotalVeHemiSupply();
        assertEq(locked, forfeitable_, "When all locked are forfeitable, they should be equal");
    }

    function test_EdgeCase_SameBlockCreateAndCheckpoint() public {
        (uint256 t1,,) = createForfeitablePosition(alice, 100 ether, LOCK_2Y);
        seedAndFinalize(_toArray(t1));

        // Create another forfeitable in the same block
        (uint256 t2,,) = createForfeitablePosition(bob, 200 ether, LOCK_2Y);

        // Both should be tracked
        _assertInvariant("Same block create");
        assertGt(veHemi.forfeitableTotalVeHemiSupply(), 0, "Forfeitable should be positive");
    }

    function test_EdgeCase_WithdrawAndCreateSameBlock() public {
        (uint256 t1,, uint256 e1) = createForfeitablePosition(alice, 100 ether, LOCK_2Y);
        seedAndFinalize(_toArray(t1));

        // Warp to expiry
        vm.warp(e1 + 1);

        // Withdraw alice's expired position
        vm.prank(alice);
        veHemi.withdraw(t1);

        // Create new forfeitable in same block
        (,uint256 s2, uint256 e2) = createForfeitablePosition(bob, 200 ether, LOCK_2Y);

        uint256 expected = s2 * (e2 - block.timestamp);
        assertEq(veHemi.forfeitableTotalVeHemiSupply(), expected, "New position tracked after withdraw");
    }

    function test_EdgeCase_ForfeitAllThenCreateNew() public {
        _enableForfeitAdmin();

        (uint256 t1,,) = createForfeitablePosition(alice, 100 ether, LOCK_2Y);
        (uint256 t2,,) = createForfeitablePosition(bob, 100 ether, LOCK_2Y);
        seedAndFinalize(_toArray(t1, t2));

        // Forfeit all
        veHemi.forfeit(t1);
        veHemi.forfeit(t2);
        assertEq(veHemi.forfeitableTotalVeHemiSupply(), 0, "Should be 0 after all forfeited");

        // Create new
        (,uint256 s3, uint256 e3) = createForfeitablePosition(charlie, 300 ether, LOCK_2Y);
        uint256 expected = s3 * (e3 - block.timestamp);
        assertEq(veHemi.forfeitableTotalVeHemiSupply(), expected, "New position should be tracked");
    }

    function test_EdgeCase_TransferablePositionNotTracked() public {
        (uint256 t1,,) = createForfeitablePosition(alice, 100 ether, LOCK_2Y);
        seedAndFinalize(_toArray(t1));

        uint256 forfeitableBefore = veHemi.forfeitableTotalVeHemiSupply();

        // Create a transferable position — should not affect forfeitable curve
        createTransferablePosition(bob, 500 ether, LOCK_2Y);

        uint256 forfeitableAfter = veHemi.forfeitableTotalVeHemiSupply();
        assertEq(forfeitableAfter, forfeitableBefore, "Transferable should not affect forfeitable curve");
    }

    // ═════════════════════════════════════════════════════════════════════
    //  12. FUZZ TESTS
    // ═════════════════════════════════════════════════════════════════════

    function testFuzz_ForfeitableSubsetOfNonTransferable(uint256 lockedAmt, uint256 forfeitableAmt) public {
        lockedAmt = bound(lockedAmt, MIN_AMOUNT, 500 ether);
        forfeitableAmt = bound(forfeitableAmt, MIN_AMOUNT, 500 ether);

        (uint256 t1,,) = createNonTransferablePosition(alice, lockedAmt, LOCK_2Y);
        (uint256 t2,,) = createForfeitablePosition(bob, forfeitableAmt, LOCK_2Y);
        seedAndFinalize(_toArray(t1, t2));

        uint256 locked = veHemi.nonTransferableTotalVeHemiSupply();
        uint256 forf = veHemi.forfeitableTotalVeHemiSupply();
        assertGe(locked, forf, "locked >= forfeitable always");
    }

    function testFuzz_ForfeitableDecayMonotonic(uint256 amount, uint256 duration, uint256 warpTime) public {
        amount = bound(amount, MIN_AMOUNT, 500 ether);
        duration = bound(duration, 2 * SIX_DAYS, MAX_TIME / 2);
        warpTime = bound(warpTime, 1 days, 365 days);

        (uint256 t1,,) = createForfeitablePosition(alice, amount, duration);
        seedAndFinalize(_toArray(t1));

        uint256 supply0 = veHemi.forfeitableTotalVeHemiSupply();

        _warpAndCheckpoint(warpTime);

        uint256 supply1 = veHemi.forfeitableTotalVeHemiSupply();
        assertLe(supply1, supply0, "Forfeitable supply must be non-increasing over time");
    }

    function testFuzz_IncreaseAmount_ForfeitableCurve(uint256 initialAmt, uint256 addAmt) public {
        initialAmt = bound(initialAmt, MIN_AMOUNT, 300 ether);
        addAmt = bound(addAmt, MIN_AMOUNT, 300 ether);

        (uint256 t1,,) = createForfeitablePosition(alice, initialAmt, LOCK_2Y);
        seedAndFinalize(_toArray(t1));

        uint256 before = veHemi.forfeitableTotalVeHemiSupply();

        vm.startPrank(alice);
        hemi.mint(alice, addAmt);
        hemi.approve(address(veHemi), type(uint256).max);
        veHemi.increaseAmount(t1, addAmt);
        vm.stopPrank();

        uint256 after_ = veHemi.forfeitableTotalVeHemiSupply();
        assertGt(after_, before, "Forfeitable supply should increase");
    }

    function testFuzz_ForfeitReducesCurve(uint256 amount) public {
        _enableForfeitAdmin();
        amount = bound(amount, MIN_AMOUNT, 500 ether);

        (uint256 t1,,) = createForfeitablePosition(alice, amount, LOCK_2Y);
        seedAndFinalize(_toArray(t1));

        uint256 before = veHemi.forfeitableTotalVeHemiSupply();
        assertGt(before, 0, "Should be positive before forfeit");

        veHemi.forfeit(t1);

        assertEq(veHemi.forfeitableTotalVeHemiSupply(), 0, "Should be 0 after forfeit");
    }

    function testFuzz_MixedPositionTypes_InvariantHolds(
        uint256 transferableAmt,
        uint256 lockedAmt,
        uint256 forfeitableAmt
    ) public {
        transferableAmt = bound(transferableAmt, MIN_AMOUNT, 300 ether);
        lockedAmt = bound(lockedAmt, MIN_AMOUNT, 300 ether);
        forfeitableAmt = bound(forfeitableAmt, MIN_AMOUNT, 300 ether);

        (uint256 t1,,) = createNonTransferablePosition(alice, lockedAmt, LOCK_2Y);
        (uint256 t2,,) = createForfeitablePosition(bob, forfeitableAmt, LOCK_2Y);
        createTransferablePosition(charlie, transferableAmt, LOCK_2Y);
        seedAndFinalize(_toArray(t1, t2));

        _assertInvariant("Fuzz mixed positions");
    }

    function testFuzz_HistoricalQuery_MatchesSnapshot(uint256 amount, uint256 warpDays) public {
        amount = bound(amount, MIN_AMOUNT, 500 ether);
        warpDays = bound(warpDays, 1, 365);

        (uint256 t1,,) = createForfeitablePosition(alice, amount, LOCK_2Y);
        seedAndFinalize(_toArray(t1));

        uint256 snapshotTime = block.timestamp;
        uint256 snapshotSupply = veHemi.forfeitableTotalVeHemiSupply();

        _warpAndCheckpoint(warpDays * 1 days);

        uint256 pastSupply = veHemi.forfeitableTotalVeHemiSupplyAt(snapshotTime);
        assertEq(pastSupply, snapshotSupply, "Historical query should match snapshot");
    }

    function testFuzz_Breakdown_SumsCorrectly(
        uint256 lockedAmt,
        uint256 forfeitableAmt,
        uint256 transferableAmt
    ) public {
        lockedAmt = bound(lockedAmt, MIN_AMOUNT, 300 ether);
        forfeitableAmt = bound(forfeitableAmt, MIN_AMOUNT, 300 ether);
        transferableAmt = bound(transferableAmt, MIN_AMOUNT, 300 ether);

        (uint256 t1,,) = createNonTransferablePosition(alice, lockedAmt, LOCK_2Y);
        (uint256 t2,,) = createForfeitablePosition(bob, forfeitableAmt, LOCK_2Y);
        createTransferablePosition(charlie, transferableAmt, LOCK_2Y);
        seedAndFinalize(_toArray(t1, t2));

        (uint256 total, uint256 locked_, uint256 forfeitable_, uint256 transferable) = veHemi.supplyBreakdown();

        assertEq(total, locked_ + transferable, "total = locked + transferable");
        assertLe(forfeitable_, locked_, "forfeitable <= locked");
        assertGt(total, 0, "total > 0");
    }

    /// @notice Forfeitable supply should NOT change when a forfeitable position extends its lock.
    ///         The forfeitable subcurve is bounded by transferableAfter (original end), not lock.end.
    function testFuzz_IncreaseUnlockTime_ForfeitableCurveUnchanged(uint256 amount, uint256 initDuration, uint256 newDuration) public {
        amount = bound(amount, MIN_AMOUNT, 300 ether);
        initDuration = bound(initDuration, 2 * SIX_DAYS, MAX_TIME / 3);
        newDuration = bound(newDuration, initDuration + SIX_DAYS, MAX_TIME);

        (uint256 t1,,) = createForfeitablePosition(alice, amount, initDuration);
        seedAndFinalize(_toArray(t1));

        uint256 forfeitableBefore = veHemi.forfeitableTotalVeHemiSupply();
        uint256 totalBefore = veHemi.totalVeHemiSupply();

        vm.prank(alice);
        veHemi.increaseUnlockTime(t1, newDuration);

        // Global increases, forfeitable stays the same
        assertGt(veHemi.totalVeHemiSupply(), totalBefore, "Global should increase");
        assertEq(veHemi.forfeitableTotalVeHemiSupply(), forfeitableBefore, "Forfeitable should NOT change");
    }

    function testFuzz_SubsetInvariant_WithFuzzedDurations(
        uint256 lockedAmt,
        uint256 forfeitableAmt,
        uint256 lockedDuration,
        uint256 forfeitableDuration
    ) public {
        lockedAmt = bound(lockedAmt, MIN_AMOUNT, 300 ether);
        forfeitableAmt = bound(forfeitableAmt, MIN_AMOUNT, 300 ether);
        lockedDuration = bound(lockedDuration, 2 * SIX_DAYS, MAX_TIME / 2);
        forfeitableDuration = bound(forfeitableDuration, 2 * SIX_DAYS, MAX_TIME / 2);

        (uint256 t1,,) = createNonTransferablePosition(alice, lockedAmt, lockedDuration);
        (uint256 t2,,) = createForfeitablePosition(bob, forfeitableAmt, forfeitableDuration);
        seedAndFinalize(_toArray(t1, t2));

        _assertInvariant("Fuzz with different durations");
    }

    // ═════════════════════════════════════════════════════════════════════
    //  13. MEDIUM FIXES — MISSING CROSS-TYPE ISOLATION TESTS
    // ═════════════════════════════════════════════════════════════════════

    function test_IncreaseUnlockTime_NonTransferableOnlyDoesNotAffectForfeitable() public {
        (uint256 t1,,) = createNonTransferablePosition(alice, 100 ether, LOCK_2Y);
        (uint256 t2,,) = createForfeitablePosition(bob, 100 ether, LOCK_2Y);
        seedAndFinalize(_toArray(t1, t2));

        uint256 forfeitableBefore = veHemi.forfeitableTotalVeHemiSupply();

        vm.prank(alice);
        veHemi.increaseUnlockTime(t1, LOCK_3Y);

        uint256 forfeitableAfter = veHemi.forfeitableTotalVeHemiSupply();
        assertEq(forfeitableAfter, forfeitableBefore, "Non-transferable-only increaseUnlockTime should not affect forfeitable");

        // Non-transferable should increase though
        assertGt(veHemi.nonTransferableTotalVeHemiSupply(), forfeitableAfter, "Non-transferable should exceed forfeitable now");
    }

    function test_IncreaseAmount_TransferableDoesNotAffectNonTransferableOrForfeitable() public {
        (uint256 t1,,) = createNonTransferablePosition(alice, 100 ether, LOCK_2Y);
        (uint256 t2,,) = createForfeitablePosition(bob, 100 ether, LOCK_2Y);
        createTransferablePosition(charlie, 100 ether, LOCK_2Y);
        seedAndFinalize(_toArray(t1, t2));

        uint256 nonTransferableSupplyBefore = veHemi.nonTransferableTotalVeHemiSupply();
        uint256 forfeitableBefore = veHemi.forfeitableTotalVeHemiSupply();

        // Increase amount on charlie's transferable position
        uint256 charlieToken = veHemi.tokenOfOwnerByIndex(charlie, 0);
        vm.startPrank(charlie);
        hemi.mint(charlie, 50 ether);
        hemi.approve(address(veHemi), type(uint256).max);
        veHemi.increaseAmount(charlieToken, 50 ether);
        vm.stopPrank();

        assertEq(veHemi.nonTransferableTotalVeHemiSupply(), nonTransferableSupplyBefore, "Non-transferable should not change");
        assertEq(veHemi.forfeitableTotalVeHemiSupply(), forfeitableBefore, "Forfeitable should not change");
    }

    function test_Forfeit_ExactRemainingSupply() public {
        _enableForfeitAdmin();

        (uint256 t1, uint256 s1, uint256 e1) = createForfeitablePosition(alice, 100 ether, LOCK_2Y);
        (uint256 t2, uint256 s2, uint256 e2) = createForfeitablePosition(bob, 200 ether, LOCK_3Y);
        seedAndFinalize(_toArray(t1, t2));

        // Forfeit alice's position
        veHemi.forfeit(t1);

        // Bob's exact contribution should remain
        uint256 expectedForfeitable = s2 * (e2 - block.timestamp);
        assertEq(veHemi.forfeitableTotalVeHemiSupply(), expectedForfeitable, "Exact remaining forfeitable after partial forfeit");
    }

    // ═════════════════════════════════════════════════════════════════════
    //  14. EDGE CASES — BOUNDARIES AND STRESS
    // ═════════════════════════════════════════════════════════════════════

    function test_EdgeCase_MaxDuration_ForfeitablePosition() public {
        (uint256 t1, uint256 s1, uint256 e1) = createForfeitablePosition(alice, 100 ether, MAX_TIME);
        seedAndFinalize(_toArray(t1));

        uint256 supply = veHemi.forfeitableTotalVeHemiSupply();
        uint256 expected = s1 * (e1 - block.timestamp);
        assertEq(supply, expected, "Max duration forfeitable should be tracked");
        _assertInvariant("Max duration");
    }

    function test_EdgeCase_MinAmount_ForfeitablePosition() public {
        // Exactly MIN_LOCK_AMOUNT (10e18) — smallest possible position
        (uint256 t1, uint256 s1, uint256 e1) = createForfeitablePosition(alice, 10 ether, LOCK_2Y);
        seedAndFinalize(_toArray(t1));

        uint256 supply = veHemi.forfeitableTotalVeHemiSupply();
        uint256 expected = s1 * (e1 - block.timestamp);
        assertEq(supply, expected, "Min amount forfeitable should be tracked");
        assertGt(supply, 0, "Even min amount should produce non-zero supply");
    }

    function test_EdgeCase_ForfeitRightBeforeExpiry() public {
        _enableForfeitAdmin();

        (uint256 t1,, uint256 e1) = createForfeitablePosition(alice, 100 ether, LOCK_2Y);
        seedAndFinalize(_toArray(t1));

        // Warp to within the final SIX_DAYS period before expiry
        vm.warp(e1 - SIX_DAYS / 2);
        veHemi.checkpoint();

        uint256 supplyBefore = veHemi.forfeitableTotalVeHemiSupply();
        assertGt(supplyBefore, 0, "Should still have some supply near expiry");

        veHemi.forfeit(t1);

        assertEq(veHemi.forfeitableTotalVeHemiSupply(), 0, "Should be 0 after forfeit near expiry");
        _assertInvariant("After near-expiry forfeit");
    }

    function test_EdgeCase_LongCatchupGap() public {
        (uint256 t1,,) = createForfeitablePosition(alice, 100 ether, MAX_TIME);
        seedAndFinalize(_toArray(t1));

        uint256 supply0 = veHemi.forfeitableTotalVeHemiSupply();

        // Warp ~2 years (roughly 122 SIX_DAYS periods) without checkpointing
        vm.warp(block.timestamp + 2 * 365 days);
        veHemi.checkpoint();

        uint256 supply1 = veHemi.forfeitableTotalVeHemiSupply();
        assertLt(supply1, supply0, "Should decay after long gap");
        assertGt(supply1, 0, "Should still be positive (4yr lock, 2yr elapsed)");
        _assertInvariant("After long catchup gap");
    }

    function test_EdgeCase_DifferentDurations_StaggeredExpiry() public {
        (uint256 t1, uint256 s1, uint256 e1) = createForfeitablePosition(alice, 100 ether, LOCK_2Y);
        (uint256 t2,, uint256 e2) = createForfeitablePosition(bob, 100 ether, MAX_TIME);
        seedAndFinalize(_toArray(t1, t2));

        assertGt(e2, e1, "Bob's lock should end later");

        // Warp past alice's expiry but before bob's
        vm.warp(e1 + 1);
        veHemi.checkpoint();

        // Alice's contribution is gone, bob's remains
        uint256 supply = veHemi.forfeitableTotalVeHemiSupply();
        assertGt(supply, 0, "Bob's position should still contribute");

        // The forfeitable slope change at e1 should have already fired
        // so only bob's slope remains active
        _assertInvariant("After staggered expiry");
    }

    function test_EdgeCase_MultipleForfeitures_Interleaved() public {
        _enableForfeitAdmin();

        (uint256 t1,,) = createForfeitablePosition(alice, 100 ether, LOCK_2Y);
        (uint256 t2,,) = createForfeitablePosition(bob, 200 ether, LOCK_3Y);
        (uint256 t3,,) = createForfeitablePosition(charlie, 150 ether, MAX_TIME);
        seedAndFinalize(_toArray(t1, t2, t3));

        _assertInvariant("Initial");

        _warpAndCheckpoint(30 days);
        veHemi.forfeit(t1);
        _assertInvariant("After first forfeit + time");

        _warpAndCheckpoint(60 days);
        veHemi.forfeit(t2);
        _assertInvariant("After second forfeit + more time");

        // Only charlie remains
        assertGt(veHemi.forfeitableTotalVeHemiSupply(), 0, "Charlie should remain");

        _warpAndCheckpoint(90 days);
        veHemi.forfeit(t3);
        assertEq(veHemi.forfeitableTotalVeHemiSupply(), 0, "All forfeited");
        _assertInvariant("After all forfeited");
    }

    // ═════════════════════════════════════════════════════════════════════
    //  15. MULTI-OPERATION INVARIANT STRESS
    // ═════════════════════════════════════════════════════════════════════

    function test_Invariant_FullLifecycleStress() public {
        _enableForfeitAdmin();

        // Create all three position types
        (uint256 t1,,) = createNonTransferablePosition(alice, 100 ether, LOCK_2Y);
        (uint256 t2,,) = createForfeitablePosition(bob, 200 ether, LOCK_3Y);
        createTransferablePosition(charlie, 150 ether, LOCK_2Y);
        seedAndFinalize(_toArray(t1, t2));
        _assertInvariant("After seeding");

        // increaseAmount on forfeitable
        vm.startPrank(bob);
        hemi.mint(bob, 50 ether);
        hemi.approve(address(veHemi), type(uint256).max);
        veHemi.increaseAmount(t2, 50 ether);
        vm.stopPrank();
        _assertInvariant("After increaseAmount on forfeitable");

        // increaseUnlockTime on forfeitable
        vm.prank(bob);
        veHemi.increaseUnlockTime(t2, MAX_TIME);
        _assertInvariant("After increaseUnlockTime on forfeitable");

        // increaseAmount on non-transferable-only
        vm.startPrank(alice);
        hemi.mint(alice, 50 ether);
        hemi.approve(address(veHemi), type(uint256).max);
        veHemi.increaseAmount(t1, 50 ether);
        vm.stopPrank();
        _assertInvariant("After increaseAmount on non-transferable-only");

        // increaseUnlockTime on non-transferable-only
        vm.prank(alice);
        veHemi.increaseUnlockTime(t1, LOCK_3Y);
        _assertInvariant("After increaseUnlockTime on non-transferable-only");

        // Warp across boundaries
        _warpAndCheckpoint(90 days);
        _assertInvariant("After 90 day warp");

        // Create new forfeitable post-seeding (MAX_TIME to survive the full test)
        (uint256 t4,,) = createForfeitablePosition(alice, 100 ether, MAX_TIME);
        _assertInvariant("After new forfeitable");

        // Forfeit one position
        veHemi.forfeit(t2);
        _assertInvariant("After forfeit");

        // Warp to t1's expiry and withdraw
        uint256 t1End = veHemi.getLockedBalance(t1).end;
        vm.warp(t1End + 1);
        veHemi.checkpoint();
        vm.prank(alice);
        veHemi.withdraw(t1);
        _assertInvariant("After expired withdraw");

        // Warp more
        _warpAndCheckpoint(180 days);
        _assertInvariant("After another 180 days");

        // Forfeit the post-seeding position (still active due to MAX_TIME lock)
        veHemi.forfeit(t4);
        _assertInvariant("After second forfeit");
    }

    // ═════════════════════════════════════════════════════════════════════
    //  16. HISTORICAL QUERY AFTER OPERATIONS
    // ═════════════════════════════════════════════════════════════════════

    function test_HistoricalQuery_AfterForfeit() public {
        _enableForfeitAdmin();

        (uint256 t1,,) = createForfeitablePosition(alice, 100 ether, LOCK_2Y);
        (uint256 t2,,) = createForfeitablePosition(bob, 200 ether, LOCK_2Y);
        seedAndFinalize(_toArray(t1, t2));

        uint256 t0 = block.timestamp;
        uint256 supplyAtT0 = veHemi.forfeitableTotalVeHemiSupply();

        _warpAndCheckpoint(30 days);

        // Snapshot supply AFTER checkpoint so the epoch is recorded
        uint256 supplyAfterWarp = veHemi.forfeitableTotalVeHemiSupply();

        // Forfeit alice
        veHemi.forfeit(t1);

        uint256 supplyAfterForfeit = veHemi.forfeitableTotalVeHemiSupply();
        assertLt(supplyAfterForfeit, supplyAfterWarp, "Forfeit should reduce supply");

        _warpAndCheckpoint(30 days);

        // Historical query at t0 should match the original snapshot
        assertEq(veHemi.forfeitableTotalVeHemiSupplyAt(t0), supplyAtT0, "t0 should show both positions");
        // Current supply (after forfeit + more decay) should be less than pre-forfeit
        assertLt(veHemi.forfeitableTotalVeHemiSupply(), supplyAfterWarp, "Current < pre-forfeit");
    }

    // ═════════════════════════════════════════════════════════════════════
    //  17. SUBCURVE TRANSITION — POSITION EXITS LOCKED/FORFEITABLE CURVES
    // ═════════════════════════════════════════════════════════════════════

    /// @notice After increaseUnlockTime, the position eventually crosses its transferableAfter
    ///         boundary. At that point it should exit the locked/forfeitable curves while
    ///         remaining in the global curve.
    function test_SubcurveTransition_ExitOnTransferableAfter() public {
        // Create forfeitable with 2Y lock
        (uint256 t1, uint256 s1, uint256 originalEnd) = createForfeitablePosition(alice, 100 ether, LOCK_2Y);
        seedAndFinalize(_toArray(t1));

        // Extend lock to 3Y — transferableAfter stays at originalEnd
        vm.prank(alice);
        veHemi.increaseUnlockTime(t1, LOCK_3Y);

        uint256 newEnd = veHemi.getLockedBalance(t1).end;
        assertGt(newEnd, originalEnd, "Lock end extended");
        assertEq(veHemi.transferableAfter(t1), originalEnd, "transferableAfter unchanged");

        // Before transferableAfter: position is in all 3 curves
        uint256 forfeitableBefore = veHemi.forfeitableTotalVeHemiSupply();
        uint256 nonTransferableSupplyBefore = veHemi.nonTransferableTotalVeHemiSupply();
        uint256 totalBefore = veHemi.totalVeHemiSupply();
        assertGt(forfeitableBefore, 0, "Forfeitable should be positive before transition");
        assertGt(nonTransferableSupplyBefore, 0, "Non-transferable should be positive before transition");

        // Warp to just past transferableAfter (the original end)
        vm.warp(originalEnd + 1);
        veHemi.checkpoint();

        // After transferableAfter: position should have EXITED the subcurves
        assertEq(veHemi.forfeitableTotalVeHemiSupply(), 0, "Forfeitable should be 0 after transition");
        assertEq(veHemi.nonTransferableTotalVeHemiSupply(), 0, "Non-transferable should be 0 after transition");

        // But the global curve should still have voting power (lock.end hasn't passed)
        uint256 totalAfter = veHemi.totalVeHemiSupply();
        assertGt(totalAfter, 0, "Global should still be positive (lock.end not reached)");

        // The position is now transferable
        assertTrue(veHemi.isTransferable(t1), "Position should be transferable now");

        // Eventually, warp past lock.end — global should also drop to 0
        vm.warp(newEnd + 1);
        veHemi.checkpoint();
        assertEq(veHemi.totalVeHemiSupply(), 0, "Global should be 0 after lock.end");
    }

    /// @notice Forfeit window expires at transferableAfter. After that, the admin
    ///         can no longer forfeit the position even though the lock is still active.
    function test_ForfeitWindowExpires() public {
        _enableForfeitAdmin();

        (uint256 t1,,uint256 originalEnd) = createForfeitablePosition(alice, 100 ether, LOCK_2Y);
        seedAndFinalize(_toArray(t1));

        // Extend lock past the original end
        vm.prank(alice);
        veHemi.increaseUnlockTime(t1, LOCK_3Y);

        // Forfeit should work BEFORE transferableAfter
        // (but we want to test the expiry, so let's create a second position for this)
        (uint256 t2,,) = createForfeitablePosition(bob, 100 ether, LOCK_2Y);

        // Warp past the original end (transferableAfter)
        vm.warp(originalEnd + 1);

        // t1: lock is still active (extended to 3Y) but forfeit window expired
        assertGt(veHemi.getLockedBalance(t1).end, block.timestamp, "Lock still active");
        vm.expectRevert(VeHemi.ForfeitWindowExpired.selector);
        veHemi.forfeit(t1);

        // t2: transferableAfter == lock.end, and we're past both → LockExpired (checked before ForfeitWindowExpired)
        vm.expectRevert(VeHemi.LockExpired.selector);
        veHemi.forfeit(t2);
    }

    /// @notice After the transition, increaseAmount should still work but should NOT
    ///         add to the subcurves (the position is now transferable).
    function test_IncreaseAmountAfterTransition() public {
        (uint256 t1,,uint256 originalEnd) = createForfeitablePosition(alice, 100 ether, LOCK_2Y);
        seedAndFinalize(_toArray(t1));

        // Extend lock
        vm.prank(alice);
        veHemi.increaseUnlockTime(t1, LOCK_3Y);

        // Warp past transferableAfter
        vm.warp(originalEnd + 1);
        veHemi.checkpoint();

        uint256 nonTransferableSupplyBefore = veHemi.nonTransferableTotalVeHemiSupply();
        uint256 forfeitableBefore = veHemi.forfeitableTotalVeHemiSupply();
        uint256 totalBefore = veHemi.totalVeHemiSupply();

        // increaseAmount on a now-transferable position
        vm.startPrank(alice);
        hemi.mint(alice, 50 ether);
        hemi.approve(address(veHemi), type(uint256).max);
        veHemi.increaseAmount(t1, 50 ether);
        vm.stopPrank();

        // Subcurves should be unchanged (position is no longer in them)
        assertEq(veHemi.nonTransferableTotalVeHemiSupply(), nonTransferableSupplyBefore, "Locked unchanged after transition");
        assertEq(veHemi.forfeitableTotalVeHemiSupply(), forfeitableBefore, "Forfeitable unchanged after transition");
        // Global should increase
        assertGt(veHemi.totalVeHemiSupply(), totalBefore, "Global should increase");
    }

    /// @notice The supply breakdown should correctly partition after transition:
    ///         the position's voting power moves from locked to transferable bucket.
    function test_SupplyBreakdown_AfterTransition() public {
        (uint256 t1,,uint256 originalEnd) = createForfeitablePosition(alice, 100 ether, LOCK_2Y);
        createTransferablePosition(bob, 100 ether, LOCK_3Y); // transferable reference
        seedAndFinalize(_toArray(t1));

        // Extend alice's lock
        vm.prank(alice);
        veHemi.increaseUnlockTime(t1, LOCK_3Y);

        // Before transition: alice is in locked, bob is in transferable
        (uint256 total1, uint256 nonTransferable1, uint256 forf1, uint256 trans1) = veHemi.supplyBreakdown();
        assertGt(nonTransferable1, 0, "Locked before transition");
        assertGt(trans1, 0, "Transferable before transition");

        // Warp past transferableAfter
        vm.warp(originalEnd + 1);
        veHemi.checkpoint();

        // After transition: alice moves from locked to transferable bucket
        // Note: both alice and bob's positions have decayed over the 2-year warp,
        // so we can't compare absolute transferable values. The key invariant is:
        // locked drops to 0 and all remaining supply is transferable.
        (uint256 total2, uint256 nonTransferable2, uint256 forf2, uint256 trans2) = veHemi.supplyBreakdown();
        assertEq(nonTransferable2, 0, "Non-transferable should be 0 (alice exited)");
        assertEq(forf2, 0, "Forfeitable should be 0 (alice exited)");
        assertGt(trans2, 0, "Transferable should be positive (bob + alice)");
        assertEq(total2, trans2, "Total should equal transferable (no non-transferable positions remain)");

        _assertInvariant("After transition");
    }
}
