// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import "./NonTransferableCurveTestBase.sol";
import "../src/storage/VeHemiStorageV2.sol";

/// @title VeHemiMultiPositionExtensionTest
/// @notice Comprehensive test covering extension of multiple non-transferable-only AND locked+forfeitable
///         positions by various amounts, with full weight verification at 8 timestamps.
///
///         Setup:
///           - 3 non-transferable-only positions: 1yr, 2yr, 3yr
///           - 3 forfeitable positions: 1yr, 2yr, 3yr
///           - All 6 seeded
///           - Each extended by different amounts (+6mo, +1yr, +2yr)
///
///         After extension, each position has a DIFFERENT transferableAfter vs lock.end:
///           - Subcurve weight uses min(lock.end, transferableAfter) as effective end
///           - Global weight uses lock.end
///
///         Verifies exact equality at t0, t0+6mo, t0+1yr, t0+1.5yr, t0+2yr, t0+2.5yr, t0+3yr, t0+4yr.
contract VeHemiMultiPositionExtensionTest is NonTransferableCurveTestBase {
    uint256 constant LOCK_1Y = 1 * 365 days;
    uint256 constant LOCK_2Y = 2 * 365 days;
    uint256 constant LOCK_3Y = 3 * 365 days;

    // Position info
    struct PosInfo {
        uint256 tokenId;
        uint256 slope;              // amount / MAX_TIME (integer division)
        uint256 lockEnd;            // current lock.end after extension (global curve endpoint)
        uint256 transferableAfter;  // original lock.end (subcurve endpoint)
        bool isForfeitable;
    }

    PosInfo[] internal positions;

    // Extra users beyond alice/bob/charlie (which are defined in NonTransferableCurveTestBase)
    address dave = address(0x7788);
    address eve = address(0x99AA);
    address frank = address(0xBBCC);

    // Owner array for extensions
    address[6] internal posOwners;

    function setUp() public override {
        super.setUp();

        // Mint and approve for additional users
        address[3] memory extras = [dave, eve, frank];
        for (uint256 i; i < 3; i++) {
            hemi.mint(extras[i], 10_000 ether);
            vm.prank(extras[i]);
            hemi.approve(address(veHemi), type(uint256).max);
        }

        // Enable forfeit admin (needed for forfeitable positions)
        veHemi.updateForfeitAdmin(admin);

        posOwners = [alice, bob, charlie, dave, eve, frank];
    }

    // ── Position creation and recording helpers ──────────────────────────

    function _createAndRecordNonTransferable(address account_, uint256 amount_, uint256 duration_) internal {
        vm.startPrank(admin);
        hemi.mint(admin, amount_);
        hemi.approve(address(veHemi), type(uint256).max);
        uint256 tokenId = veHemi.createLockFor(amount_, duration_, account_, false, false);
        vm.stopPrank();

        uint256 slope = amount_ / MAX_TIME;
        uint256 end = veHemi.getLockedBalance(tokenId).end;
        positions.push(PosInfo(tokenId, slope, end, end, false));
    }

    function _createAndRecordForfeitable(address account_, uint256 amount_, uint256 duration_) internal {
        vm.startPrank(admin);
        hemi.mint(admin, amount_);
        hemi.approve(address(veHemi), type(uint256).max);
        uint256 tokenId = veHemi.createLockFor(amount_, duration_, account_, false, true);
        vm.stopPrank();

        uint256 slope = amount_ / MAX_TIME;
        uint256 end = veHemi.getLockedBalance(tokenId).end;
        positions.push(PosInfo(tokenId, slope, end, end, true));
    }

    /// @dev Sort token IDs ascending for seedAndFinalizeNonTransferablePositions
    function _sortedIds() internal view returns (uint256[] memory sorted) {
        sorted = new uint256[](positions.length);
        for (uint256 i; i < positions.length; i++) {
            sorted[i] = positions[i].tokenId;
        }
        // Insertion sort
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

    // ── Independent supply calculations ──────────────────────────────────

    /// @dev Expected global supply at time t: sum(slope_i * max(0, lockEnd_i - t))
    function _expectedGlobalSupply(uint256 t) internal view returns (uint256 total) {
        for (uint256 i; i < positions.length; i++) {
            if (positions[i].lockEnd > t) {
                total += positions[i].slope * (positions[i].lockEnd - t);
            }
        }
    }

    /// @dev Expected locked (non-transferable) supply at time t.
    ///      Effective end = min(lockEnd, transferableAfter). Active only when transferableAfter > t.
    function _expectedNonTransferableSupply(uint256 t) internal view returns (uint256 total) {
        for (uint256 i; i < positions.length; i++) {
            PosInfo memory p = positions[i];
            if (p.transferableAfter <= t) continue;
            uint256 effEnd = p.lockEnd < p.transferableAfter ? p.lockEnd : p.transferableAfter;
            if (effEnd > t) {
                total += p.slope * (effEnd - t);
            }
        }
    }

    /// @dev Expected forfeitable supply at time t (same as locked but filtered to forfeitable only).
    function _expectedForfeitableSupply(uint256 t) internal view returns (uint256 total) {
        for (uint256 i; i < positions.length; i++) {
            PosInfo memory p = positions[i];
            if (!p.isForfeitable) continue;
            if (p.transferableAfter <= t) continue;
            uint256 effEnd = p.lockEnd < p.transferableAfter ? p.lockEnd : p.transferableAfter;
            if (effEnd > t) {
                total += p.slope * (effEnd - t);
            }
        }
    }

    // ── Full verification helper ─────────────────────────────────────────

    function _verifyAtTime(uint256 t, string memory label) internal {
        vm.warp(t);
        veHemi.checkpoint();

        uint256 expectedGlobal = _expectedGlobalSupply(t);
        uint256 expectedNonTransferable = _expectedNonTransferableSupply(t);
        uint256 expectedForfeitable = _expectedForfeitableSupply(t);

        uint256 actualGlobal = veHemi.totalVeHemiSupply();
        uint256 actualNonTransferable = veHemi.nonTransferableTotalVeHemiSupply();
        uint256 actualForfeitable = veHemi.forfeitableTotalVeHemiSupply();

        // Exact equality against shadow
        assertEq(actualGlobal, expectedGlobal, string.concat(label, ": global supply"));
        assertEq(actualNonTransferable, expectedNonTransferable, string.concat(label, ": non-transferable supply"));
        assertEq(actualForfeitable, expectedForfeitable, string.concat(label, ": forfeitable supply"));

        // supplyBreakdown consistency
        (uint256 bdTotal, uint256 bdNonTransferable, uint256 bdForf, uint256 bdTrans) = veHemi.supplyBreakdown();
        assertEq(bdTotal, actualGlobal, string.concat(label, ": breakdown total"));
        assertEq(bdNonTransferable, actualNonTransferable, string.concat(label, ": breakdown locked"));
        assertEq(bdForf, actualForfeitable, string.concat(label, ": breakdown forfeitable"));
        assertEq(bdTrans, actualGlobal - actualNonTransferable, string.concat(label, ": breakdown transferable"));

        // Ordering invariant: forfeitable <= locked <= total
        assertLe(actualForfeitable, actualNonTransferable, string.concat(label, ": forfeitable <= locked"));
        assertLe(actualNonTransferable, actualGlobal, string.concat(label, ": locked <= total"));
    }

    // ═════════════════════════════════════════════════════════════════════
    //  THE COMPREHENSIVE MULTI-POSITION EXTENSION TEST
    // ═════════════════════════════════════════════════════════════════════

    function test_MultiPositionExtension_ComprehensiveWeightVerification() public {
        uint256 amount = 100 ether;

        // Step 1: Create 3 non-transferable-only positions (1yr, 2yr, 3yr)
        _createAndRecordNonTransferable(alice, amount, LOCK_1Y);
        _createAndRecordNonTransferable(bob, amount, LOCK_2Y);
        _createAndRecordNonTransferable(charlie, amount, LOCK_3Y);

        // Step 2: Create 3 forfeitable positions (1yr, 2yr, 3yr)
        _createAndRecordForfeitable(dave, amount, LOCK_1Y);
        _createAndRecordForfeitable(eve, amount, LOCK_2Y);
        _createAndRecordForfeitable(frank, amount, LOCK_3Y);

        // Step 3: Seed all 6 positions
        veHemi.seedAndFinalizeNonTransferablePositions(_sortedIds());

        uint256 t0 = block.timestamp;

        // Verify initial state (all transferableAfter == lock.end, subcurve == global)
        _verifyAtTime(t0, "t0 (initial)");

        // Step 4: Extend each by different amounts
        _extendPositions(t0);

        // Verify all 6 positions now have transferableAfter < lockEnd
        for (uint256 i; i < 6; i++) {
            assertLt(
                positions[i].transferableAfter,
                positions[i].lockEnd,
                string.concat("Pos ", vm.toString(i), ": TA < lockEnd after extension")
            );
        }

        // Step 5: Verify at 8 timestamps
        _verifyAllTimestamps(t0);

        // Step 6: Additional targeted checks
        _verifySubcurveExits(t0);
    }

    function _extendPositions(uint256 /* t0 */) internal {
        // Extension target durations from now:
        //   pos 0 (locked, 1yr):       +6mo  -> total ~1.5yr from now
        //   pos 1 (locked, 2yr):       +1yr  -> total ~3yr from now
        //   pos 2 (locked, 3yr):       +2yr  -> may approach MAX_TIME
        //   pos 3 (forfeitable, 1yr):  +6mo  -> total ~1.5yr from now
        //   pos 4 (forfeitable, 2yr):  +1yr  -> total ~3yr from now
        //   pos 5 (forfeitable, 3yr):  +2yr  -> may approach MAX_TIME

        uint256[6] memory targetDurations = [
            uint256(LOCK_1Y + LOCK_1Y / 2),   // ~1.5yr
            uint256(LOCK_3Y),                   // 3yr
            uint256(LOCK_3Y + LOCK_2Y),         // ~5yr (capped to MAX_TIME)
            uint256(LOCK_1Y + LOCK_1Y / 2),     // ~1.5yr
            uint256(LOCK_3Y),                    // 3yr
            uint256(LOCK_3Y + LOCK_2Y)           // ~5yr (capped to MAX_TIME)
        ];

        for (uint256 i; i < 6; i++) {
            uint256 newDuration = targetDurations[i];
            if (newDuration > MAX_TIME) newDuration = MAX_TIME;

            uint256 newEnd = ((block.timestamp + newDuration) / SIX_DAYS) * SIX_DAYS;
            if (newEnd <= positions[i].lockEnd) continue;

            vm.prank(posOwners[i]);
            veHemi.increaseUnlockTime(positions[i].tokenId, newDuration);

            // Update shadow: lockEnd changes, transferableAfter stays at original end
            positions[i].lockEnd = veHemi.getLockedBalance(positions[i].tokenId).end;

            // Verify transferableAfter did NOT change
            assertEq(
                veHemi.transferableAfter(positions[i].tokenId),
                positions[i].transferableAfter,
                string.concat("TA unchanged for pos ", vm.toString(i))
            );
        }
    }

    function _verifyAllTimestamps(uint256 t0) internal {
        //   t0             (just after extension, all subcurves active)
        //   t0 + 6mo       (still before shortest transferableAfter)
        //   t0 + 1yr       (at/near transferableAfter for 1yr locks)
        //   t0 + 1.5yr     (past 1yr TA, before 2yr TA)
        //   t0 + 2yr       (at/near transferableAfter for 2yr locks)
        //   t0 + 2.5yr     (past 2yr TA, before 3yr TA)
        //   t0 + 3yr       (at/near transferableAfter for 3yr locks)
        //   t0 + 4yr       (past all lock ends, everything 0 or near 0)

        _verifyAtTime(t0, "t0 (post-ext)");
        _verifyAtTime(t0 + YEAR / 2, "t0 + 6mo");
        _verifyAtTime(t0 + YEAR, "t0 + 1yr");
        _verifyAtTime(t0 + YEAR + YEAR / 2, "t0 + 1.5yr");
        _verifyAtTime(t0 + 2 * YEAR, "t0 + 2yr");
        _verifyAtTime(t0 + 2 * YEAR + YEAR / 2, "t0 + 2.5yr");
        _verifyAtTime(t0 + 3 * YEAR, "t0 + 3yr");
        _verifyAtTime(t0 + 4 * YEAR, "t0 + 4yr");
    }

    function _verifySubcurveExits(uint256 t0) internal {
        // Check subcurve exits at the 1yr transferableAfter boundary
        // We use SupplyAt (historical query) since we already warped past this time
        // in _verifyAllTimestamps. Subcurve exits are verified via supply comparison
        // at timestamps we already checkpointed through.
        uint256 ta1yr = positions[0].transferableAfter;

        // Use historical query at ta1yr + 1 (already checkpointed through this)
        uint256 nonTransferableSupply = veHemi.nonTransferableTotalVeHemiSupplyAt(ta1yr + 1);
        uint256 expectedNonTransferable = _expectedNonTransferableSupply(ta1yr + 1);
        assertEq(nonTransferableSupply, expectedNonTransferable, "After 1yr TA: locked excludes exited positions");

        // Verify positions 0 and 3 (1yr TAs) have global VP at ta1yr+1 (their locks extend past)
        if (positions[0].lockEnd > ta1yr + 1) {
            uint256 vp0 = veHemi.balanceOfNFTAt(positions[0].tokenId, ta1yr + 1);
            assertGt(vp0, 0, "Pos 0: global VP at ta1yr+1");
        }
        if (positions[3].lockEnd > ta1yr + 1) {
            uint256 vp3 = veHemi.balanceOfNFTAt(positions[3].tokenId, ta1yr + 1);
            assertGt(vp3, 0, "Pos 3: global VP at ta1yr+1");
        }

        // Now verify the post-4yr state (we're already at t0+4yr from _verifyAllTimestamps)
        // Warp forward slightly past 4yr to ensure all expired
        vm.warp(t0 + 4 * YEAR + 1 days);
        veHemi.checkpoint();

        assertEq(
            veHemi.totalVeHemiSupply(),
            _expectedGlobalSupply(block.timestamp),
            "Post-4yr: global supply"
        );
        assertEq(veHemi.nonTransferableTotalVeHemiSupply(), 0, "Post-4yr: locked should be 0");
        assertEq(veHemi.forfeitableTotalVeHemiSupply(), 0, "Post-4yr: forfeitable should be 0");

        // Verify isTransferable for all positions at this point
        for (uint256 i; i < positions.length; i++) {
            assertTrue(
                veHemi.isTransferable(positions[i].tokenId),
                string.concat("Pos ", vm.toString(i), ": transferable post-4yr")
            );
        }
    }

    // ═════════════════════════════════════════════════════════════════════
    //  BONUS: Historical query verification at transition points
    // ═════════════════════════════════════════════════════════════════════

    function test_MultiPositionExtension_HistoricalQueries() public {
        uint256 amount = 100 ether;

        // Create all 6 positions
        _createAndRecordNonTransferable(alice, amount, LOCK_1Y);
        _createAndRecordNonTransferable(bob, amount, LOCK_2Y);
        _createAndRecordNonTransferable(charlie, amount, LOCK_3Y);
        _createAndRecordForfeitable(dave, amount, LOCK_1Y);
        _createAndRecordForfeitable(eve, amount, LOCK_2Y);
        _createAndRecordForfeitable(frank, amount, LOCK_3Y);

        veHemi.seedAndFinalizeNonTransferablePositions(_sortedIds());

        uint256 t0 = block.timestamp;

        // Extend all by +1yr (those that can)
        _extendAllByOneYear();

        // Snapshot expected values at t0 (post-extension, same block)
        uint256 expGlobalT0 = _expectedGlobalSupply(t0);
        uint256 expNonTransferableT0 = _expectedNonTransferableSupply(t0);
        uint256 expForfT0 = _expectedForfeitableSupply(t0);

        // Warp forward 6 months and checkpoint
        vm.warp(t0 + YEAR / 2);
        veHemi.checkpoint();

        uint256 t1 = block.timestamp;
        uint256 t1Global = veHemi.totalVeHemiSupply();
        uint256 t1NonTransferable = veHemi.nonTransferableTotalVeHemiSupply();
        uint256 t1Forfeitable = veHemi.forfeitableTotalVeHemiSupply();

        // Warp forward another 6 months and checkpoint (to enable historical queries)
        vm.warp(t0 + YEAR);
        veHemi.checkpoint();

        // Historical query at t0
        assertEq(veHemi.totalVeHemiSupplyAt(t0), expGlobalT0, "Hist global at t0");
        assertEq(veHemi.nonTransferableTotalVeHemiSupplyAt(t0), expNonTransferableT0, "Hist non-transferable at t0");
        assertEq(veHemi.forfeitableTotalVeHemiSupplyAt(t0), expForfT0, "Hist forfeitable at t0");

        // Historical query at t1
        assertEq(veHemi.totalVeHemiSupplyAt(t1), t1Global, "Hist global at t1");
        assertEq(veHemi.nonTransferableTotalVeHemiSupplyAt(t1), t1NonTransferable, "Hist non-transferable at t1");
        assertEq(veHemi.forfeitableTotalVeHemiSupplyAt(t1), t1Forfeitable, "Hist forfeitable at t1");
    }

    function _extendAllByOneYear() internal {
        for (uint256 i; i < positions.length; i++) {
            uint256 currentDuration = positions[i].lockEnd - block.timestamp;
            uint256 newDuration = currentDuration + LOCK_1Y;
            if (newDuration > MAX_TIME) newDuration = MAX_TIME;

            uint256 newEnd = ((block.timestamp + newDuration) / SIX_DAYS) * SIX_DAYS;
            if (newEnd <= positions[i].lockEnd) continue;

            vm.prank(posOwners[i]);
            veHemi.increaseUnlockTime(positions[i].tokenId, newDuration);
            positions[i].lockEnd = veHemi.getLockedBalance(positions[i].tokenId).end;
        }
    }
}
