// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {Test} from "forge-std/Test.sol";
import {VeHemi} from "../src/VeHemi.sol";
import {VeHemiVoteDelegation} from "../src/VeHemiVoteDelegation.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {MockERC20} from "./mocks/MockERC20.sol";

/// @title SeedingFlow
/// @notice Behavioral coverage for the 3-phase seeding flow:
///         `markSeedingStarted` → `seedBatch(maxIterations)` (one or many)
///         → `finalizeSeeding`. The flow replaces a single-shot
///         caller-supplied-list seeder with an on-chain enumeration that
///         eliminates two failure modes:
///
///           1. Operator drift between off-chain list derivation and Safe
///              execution (omitted positions permanently understate the
///              locked subcurve).
///           2. Adversarial front-run via a permissionless non-transferable
///              mint inserted into the gap between list snapshot and Safe
///              execution.
///
///         Each test pins one observable property of the flow so a future
///         refactor that re-introduces the original bug class fails loudly.
contract SeedingFlowTest is Test {
    VeHemi internal veHemi;
    VeHemiVoteDelegation internal delegation;
    MockERC20 internal hemi;

    address internal owner = address(this);
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal carol = makeAddr("carol");
    address internal attacker = makeAddr("attacker");

    uint256 internal constant YEAR = 365.25 days;
    uint256 internal constant MONTH = YEAR / 12;
    uint256 internal constant SIX_DAYS = MONTH / 5;
    uint256 internal constant MAX_TIME = 4 * YEAR;
    uint256 internal constant LOCK_2Y = 2 * YEAR;
    uint256 internal constant LOCK_3Y = 3 * YEAR;
    uint256 internal constant LOCK_SHORT = 2 * SIX_DAYS;
    uint256 internal constant LOCK_AMOUNT = 100 ether;
    uint256 internal constant TOPUP_AMOUNT = 50 ether;

    /// @dev Slot constants for direct storage probes of `_seedingProgress`.
    ///      `_seedingProgress` lives at slot 23 (struct base = first member
    ///      `lastProcessedId`); `count` lives at slot 26; `minSubEnd` lives
    ///      at slot 27 (the 5th and final struct slot). These are pinned by
    ///      `test_VeHemi_SeedingProgressMemberLayout` in `StorageLayoutGolden.t.sol`
    ///      AND by `test_slot23to27_seedingProgressLayout` in
    ///      `VeHemiStorageLayout.t.sol`. If a future V3 reshuffle moves the
    ///      struct, update both pins AND this constant.
    uint256 internal constant SLOT_SEEDING_PROGRESS_BASE = 23;
    uint256 internal constant SLOT_SEEDING_PROGRESS_COUNT = 26;
    uint256 internal constant SLOT_SEEDING_PROGRESS_MIN_SUBEND = 27;

    event SeedingStarted(uint256 seedingTargetId);
    event LockedSeedingFinalized(uint256 epoch);

    function setUp() public {
        hemi = new MockERC20("HEMI", "HEMI", 18);

        VeHemi logic = new VeHemi(address(hemi));
        ERC1967Proxy proxy = new ERC1967Proxy(
            address(logic), abi.encodeWithSelector(VeHemi.initialize.selector, owner)
        );
        veHemi = VeHemi(address(proxy));

        delegation = new VeHemiVoteDelegation(address(veHemi));
        veHemi.updateVoteDelegation(delegation);

        hemi.mint(alice, 10_000 ether);
        hemi.mint(bob, 10_000 ether);
        hemi.mint(carol, 10_000 ether);
        hemi.mint(attacker, 10_000 ether);
        // The owner (test contract) calls `createLockFor` directly in
        // helpers; createLockFor pulls HEMI from msg.sender, so fund + approve.
        hemi.mint(owner, 1_000_000 ether);
        hemi.approve(address(veHemi), type(uint256).max);

        vm.prank(alice);
        hemi.approve(address(veHemi), type(uint256).max);
        vm.prank(bob);
        hemi.approve(address(veHemi), type(uint256).max);
        vm.prank(carol);
        hemi.approve(address(veHemi), type(uint256).max);
        vm.prank(attacker);
        hemi.approve(address(veHemi), type(uint256).max);
    }

    // ─────────────────────────────────────────────────────────────────────
    // markSeedingStarted: preconditions and state snapshot
    // ─────────────────────────────────────────────────────────────────────

    function test_markSeedingStarted_snapshotsTargetIdAndSetsFlag() public {
        // Mint a few positions so nextTokenId moves forward.
        _mintLocked(alice, LOCK_AMOUNT, LOCK_2Y);
        _mintLocked(bob, LOCK_AMOUNT, LOCK_2Y);
        uint256 nextBeforeMark = veHemi.nextTokenId();
        assertEq(nextBeforeMark, 3, "two mints => nextTokenId == 3");

        vm.expectEmit(true, true, true, true, address(veHemi));
        emit SeedingStarted(nextBeforeMark);
        veHemi.markSeedingStarted();

        assertTrue(veHemi.seedingStarted(), "flag must be set");
        assertEq(veHemi.seedingTargetId(), nextBeforeMark, "target frozen at pre-mark nextTokenId");
    }

    function test_markSeedingStarted_revertsOnDoubleCall() public {
        veHemi.markSeedingStarted();
        vm.expectRevert(VeHemi.SeedingAlreadyStarted.selector);
        veHemi.markSeedingStarted();
    }

    function test_markSeedingStarted_revertsAfterFinalization() public {
        veHemi.markSeedingStarted();
        veHemi.seedBatch(type(uint256).max);
        veHemi.finalizeSeeding();

        // `seedingStarted` is set on markSeedingStarted and never cleared, so
        // re-calling after finalization reverts with SeedingAlreadyStarted
        // (the dead `lockedSeedingFinalized` check was removed for bytecode).
        vm.expectRevert(VeHemi.SeedingAlreadyStarted.selector);
        veHemi.markSeedingStarted();
    }

    function test_markSeedingStarted_revertsForNonOwner() public {
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", attacker));
        veHemi.markSeedingStarted();
    }

    /// @notice MULTI-BLOCK REGRESSION: the single-block atomicity guard that
    ///         previously gated `seedBatch`/`finalizeSeeding` has been removed
    ///         (Hemi mainnet has 30K+ non-transferable positions, far beyond a
    ///         single-block budget). Cross-block execution must now SUCCEED
    ///         and produce totals identical to a single-block scan, as long
    ///         as the immutability guards on non-transferable positions hold
    ///         throughout the window.
    function test_seedingFlow_multiBlock_finalizeAcrossBlockBoundary_succeeds() public {
        // Mint a short-lived non-transferable so subEnd is close.
        (, uint256 lockEnd) = _mintLocked(alice, LOCK_AMOUNT, LOCK_SHORT);

        veHemi.markSeedingStarted();
        veHemi.seedBatch(type(uint256).max);

        // Warp forward — multi-block finalize must succeed.
        uint256 finalizeTs = block.timestamp + 1 hours;
        vm.warp(finalizeTs);
        veHemi.finalizeSeeding();

        // Decayed bias from finalize time forward, evaluated at the
        // finalize timestamp.
        uint256 slope = LOCK_AMOUNT / MAX_TIME;
        uint256 expected = slope * (lockEnd - finalizeTs);
        assertEq(
            veHemi.nonTransferableTotalVeHemiSupplyAt(finalizeTs),
            expected,
            "multi-block finalize totals must match single-block math"
        );
    }

    function test_seedingFlow_multiBlock_seedBatchAcrossBlockBoundary_succeeds() public {
        _mintLocked(alice, LOCK_AMOUNT, LOCK_SHORT);

        veHemi.markSeedingStarted();
        vm.warp(block.timestamp + 1);

        // Multi-block seedBatch must succeed — the operator can run a
        // catchup loop across many blocks at mainnet scale.
        veHemi.seedBatch(type(uint256).max);
        assertEq(_progressLastProcessedId(), 1, "cursor advanced across block boundary");
    }

    // ─────────────────────────────────────────────────────────────────────
    // seedBatch: range, skip semantics, cursor advance
    // ─────────────────────────────────────────────────────────────────────

    function test_seedBatch_revertsIfNotStarted() public {
        vm.expectRevert(VeHemi.SeedingNotStarted.selector);
        veHemi.seedBatch(10);
    }

    function test_seedBatch_revertsAfterFinalization() public {
        veHemi.markSeedingStarted();
        veHemi.seedBatch(type(uint256).max);
        veHemi.finalizeSeeding();

        vm.expectRevert(VeHemi.SeedingAlreadyFinalized.selector);
        veHemi.seedBatch(10);
    }

    /// @notice PERMISSIONLESS: `seedBatch` may be called by any account once
    ///         seeding is started. The cursor only advances monotonically and
    ///         the per-iteration math is a deterministic read of immutable
    ///         non-transferable position state — so the gas cost falls on the
    ///         caller and no attacker can corrupt the accumulator. Keepers /
    ///         community callers may help advance seeding without owner
    ///         intervention.
    function test_seedBatch_permissionlessCaller_succeeds() public {
        _mintLocked(alice, LOCK_AMOUNT, LOCK_2Y);
        veHemi.markSeedingStarted();

        vm.prank(attacker);
        veHemi.seedBatch(type(uint256).max);
        assertEq(_progressLastProcessedId(), 1, "attacker-driven cursor advance succeeded");
    }

    /// @notice PERMISSIONLESS PRE-START: a non-owner call BEFORE
    ///         `markSeedingStarted` must revert with `SeedingNotStarted`
    ///         (start-latch precondition), not with an owner error. The
    ///         `onlyOwner` modifier on `seedBatch` was removed; ordering of
    ///         remaining checks is verified here.
    function test_seedBatch_revertsForAnyCaller_beforeStart() public {
        vm.prank(attacker);
        vm.expectRevert(VeHemi.SeedingNotStarted.selector);
        veHemi.seedBatch(10);
    }

    function test_seedBatch_advancesCursorMonotonically() public {
        _mintLocked(alice, LOCK_AMOUNT, LOCK_2Y); // tokenId 1
        _mintLocked(bob, LOCK_AMOUNT, LOCK_2Y); // tokenId 2
        _mintLocked(carol, LOCK_AMOUNT, LOCK_2Y); // tokenId 3

        veHemi.markSeedingStarted();
        // First batch: covers IDs [1, 2)
        veHemi.seedBatch(1);
        assertEq(_progressLastProcessedId(), 1, "after 1 step: cursor == 1");

        // Second batch: covers IDs [2, 3)
        veHemi.seedBatch(1);
        assertEq(_progressLastProcessedId(), 2, "after 2 steps: cursor == 2");

        // Third batch: covers IDs [3, 4) (4 == seedingTargetId)
        veHemi.seedBatch(1);
        assertEq(_progressLastProcessedId(), 3, "after 3 steps: cursor == 3");

        // Extra batch is a no-op (cursor already at the end).
        veHemi.seedBatch(1);
        assertEq(_progressLastProcessedId(), 3, "extra batch is structural no-op");
    }

    function test_seedBatch_clampsToSeedingTargetId() public {
        _mintLocked(alice, LOCK_AMOUNT, LOCK_2Y);
        _mintLocked(bob, LOCK_AMOUNT, LOCK_2Y);
        veHemi.markSeedingStarted(); // target == 3

        // Request a batch much larger than the remaining range. The cursor
        // should clamp at seedingTargetId - 1 = 2 without overflowing.
        veHemi.seedBatch(type(uint256).max);
        assertEq(_progressLastProcessedId(), 2, "cursor clamps to target - 1");
    }

    function test_seedBatch_skipsBurnedTokens() public {
        // Mint a short-lived position, burn it via withdraw, then mint two more.
        (uint256 burned,) = _mintLocked(alice, LOCK_AMOUNT, LOCK_SHORT);
        vm.warp(veHemi.getLockedBalance(burned).end + 1);
        vm.prank(alice);
        veHemi.withdraw(burned);
        (, uint256 e1) = _mintLocked(bob, LOCK_AMOUNT, LOCK_2Y);
        (, uint256 e2) = _mintLocked(carol, LOCK_AMOUNT, LOCK_2Y);

        veHemi.markSeedingStarted();
        veHemi.seedBatch(type(uint256).max);
        veHemi.finalizeSeeding();

        // Only bob and carol contribute; alice's burned position is skipped.
        uint256 expected;
        unchecked {
            expected = (LOCK_AMOUNT / MAX_TIME) * (e1 - block.timestamp)
                + (LOCK_AMOUNT / MAX_TIME) * (e2 - block.timestamp);
        }
        assertEq(veHemi.nonTransferableTotalVeHemiSupply(), expected, "burned ID must be skipped");
    }

    function test_seedBatch_skipsTransferablePositions() public {
        // Transferable positions (transferableAfter == 0) are NOT part of
        // the locked subcurve and must be silently skipped by the scan.
        _mintTransferable(alice, LOCK_AMOUNT, LOCK_2Y);
        (, uint256 e2) = _mintLocked(bob, LOCK_AMOUNT, LOCK_2Y);

        veHemi.markSeedingStarted();
        veHemi.seedBatch(type(uint256).max);
        veHemi.finalizeSeeding();

        uint256 expected = (LOCK_AMOUNT / MAX_TIME) * (e2 - block.timestamp);
        assertEq(
            veHemi.nonTransferableTotalVeHemiSupply(), expected, "transferable position must be skipped"
        );
    }

    function test_seedBatch_skipsPositionsWithExpiredTransferableAfter() public {
        // A non-transferable position whose transferableAfter has elapsed is
        // no longer a member of the locked subcurve. The scan must skip it.
        (uint256 shortId, uint256 shortEnd) = _mintLocked(alice, LOCK_AMOUNT, LOCK_SHORT);
        (, uint256 e2) = _mintLocked(bob, LOCK_AMOUNT, LOCK_2Y);

        // Warp past shortId's transferability window but before shortEnd lock end.
        // Actually for non-transferable mints, transferableAfter == unlockTime,
        // so we must warp past unlockTime. The position is then fully expired.
        vm.warp(shortEnd + 1);

        veHemi.markSeedingStarted();
        veHemi.seedBatch(type(uint256).max);
        veHemi.finalizeSeeding();

        uint256 expected = (LOCK_AMOUNT / MAX_TIME) * (e2 - block.timestamp);
        assertEq(
            veHemi.nonTransferableTotalVeHemiSupply(),
            expected,
            "expired transferableAfter must skip from subcurve"
        );
    }

    function test_seedBatch_accumulatesAcrossMultipleCalls() public {
        // Mint 5 positions, scan in 2-id chunks, verify final aggregate
        // matches a single-shot scan.
        uint256[5] memory amts;
        for (uint256 i; i < 5; ++i) {
            (, uint256 endI) = _mintLocked(_user(i), LOCK_AMOUNT, LOCK_2Y);
            amts[i] = endI - block.timestamp;
        }

        veHemi.markSeedingStarted();
        veHemi.seedBatch(2); // ids 1-2
        veHemi.seedBatch(2); // ids 3-4
        veHemi.seedBatch(2); // id 5 (clamps)
        veHemi.finalizeSeeding();

        uint256 expected;
        for (uint256 i; i < 5; ++i) {
            expected += (LOCK_AMOUNT / MAX_TIME) * amts[i];
        }
        assertEq(
            veHemi.nonTransferableTotalVeHemiSupply(),
            expected,
            "multi-batch aggregate must equal sum of contributions"
        );
    }

    function test_seedBatch_writesSlopeChangesAtSubEnd() public {
        (, uint256 e1) = _mintLocked(alice, LOCK_AMOUNT, LOCK_2Y);
        (, uint256 e2) = _mintLocked(bob, LOCK_AMOUNT, MAX_TIME);

        veHemi.markSeedingStarted();
        veHemi.seedBatch(type(uint256).max);
        veHemi.finalizeSeeding();

        int128 slope = int128(int256(LOCK_AMOUNT / MAX_TIME));
        // Slope changes at e1 should be -slope1 (alice).
        assertEq(veHemi.lockedSlopeChanges(e1), -slope, "slope change at alice's end");
        // Slope changes at e2 should be -slope2 (bob).
        if (e1 != e2) {
            assertEq(veHemi.lockedSlopeChanges(e2), -slope, "slope change at bob's end");
        }
    }

    /// @notice Two non-transferable positions with the SAME subEnd must
    ///         accumulate slope-changes in the same bucket (-slope1 - slope2),
    ///         not overwrite. SIX_DAYS-rounded lock.end with identical
    ///         (block.timestamp, duration) collapses to one slot.
    function test_seedBatch_accumulatesSharedSubEndSlot() public {
        (, uint256 e1) = _mintLocked(alice, LOCK_AMOUNT, LOCK_2Y);
        (, uint256 e2) = _mintLocked(bob, LOCK_AMOUNT, LOCK_2Y);
        assertEq(e1, e2, "shared-subEnd precondition: SIX_DAYS bucketing");

        veHemi.markSeedingStarted();
        veHemi.seedBatch(type(uint256).max);
        veHemi.finalizeSeeding();

        int128 slope = int128(int256(LOCK_AMOUNT / MAX_TIME));
        // Two positions, same subEnd → bucket holds -2*slope (accumulation).
        assertEq(
            veHemi.lockedSlopeChanges(e1),
            -slope * 2,
            "shared-subEnd slot must accumulate both deltas"
        );
    }

    function test_seedBatch_idempotentOnRepeatedCallsAfterCursorReached() public {
        _mintLocked(alice, LOCK_AMOUNT, LOCK_2Y);
        veHemi.markSeedingStarted();
        veHemi.seedBatch(type(uint256).max);

        // Pin the absolute cursor value: with one position minted before
        // `markSeedingStarted`, `seedingTargetId == nextTokenId == 2` and
        // the cursor advances to `seedingTargetId - 1 == 1`. `assertEq` to
        // the captured value alone would miss a regression that ALSO moved
        // the captured value (e.g., off-by-one in the cursor advance).
        uint256 cursorAfterFirst = _progressLastProcessedId();
        assertEq(cursorAfterFirst, 1, "cursor after first batch must equal seedingTargetId - 1 = 1");

        veHemi.seedBatch(100);
        veHemi.seedBatch(1);
        assertEq(_progressLastProcessedId(), cursorAfterFirst, "extra batches don't move cursor");
        assertEq(_progressLastProcessedId(), 1, "cursor remains at seedingTargetId - 1 after no-ops");
    }

    // ─────────────────────────────────────────────────────────────────────
    // seedBatch: boundary / edge cases
    // ─────────────────────────────────────────────────────────────────────

    /// @notice Calling `seedBatch(0)` with positions present must be a
    ///         pure no-op: cursor unchanged, count unchanged, no state
    ///         mutation. A regression that wrote `progress.lastProcessedId
    ///         = endIdExclusive - 1 = -1 (underflow)` or otherwise treated
    ///         `maxIterations=0` as "process one" would fail this pin.
    function test_seedBatch_zeroMaxIterationsIsNoOp() public {
        _mintLocked(alice, LOCK_AMOUNT, LOCK_2Y);
        veHemi.markSeedingStarted();

        uint256 cursorBefore = _progressLastProcessedId();
        uint256 countBefore = _progressCount();
        assertEq(cursorBefore, 0, "pre-call cursor is 0");
        assertEq(countBefore, 0, "pre-call count is 0");

        veHemi.seedBatch(0);

        assertEq(_progressLastProcessedId(), 0, "zero-maxIter must not advance cursor");
        assertEq(_progressCount(), 0, "zero-maxIter must not increment count");

        // Subsequent normal batches still work — the no-op did not poison state.
        veHemi.seedBatch(type(uint256).max);
        assertEq(_progressLastProcessedId(), 1, "follow-up batch advances cursor normally");
        assertEq(_progressCount(), 1, "follow-up batch counts the one eligible position");
    }

    /// @notice Boundary: a non-transferable position whose lock end is EXACTLY
    ///         `block.timestamp` at seeding time must be SKIPPED (treat as
    ///         expired). The skip predicate is `_lock.end <= block.timestamp`,
    ///         so the boundary is excluded by design — pin it so a future
    ///         refactor to strict `<` doesn't silently include zero-bias
    ///         entries.
    function test_seedBatch_positionWithLockEndAtSeedingStartedAtIsSkipped() public {
        // Mint a position whose lock end falls EXACTLY at the current block.
        // `createLockFor` rounds the unlock time DOWN to SIX_DAYS, so we
        // pick a duration whose rounded-down end is `block.timestamp`. The
        // simplest way: warp to the lock's original end before seeding so
        // `lock.end == block.timestamp`.
        (uint256 tokenId, uint256 lockEnd) = _mintLocked(alice, LOCK_AMOUNT, LOCK_SHORT);
        vm.warp(lockEnd); // now `block.timestamp == lock.end`

        veHemi.markSeedingStarted();
        veHemi.seedBatch(type(uint256).max);

        // The position was iterated but the skip predicate
        // `_lock.end <= block.timestamp` excluded it.
        assertEq(_progressCount(), 0, "lock.end == block.timestamp must be skipped (zero count)");
        // Cursor still advances past the ID range (seedingTargetId = nextTokenId = 2 → cursor = 1).
        assertEq(_progressLastProcessedId(), 1, "cursor still advances past skipped positions");
        // Suppress unused-variable warning.
        tokenId;
    }

    /// @notice Boundary: a non-transferable position with `_lock.end ==
    ///         seedingStartedAt + 1` (the smallest possible non-expired)
    ///         MUST be processed and contribute exactly `slope * 1`
    ///         to the bias at finalize time. Catches a regression where the
    ///         skip predicate becomes `<` instead of `<=` (would include
    ///         the boundary case incorrectly) or a one-off in the bias arithmetic.
    function test_seedBatch_positionWithLockEndOneSecondAheadIsProcessed() public {
        // Mint with a long-enough duration to clear the SIX_DAYS rounding,
        // then warp so `lock.end == block.timestamp + 1` at seeding time.
        (uint256 tokenId, uint256 lockEnd) = _mintLocked(alice, LOCK_AMOUNT, LOCK_2Y);
        vm.warp(lockEnd - 1); // now `lock.end == block.timestamp + 1`

        veHemi.markSeedingStarted();
        veHemi.seedBatch(type(uint256).max);
        veHemi.finalizeSeeding();

        // The position contributes `slope * (subEnd - now) = slope * 1` to
        // the locked subcurve's bias.
        uint256 slope = uint256(uint128(LOCK_AMOUNT)) / MAX_TIME;
        assertEq(
            veHemi.nonTransferableTotalVeHemiSupply(),
            slope * 1,
            "one-second-ahead position must contribute exactly slope*1"
        );
        tokenId;
    }

    /// @notice POSITIVE PIN against the slope-truncation boundary: the
    ///         minimum-lock-amount gate keeps user-mintable positions
    ///         above the `slope = amount / MAX_TIME == 0` zone. This test
    ///         enforces TWO complementary properties so a future relaxation
    ///         of the floor cannot silently introduce zero-slope positions
    ///         into the seeded subcurve:
    ///
    ///           (a) `createLockFor` reverts with `AmountTooSmall` when
    ///               `amount < MIN_LOCK_AMOUNT`. There is NO owner bypass —
    ///               the floor applies to every caller, including the test
    ///               contract.
    ///           (b) `MIN_LOCK_AMOUNT > MAX_TIME`. Integer division
    ///               `MIN_LOCK_AMOUNT / MAX_TIME` is therefore `>= 1`, so
    ///               every user-mintable position has a strictly positive
    ///               slope. Specifically: `10e18 / (4 * 365.25 days) ≈ 7.93e10`.
    ///
    ///         If either property regresses (e.g., MIN_LOCK_AMOUNT lowered
    ///         below MAX_TIME, or the `AmountTooSmall` revert is removed),
    ///         this test fires loudly. Catches the exact regression that the
    ///         prior `vm.skip(true)` documented but did not enforce.
    function test_seedBatch_minLockAmountGateForcesNonZeroSlope() public {
        // (a) The floor applies to every caller — including the test contract
        // (which is the owner). There is no owner bypass. Calling with
        // amount=1 must revert with AmountTooSmall.
        vm.expectRevert(VeHemi.AmountTooSmall.selector);
        veHemi.createLockFor(1, LOCK_2Y, alice, false, false);

        // (b) The constants enforce that any acceptable user mint produces a
        // strictly positive slope via integer truncation. `MIN_LOCK_AMOUNT`
        // is internal so we can't read it directly, but we can observe its
        // effect: the boundary value `MAX_TIME` itself must already revert
        // (any non-reverting value would mean slope >= 1, by integer division
        // semantics).
        vm.expectRevert(VeHemi.AmountTooSmall.selector);
        veHemi.createLockFor(MAX_TIME, LOCK_2Y, alice, false, false);

        // Sanity-check the corollary: an amount equal to MIN_LOCK_AMOUNT
        // (= 10 ether per the contract constant) produces a positive slope
        // by construction. Mint via the helper and verify the subcurve
        // contribution is non-zero after seeding.
        (uint256 tokenId, uint256 lockEnd) = _mintLocked(alice, 10 ether, LOCK_2Y);
        veHemi.markSeedingStarted();
        veHemi.seedBatch(type(uint256).max);
        veHemi.finalizeSeeding();
        assertGt(
            veHemi.nonTransferableTotalVeHemiSupply(),
            0,
            "MIN_LOCK_AMOUNT position must yield positive subcurve supply"
        );
        // Quench unused-var lints; both are observable downstream.
        tokenId;
        lockEnd;
    }

    /// @notice ID gap regression: cursor must advance past a BURNED middle
    ///         token (slot 2 between live slots 1 and 3). The existing
    ///         `test_seedBatch_skipsBurnedTokens` burns the FIRST id; this
    ///         test pins the harder middle-burn case.
    function test_seedBatch_idGapFromBurnedTokenInMiddle() public {
        (uint256 t1,) = _mintLocked(alice, LOCK_AMOUNT, LOCK_2Y);          // id 1
        (uint256 t2, uint256 t2End) = _mintLocked(bob, LOCK_AMOUNT, LOCK_SHORT);  // id 2
        (uint256 t3,) = _mintLocked(carol, LOCK_AMOUNT, LOCK_2Y);          // id 3

        // Burn id 2 by warping past its expiry and withdrawing.
        vm.warp(t2End + 1);
        vm.prank(bob);
        veHemi.withdraw(t2);

        veHemi.markSeedingStarted();
        veHemi.seedBatch(type(uint256).max);

        // Cursor advances to seedingTargetId - 1 == 3 (the last ID, regardless
        // of which IDs were burned). Count is 2 — alice's and carol's
        // positions remain; bob's was burned.
        assertEq(_progressLastProcessedId(), 3, "cursor advances past burned-middle ID");
        assertEq(_progressCount(), 2, "burned middle ID excluded; count == 2");
        // Defense against later use:
        t1; t3;
    }

    /// @notice Cursor monotonicity under arbitrary batch sizes (chunked
    ///         seedBatch). Verifies the cursor strictly increases (or
    ///         stays equal) across a sequence of small / large /
    ///         oversize-clamped calls. A regression that reset the cursor
    ///         mid-flow would silently re-process IDs, double-counting
    ///         their contributions to the accumulator.
    function test_seedBatch_cursorMonotonicAcrossArbitraryBatchSizes() public {
        // Mint 5 non-transferable positions.
        _mintLocked(alice, LOCK_AMOUNT, LOCK_2Y);
        _mintLocked(bob, LOCK_AMOUNT, LOCK_2Y);
        _mintLocked(carol, LOCK_AMOUNT, LOCK_2Y);
        _mintLocked(_user(0), LOCK_AMOUNT, LOCK_2Y);
        _mintLocked(_user(1), LOCK_AMOUNT, LOCK_2Y);

        veHemi.markSeedingStarted();

        // Sequence: 0, 1, 1, 3, 10, 100, type(uint256).max — pathological mix.
        uint256[] memory sizes = new uint256[](7);
        sizes[0] = 0;
        sizes[1] = 1;
        sizes[2] = 1;
        sizes[3] = 3;
        sizes[4] = 10;
        sizes[5] = 100;
        sizes[6] = type(uint256).max;

        uint256 prevCursor;
        for (uint256 i; i < sizes.length; ++i) {
            veHemi.seedBatch(sizes[i]);
            uint256 currCursor = _progressLastProcessedId();
            assertGe(
                currCursor,
                prevCursor,
                string.concat("cursor regressed at batch ", vm.toString(i))
            );
            prevCursor = currCursor;
        }

        // Final cursor reaches seedingTargetId - 1 = 5.
        assertEq(prevCursor, 5, "final cursor reaches seedingTargetId - 1");
    }

    // ─────────────────────────────────────────────────────────────────────
    // finalizeSeeding: completeness check, math correctness
    // ─────────────────────────────────────────────────────────────────────

    function test_finalizeSeeding_revertsIfNotStarted() public {
        vm.expectRevert(VeHemi.SeedingNotStarted.selector);
        veHemi.finalizeSeeding();
    }

    function test_finalizeSeeding_revertsIfIncomplete() public {
        _mintLocked(alice, LOCK_AMOUNT, LOCK_2Y);
        _mintLocked(bob, LOCK_AMOUNT, LOCK_2Y);
        _mintLocked(carol, LOCK_AMOUNT, LOCK_2Y); // tokenIds 1, 2, 3 — target == 4

        veHemi.markSeedingStarted();
        veHemi.seedBatch(2); // cursor at 2; target - 1 == 3 — incomplete

        // Expected payload: SeedingIncomplete(lastProcessedId=2, expectedEnd=3)
        vm.expectRevert(abi.encodeWithSelector(VeHemi.SeedingIncomplete.selector, 2, 3));
        veHemi.finalizeSeeding();
    }

    /// @notice Parametric error payload coverage at the LOWER boundary:
    ///         `markSeedingStarted` ran after mints exist, but NO
    ///         `seedBatch` call advanced the cursor at all. `lastProcessedId`
    ///         must be `0`, `expectedEnd` must be `seedingTargetId - 1`.
    ///         The companion test above only pins the `(2, 3)` payload;
    ///         this test pins `(0, n-1)` for `n > 1`.
    function test_finalizeSeeding_revertsIfIncomplete_atZeroCursor() public {
        _mintLocked(alice, LOCK_AMOUNT, LOCK_2Y);
        _mintLocked(bob, LOCK_AMOUNT, LOCK_2Y);
        _mintLocked(carol, LOCK_AMOUNT, LOCK_2Y); // 3 mints; nextTokenId = 4

        veHemi.markSeedingStarted();
        // No seedBatch call. Cursor remains at 0.

        // Expected payload: SeedingIncomplete(lastProcessedId=0, expectedEnd=3)
        vm.expectRevert(abi.encodeWithSelector(VeHemi.SeedingIncomplete.selector, 0, 3));
        veHemi.finalizeSeeding();
    }

    /// @notice Parametric error payload coverage at the NEAR-TAIL boundary:
    ///         all but the last position has been seeded. Pins
    ///         `(seedingTargetId - 2, seedingTargetId - 1)`. Catches a
    ///         regression that off-by-ones the cursor at the final position.
    function test_finalizeSeeding_revertsIfIncomplete_offByOneAtTail() public {
        _mintLocked(alice, LOCK_AMOUNT, LOCK_2Y);
        _mintLocked(bob, LOCK_AMOUNT, LOCK_2Y);
        _mintLocked(carol, LOCK_AMOUNT, LOCK_2Y);
        _mintLocked(_user(0), LOCK_AMOUNT, LOCK_2Y); // 4 mints; target = 5

        veHemi.markSeedingStarted();
        veHemi.seedBatch(3); // cursor advances to 3; target - 1 == 4

        vm.expectRevert(abi.encodeWithSelector(VeHemi.SeedingIncomplete.selector, 3, 4));
        veHemi.finalizeSeeding();
    }

    /// @notice INCOMPLETE-CURSOR REGRESSION: with the multi-block refactor,
    ///         cross-block `finalizeSeeding` is allowed when the cursor is
    ///         complete. If the cursor is INCOMPLETE, `SeedingIncomplete`
    ///         must fire — the "latch does not unlatch until max position"
    ///         property. Pins this so a future refactor that omits the
    ///         completeness check would be caught.
    function test_finalizeSeeding_incompleteCursor_revertsAcrossBlocks() public {
        _mintLocked(alice, LOCK_AMOUNT, LOCK_2Y);
        _mintLocked(bob, LOCK_AMOUNT, LOCK_2Y); // 2 mints; target == 3

        veHemi.markSeedingStarted(); // Cursor stays at 0 — incomplete.

        vm.warp(block.timestamp + 1); // Cross-block now allowed.

        // Cursor at 0, expected end at 2 — incomplete must surface.
        vm.expectRevert(abi.encodeWithSelector(VeHemi.SeedingIncomplete.selector, 0, 2));
        veHemi.finalizeSeeding();
    }

    function test_finalizeSeeding_revertsAfterFinalization() public {
        _mintLocked(alice, LOCK_AMOUNT, LOCK_2Y);
        veHemi.markSeedingStarted();
        veHemi.seedBatch(type(uint256).max);
        veHemi.finalizeSeeding();

        vm.expectRevert(VeHemi.SeedingAlreadyFinalized.selector);
        veHemi.finalizeSeeding();
    }

    /// @notice PERMISSIONLESS: `finalizeSeeding` may be called by any account
    ///         once the cursor reaches `seedingTargetId - 1`. The completeness
    ///         check (`SeedingIncomplete` revert) gates the latch flip, so a
    ///         non-owner caller cannot prematurely finalize an incomplete
    ///         seed. The resulting LockedPoint values are deterministic
    ///         functions of the accumulator and `block.timestamp` — identical
    ///         regardless of caller.
    function test_finalizeSeeding_permissionlessCaller_succeeds() public {
        _mintLocked(alice, LOCK_AMOUNT, LOCK_2Y);
        veHemi.markSeedingStarted();
        // Permissionless seedBatch advances the cursor to completion.
        vm.prank(attacker);
        veHemi.seedBatch(type(uint256).max);

        // Permissionless finalizeSeeding flips the latch.
        vm.prank(attacker);
        veHemi.finalizeSeeding();

        assertTrue(veHemi.lockedSeedingFinalized(), "permissionless caller finalized the latch");
    }

    /// @notice PERMISSIONLESS PRE-START: a call BEFORE `markSeedingStarted`
    ///         must revert with `SeedingNotStarted`, not an owner error.
    ///         Verifies the order of checks now that `onlyOwner` is gone.
    function test_finalizeSeeding_revertsForAnyCaller_beforeStart() public {
        vm.prank(attacker);
        vm.expectRevert(VeHemi.SeedingNotStarted.selector);
        veHemi.finalizeSeeding();
    }

    function test_finalizeSeeding_flipsLatchAndEmitsEvent() public {
        _mintLocked(alice, LOCK_AMOUNT, LOCK_2Y);
        veHemi.markSeedingStarted();
        veHemi.seedBatch(type(uint256).max);

        assertFalse(veHemi.lockedSeedingFinalized(), "latch is false pre-finalize");
        veHemi.checkpoint();
        uint256 expectedEpoch = veHemi.epoch();

        vm.expectEmit();
        emit LockedSeedingFinalized(expectedEpoch);
        veHemi.finalizeSeeding();

        assertTrue(veHemi.lockedSeedingFinalized(), "latch must flip");
    }

    function test_finalizeSeeding_clearsAccumulator() public {
        _mintLocked(alice, LOCK_AMOUNT, LOCK_2Y);
        veHemi.markSeedingStarted();
        veHemi.seedBatch(type(uint256).max);

        // Pre-finalize, accumulator reflects exactly one seeded position.
        assertEq(_progressCount(), 1, "accumulator count == 1 (one position seeded)");

        veHemi.finalizeSeeding();

        // Post-finalize, accumulator is `delete`d.
        assertEq(_progressLastProcessedId(), 0, "lastProcessedId cleared");
        assertEq(_progressCount(), 0, "count cleared");
    }

    function test_finalizeSeeding_handlesEmptyScanCleanly() public {
        // Edge case: markSeedingStarted with nextTokenId == 1 (no mints).
        // The flow must complete with zero contributions.
        assertEq(veHemi.nextTokenId(), 1, "fresh proxy has nextTokenId == 1");

        veHemi.markSeedingStarted();
        assertEq(veHemi.seedingTargetId(), 1, "target frozen at 1");
        veHemi.seedBatch(type(uint256).max);
        veHemi.finalizeSeeding();

        assertTrue(veHemi.lockedSeedingFinalized(), "latch flips even with empty scan");
        assertEq(veHemi.nonTransferableTotalVeHemiSupply(), 0, "empty scan => zero supply");
        assertEq(veHemi.forfeitableTotalVeHemiSupply(), 0, "empty scan => zero forfeitable supply");
    }

    function test_finalizeSeeding_writesLockedAndForfeitablePoints() public {
        // Mix of locked-only and forfeitable positions; verify both
        // subcurves end up with the correct totals.
        (, uint256 e1) = _mintLocked(alice, LOCK_AMOUNT, LOCK_2Y);
        (, uint256 e2) = _mintForfeitable(bob, LOCK_AMOUNT, LOCK_2Y);

        veHemi.markSeedingStarted();
        veHemi.seedBatch(type(uint256).max);
        veHemi.finalizeSeeding();

        uint256 slope = LOCK_AMOUNT / MAX_TIME;
        // Locked subcurve includes BOTH locked-only AND forfeitable positions.
        uint256 expectedLocked = slope * (e1 - block.timestamp) + slope * (e2 - block.timestamp);
        assertEq(veHemi.nonTransferableTotalVeHemiSupply(), expectedLocked, "locked supply == sum");

        // Forfeitable subcurve includes only the forfeitable position.
        uint256 expectedForfeitable = slope * (e2 - block.timestamp);
        assertEq(
            veHemi.forfeitableTotalVeHemiSupply(), expectedForfeitable, "forfeitable supply == bob only"
        );
    }

    // ─────────────────────────────────────────────────────────────────────
    // Mint guard: non-transferable mints blocked during active seeding
    // ─────────────────────────────────────────────────────────────────────

    function test_mintGuard_blocksNonTransferableDuringSeeding() public {
        _mintLocked(alice, LOCK_AMOUNT, LOCK_2Y);
        veHemi.markSeedingStarted();

        // Adversarial mint: try to insert a new non-transferable position
        // into the live nextTokenId slot. Must revert.
        vm.expectRevert(VeHemi.SeedingInProgress.selector);
        veHemi.createLockFor(LOCK_AMOUNT, LOCK_2Y, attacker, false, false);

        vm.expectRevert(VeHemi.SeedingInProgress.selector);
        veHemi.createLockFor(LOCK_AMOUNT, LOCK_2Y, attacker, false, true); // forfeitable variant

        vm.prank(attacker);
        hemi.approve(address(veHemi), type(uint256).max);
        vm.prank(attacker);
        vm.expectRevert(VeHemi.SeedingInProgress.selector);
        veHemi.createLockFor(LOCK_AMOUNT, LOCK_2Y, attacker, false, false);
    }

    function test_mintGuard_allowsTransferableDuringSeeding() public {
        veHemi.markSeedingStarted();
        // Transferable mints do NOT affect the locked subcurve being seeded;
        // they must not be blocked.
        vm.prank(attacker);
        uint256 tokenId = veHemi.createLock(LOCK_AMOUNT, LOCK_2Y);
        assertEq(veHemi.ownerOf(tokenId), attacker, "transferable mint must succeed");
    }

    function test_mintGuard_releasesAfterFinalization() public {
        veHemi.markSeedingStarted();
        veHemi.seedBatch(type(uint256).max);
        veHemi.finalizeSeeding();

        // Post-finalize, non-transferable mints are unblocked again.
        veHemi.createLockFor(LOCK_AMOUNT, LOCK_2Y, attacker, false, false);
        assertEq(veHemi.balanceOf(attacker), 1, "non-transferable mint allowed post-finalize");
    }

    // ─────────────────────────────────────────────────────────────────────
    // Mutation guards: increaseAmount / increaseUnlockTime / forfeit
    // also blocked on non-transferable positions during seeding to prevent
    // mid-flow accumulator drift.
    // ─────────────────────────────────────────────────────────────────────

    function test_mutationGuard_increaseAmountBlockedOnNonTransferableDuringSeeding() public {
        (uint256 tokenId,) = _mintLocked(alice, LOCK_AMOUNT, LOCK_2Y);
        veHemi.markSeedingStarted();

        // alice tries to top up her non-transferable position mid-seed.
        vm.startPrank(alice);
        hemi.approve(address(veHemi), TOPUP_AMOUNT);
        vm.expectRevert(VeHemi.SeedingInProgress.selector);
        veHemi.increaseAmount(tokenId, TOPUP_AMOUNT);
        vm.stopPrank();
    }

    function test_mutationGuard_increaseAmountAllowedOnTransferableDuringSeeding() public {
        // Transferable positions are NOT part of the locked subcurve and
        // can be safely topped up while seeding is in flight.
        (uint256 tokenId,) = _mintTransferable(alice, LOCK_AMOUNT, LOCK_2Y);
        veHemi.markSeedingStarted();

        vm.startPrank(alice);
        hemi.approve(address(veHemi), TOPUP_AMOUNT);
        veHemi.increaseAmount(tokenId, TOPUP_AMOUNT);
        vm.stopPrank();
        // Tight equality: the final amount must be EXACTLY initial + topup.
        // `assertGt` would pass even if the top-up only partially applied,
        // masking a regression that under-credits the increase.
        assertEq(
            veHemi.getLockedBalance(tokenId).amount,
            int128(int256(LOCK_AMOUNT + TOPUP_AMOUNT)),
            "top-up amount must equal LOCK_AMOUNT + TOPUP_AMOUNT exactly"
        );
    }

    function test_mutationGuard_increaseUnlockTimeBlockedOnNonTransferableDuringSeeding() public {
        (uint256 tokenId,) = _mintLocked(alice, LOCK_AMOUNT, LOCK_2Y);
        veHemi.markSeedingStarted();

        // alice tries to extend her non-transferable position mid-seed.
        vm.prank(alice);
        vm.expectRevert(VeHemi.SeedingInProgress.selector);
        veHemi.increaseUnlockTime(tokenId, LOCK_3Y);
    }

    function test_mutationGuard_increaseUnlockTimeAllowedOnTransferableDuringSeeding() public {
        (uint256 tokenId,) = _mintTransferable(alice, LOCK_AMOUNT, LOCK_2Y);
        veHemi.markSeedingStarted();

        vm.prank(alice);
        veHemi.increaseUnlockTime(tokenId, LOCK_3Y);
        // The new end snaps to the SIX_DAYS-aligned bucket at or after
        // `block.timestamp + LOCK_3Y`. Pin the exact rounded-down value:
        // `((block.timestamp + LOCK_3Y) / SIX_DAYS) * SIX_DAYS`. `assertGt`
        // against `now + LOCK_2Y` would pass even if the extension only
        // bumped by 1 second, masking an extension-math regression.
        uint256 expectedEnd = ((block.timestamp + LOCK_3Y) / SIX_DAYS) * SIX_DAYS;
        assertEq(
            veHemi.getLockedBalance(tokenId).end,
            uint64(expectedEnd),
            "extension must snap to SIX_DAYS-aligned bucket"
        );
    }

    function test_mutationGuard_forfeitBlockedDuringSeeding() public {
        // Mint a forfeitable position; configure forfeit admin.
        (uint256 tokenId,) = _mintForfeitable(alice, LOCK_AMOUNT, LOCK_2Y);
        veHemi.updateForfeitAdmin(owner);

        veHemi.markSeedingStarted();

        // Forfeit attempt mid-seed must revert.
        vm.expectRevert(VeHemi.SeedingInProgress.selector);
        veHemi.forfeit(tokenId);
    }

    function test_mutationGuard_allReleasedAfterFinalization() public {
        (uint256 lockedId,) = _mintLocked(alice, LOCK_AMOUNT, LOCK_2Y);
        (uint256 forfId,) = _mintForfeitable(bob, LOCK_AMOUNT, LOCK_2Y);
        veHemi.updateForfeitAdmin(owner);

        veHemi.markSeedingStarted();
        veHemi.seedBatch(type(uint256).max);
        veHemi.finalizeSeeding();

        // All three mutation guards must release once the latch flips.
        vm.startPrank(alice);
        hemi.approve(address(veHemi), TOPUP_AMOUNT);
        veHemi.increaseAmount(lockedId, TOPUP_AMOUNT);
        veHemi.increaseUnlockTime(lockedId, LOCK_3Y);
        vm.stopPrank();

        veHemi.forfeit(forfId);
    }

    function test_mintGuard_adversarialFrontRunDoesNotExtendSeedRange() public {
        // Set up state: existing non-transferable positions present.
        _mintLocked(alice, LOCK_AMOUNT, LOCK_2Y);
        _mintLocked(bob, LOCK_AMOUNT, LOCK_2Y);

        // Operator opens the seeding window.
        veHemi.markSeedingStarted();
        uint256 frozenTarget = veHemi.seedingTargetId();

        // Attacker tries to mint a non-transferable position into the gap.
        // This must revert per the mint guard.
        vm.expectRevert(VeHemi.SeedingInProgress.selector);
        veHemi.createLockFor(LOCK_AMOUNT, LOCK_2Y, attacker, false, false);

        // seedingTargetId did NOT move (the SSTORE in createLockFor reverted),
        // so the seed range stays bounded by the original snapshot.
        assertEq(veHemi.seedingTargetId(), frozenTarget, "target unchanged after blocked mint");

        // Operator scans and finalizes. The attacker's attempt left no
        // residue in the locked subcurve.
        veHemi.seedBatch(type(uint256).max);
        veHemi.finalizeSeeding();

        // Locked supply equals exactly alice + bob's contribution.
        uint256 slope = LOCK_AMOUNT / MAX_TIME;
        uint256 expected = slope * (veHemi.getLockedBalance(1).end - block.timestamp)
            + slope * (veHemi.getLockedBalance(2).end - block.timestamp);
        assertEq(veHemi.nonTransferableTotalVeHemiSupply(), expected, "attacker mint did not pollute");
    }

    // ─────────────────────────────────────────────────────────────────────
    // End-to-end equivalence: chunked vs single batch produces same totals
    // ─────────────────────────────────────────────────────────────────────

    function test_seedingFlow_chunkedAndSingleBatchAreEquivalent() public {
        // Path A: seed 10 positions in one big batch.
        _populateLockedPositions(10);

        uint256 snap = vm.snapshotState();

        veHemi.markSeedingStarted();
        veHemi.seedBatch(type(uint256).max);
        veHemi.finalizeSeeding();
        uint256 singleBatchLocked = veHemi.nonTransferableTotalVeHemiSupply();
        uint256 singleBatchForfeitable = veHemi.forfeitableTotalVeHemiSupply();

        vm.revertToState(snap);

        // Path B: same positions, seeded in 3-id chunks.
        veHemi.markSeedingStarted();
        veHemi.seedBatch(3);
        veHemi.seedBatch(3);
        veHemi.seedBatch(3);
        veHemi.seedBatch(type(uint256).max); // covers the tail
        veHemi.finalizeSeeding();

        assertEq(
            veHemi.nonTransferableTotalVeHemiSupply(),
            singleBatchLocked,
            "chunked result must match single batch for locked"
        );
        assertEq(
            veHemi.forfeitableTotalVeHemiSupply(),
            singleBatchForfeitable,
            "chunked result must match single batch for forfeitable"
        );
    }

    // ═════════════════════════════════════════════════════════════════════
    // MULTI-BLOCK PERMISSIONLESS SEEDING — regression coverage
    //
    // The single-block atomicity guard (`block.timestamp == seedingStartedAt`
    // in `_requireSeedingActive`) was removed because at Hemi mainnet scale
    // (~30K non-transferable positions) the catchup cannot fit in one block.
    // The seeded totals must remain identical to a single-block execution as
    // long as the immutability guards on non-transferable positions hold for
    // the whole window. These tests pin that property under realistic
    // multi-block flows.
    // ═════════════════════════════════════════════════════════════════════

    /// @notice Drive `seedBatch` across many blocks in small chunks. Compare
    ///         the seeded subcurve against an oracle single-block execution
    ///         at the SAME query timestamp (the oracle's post-finalize
    ///         supply walk decays bias to the query time; the chunked
    ///         materialization writes bias directly at the chunked finalize
    ///         time). Both must agree at the common query timestamp.
    function test_multiBlock_chunkedSeedingMatchesSingleBlockOracle() public {
        // 8 mixed positions: locked + forfeitable.
        for (uint256 i; i < 5; ++i) {
            _mintLocked(_user(i), LOCK_AMOUNT, LOCK_2Y);
        }
        for (uint256 i; i < 3; ++i) {
            _mintForfeitable(_user(100 + i), LOCK_AMOUNT, LOCK_2Y);
        }

        uint256 snap = vm.snapshotState();

        // Oracle: single-block, single-batch. Record the finalize timestamp
        // so the chunked path can match it for the assertion comparison.
        veHemi.markSeedingStarted();
        veHemi.seedBatch(type(uint256).max);
        veHemi.finalizeSeeding();
        // Pick a deterministic query time strictly after both flows would
        // have finished, well inside every seeded position's subEnd.
        uint256 queryTime = block.timestamp + 1 hours;
        uint256 oracleLocked = veHemi.nonTransferableTotalVeHemiSupplyAt(queryTime);
        uint256 oracleForfeitable = veHemi.forfeitableTotalVeHemiSupplyAt(queryTime);

        vm.revertToState(snap);

        // Multi-block: 2-id chunks, advancing the clock between each batch.
        veHemi.markSeedingStarted();
        for (uint256 step; step < 4; ++step) {
            vm.warp(block.timestamp + 12); // simulate Hemi block cadence
            vm.roll(block.number + 1);
            veHemi.seedBatch(2);
        }
        // Final block: complete and finalize across yet another block.
        vm.warp(block.timestamp + 12);
        vm.roll(block.number + 1);
        veHemi.seedBatch(type(uint256).max);
        vm.warp(block.timestamp + 12);
        vm.roll(block.number + 1);
        veHemi.finalizeSeeding();

        // Compare at the same query timestamp. The chunked finalize landed
        // at a later wall-clock than the oracle's finalize, but both
        // produce the same curve when evaluated at `queryTime` because
        // (slope, subEnd) are immutable for every scanned position.
        assertEq(
            veHemi.nonTransferableTotalVeHemiSupplyAt(queryTime),
            oracleLocked,
            "multi-block locked supply must match single-block oracle at common query time"
        );
        assertEq(
            veHemi.forfeitableTotalVeHemiSupplyAt(queryTime),
            oracleForfeitable,
            "multi-block forfeitable supply must match single-block oracle at common query time"
        );
    }

    /// @notice Permissionless: a rotating cast of non-owner callers drives
    ///         every step except `markSeedingStarted`. Latch must still flip
    ///         and the seeded totals must be correct.
    function test_multiBlock_permissionlessKeepersDriveSeed() public {
        _mintLocked(alice, LOCK_AMOUNT, LOCK_2Y);
        _mintLocked(bob, LOCK_AMOUNT, LOCK_2Y);
        _mintLocked(carol, LOCK_AMOUNT, LOCK_2Y);

        veHemi.markSeedingStarted();

        // Three different non-owner keepers drive seedBatch, each in its own
        // block.
        address k1 = makeAddr("keeper1");
        address k2 = makeAddr("keeper2");
        address k3 = makeAddr("keeper3");

        vm.warp(block.timestamp + 12);
        vm.roll(block.number + 1);
        vm.prank(k1);
        veHemi.seedBatch(1);

        vm.warp(block.timestamp + 12);
        vm.roll(block.number + 1);
        vm.prank(k2);
        veHemi.seedBatch(1);

        vm.warp(block.timestamp + 12);
        vm.roll(block.number + 1);
        vm.prank(k3);
        veHemi.seedBatch(type(uint256).max);

        // A fourth non-owner finalizes.
        address k4 = makeAddr("keeper4");
        vm.warp(block.timestamp + 12);
        vm.roll(block.number + 1);
        vm.prank(k4);
        veHemi.finalizeSeeding();

        assertTrue(veHemi.lockedSeedingFinalized(), "permissionless flow finalized the latch");
        uint256 slope = LOCK_AMOUNT / MAX_TIME;
        uint256 sumOfBiases =
            slope * (veHemi.getLockedBalance(1).end - block.timestamp)
            + slope * (veHemi.getLockedBalance(2).end - block.timestamp)
            + slope * (veHemi.getLockedBalance(3).end - block.timestamp);
        assertEq(
            veHemi.nonTransferableTotalVeHemiSupply(),
            sumOfBiases,
            "permissionless multi-block totals match per-position oracle"
        );
    }

    /// @notice The completeness latch: even with permissionless callers and
    ///         arbitrary cross-block timing, `finalizeSeeding` MUST revert
    ///         until the cursor reaches `seedingTargetId - 1`. This is the
    ///         "latch does not unlatch until max position is reached"
    ///         property — pinned across the worst caller / timing case.
    function test_multiBlock_latchHoldsUntilCursorReachesTarget() public {
        _mintLocked(alice, LOCK_AMOUNT, LOCK_2Y);
        _mintLocked(bob, LOCK_AMOUNT, LOCK_2Y);
        _mintLocked(carol, LOCK_AMOUNT, LOCK_2Y); // target == 4

        veHemi.markSeedingStarted();
        vm.warp(block.timestamp + 12);
        vm.roll(block.number + 1);
        vm.prank(attacker);
        veHemi.seedBatch(1); // cursor at 1; need 3.

        vm.warp(block.timestamp + 12);
        vm.roll(block.number + 1);
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(VeHemi.SeedingIncomplete.selector, 1, 3));
        veHemi.finalizeSeeding();

        // Advance one more, still incomplete.
        vm.prank(attacker);
        veHemi.seedBatch(1); // cursor at 2; need 3.
        vm.expectRevert(abi.encodeWithSelector(VeHemi.SeedingIncomplete.selector, 2, 3));
        vm.prank(attacker);
        veHemi.finalizeSeeding();

        // Complete the scan; now finalize succeeds.
        vm.prank(attacker);
        veHemi.seedBatch(1); // cursor at 3.
        vm.prank(attacker);
        veHemi.finalizeSeeding();
        assertTrue(veHemi.lockedSeedingFinalized(), "latch flips only after cursor reaches target");
    }

    /// @notice Adversary cannot lengthen the seed range mid-flow. The
    ///         single-block guard previously made this trivially true; with
    ///         multi-block seeding, the property must hold across the
    ///         extended window.
    function test_multiBlock_adversarialMintDuringWindow_blockedAndTargetFrozen() public {
        _mintLocked(alice, LOCK_AMOUNT, LOCK_2Y);
        _mintLocked(bob, LOCK_AMOUNT, LOCK_2Y);

        veHemi.markSeedingStarted();
        uint256 frozenTarget = veHemi.seedingTargetId();

        // Mid-window: advance the clock, attacker tries non-transferable mint.
        vm.warp(block.timestamp + 12);
        vm.roll(block.number + 1);
        vm.prank(attacker);
        vm.expectRevert(VeHemi.SeedingInProgress.selector);
        veHemi.createLockFor(LOCK_AMOUNT, LOCK_2Y, attacker, false, false);

        // Later in the window: attacker retries with the forfeitable flag.
        vm.warp(block.timestamp + 1 hours);
        vm.roll(block.number + 100);
        vm.expectRevert(VeHemi.SeedingInProgress.selector);
        veHemi.createLockFor(LOCK_AMOUNT, LOCK_2Y, attacker, false, true);

        // Range remains frozen at markSeedingStarted's snapshot.
        assertEq(veHemi.seedingTargetId(), frozenTarget, "target unchanged across multi-block window");
    }

    /// @notice Adversary cannot mutate a seeded position mid-flow (the
    ///         seedBatch math assumes (slope, subEnd) is immutable).
    function test_multiBlock_adversarialMutationDuringWindow_blocked() public {
        (uint256 nfId,) = _mintLocked(alice, LOCK_AMOUNT, LOCK_2Y);
        (uint256 forfId,) = _mintForfeitable(bob, LOCK_AMOUNT, LOCK_2Y);
        veHemi.updateForfeitAdmin(owner);

        veHemi.markSeedingStarted();
        vm.warp(block.timestamp + 12);
        vm.roll(block.number + 1);

        vm.startPrank(alice);
        hemi.approve(address(veHemi), TOPUP_AMOUNT);
        vm.expectRevert(VeHemi.SeedingInProgress.selector);
        veHemi.increaseAmount(nfId, TOPUP_AMOUNT);
        vm.expectRevert(VeHemi.SeedingInProgress.selector);
        veHemi.increaseUnlockTime(nfId, LOCK_3Y);
        vm.stopPrank();

        vm.warp(block.timestamp + 1 days);
        vm.roll(block.number + 1000);
        vm.expectRevert(VeHemi.SeedingInProgress.selector);
        veHemi.forfeit(forfId);
    }

    /// @notice Production-realistic timing: in real Hemi mainnet seeding,
    ///         the entire multi-block window (markSeedingStarted →
    ///         finalizeSeeding) completes in minutes-to-hours, far shorter
    ///         than MIN_LOCK_DURATION (~12 days). Therefore no seeded
    ///         position's `subEnd` falls inside the window. This test
    ///         simulates a realistic 2-hour seeding window across many
    ///         blocks and asserts the seeded totals match a single-block
    ///         oracle when evaluated at a common future query time.
    function test_multiBlock_realisticSeedingWindow_totalsConsistent() public {
        // 10 non-transferable positions, all 2-year locks (the realistic
        // bottom of the lock-duration distribution for governance use).
        for (uint256 i; i < 10; ++i) {
            _mintLocked(_user(i), LOCK_AMOUNT, LOCK_2Y);
        }

        uint256 snap = vm.snapshotState();

        // Oracle: single-block flow.
        veHemi.markSeedingStarted();
        veHemi.seedBatch(type(uint256).max);
        veHemi.finalizeSeeding();
        // Query time well inside every position's subEnd, beyond any
        // realistic seeding window.
        uint256 queryTime = block.timestamp + 30 days;
        uint256 oracle = veHemi.nonTransferableTotalVeHemiSupplyAt(queryTime);

        vm.revertToState(snap);

        // Multi-block: 1-id chunks across 10 blocks (simulates worst-case
        // many-small-batches operator behavior), warping a realistic
        // amount of wall-clock between batches.
        veHemi.markSeedingStarted();
        for (uint256 step; step < 10; ++step) {
            vm.warp(block.timestamp + 12 minutes);
            vm.roll(block.number + 100);
            veHemi.seedBatch(1);
        }
        vm.warp(block.timestamp + 12 minutes);
        vm.roll(block.number + 100);
        veHemi.finalizeSeeding();

        // Total elapsed: ~2 hours, still many days inside any subEnd.
        assertEq(
            veHemi.nonTransferableTotalVeHemiSupplyAt(queryTime),
            oracle,
            "realistic 2hr multi-block window matches single-block oracle"
        );
    }

    /// @notice MULTI-BLOCK: a non-transferable position whose `subEnd` falls
    ///         INSIDE the seeding window — i.e., the position is non-expired
    ///         at `markSeedingStarted` (so `seedBatch` records its
    ///         (slope, subEnd) and writes the slope-change at `subEnd`) but
    ///         expires before `finalizeSeeding`, and the owner withdraws
    ///         (burning the NFT) mid-window — must not corrupt the totals
    ///         materialized at finalize.
    ///
    ///         Pre-fix, the contract carried the lapsed position's slope
    ///         forward because `lockedSlopeChanges[subEnd]` (eagerly written
    ///         by `seedBatch`) lived at a past bucket the forward supply
    ///         walk would never revisit. This caused
    ///         `nonTransferableTotalVeHemiSupply` to under-count for as
    ///         long as the carried bias took to clamp to zero.
    ///
    ///         POST-FIX (`minSubEnd` accumulator + walk-back in
    ///         `finalizeSeeding`): the LockedPoint is materialized by
    ///         walking from `minSubEnd` forward to `tsFinal`, consuming the
    ///         otherwise-stranded slope-changes. The resulting subcurve
    ///         state at `tsFinal` reflects ONLY the positions still inside
    ///         their non-transferable window — the lapsed short position
    ///         contributes nothing, exactly as a truthful per-position
    ///         walk would produce.
    function test_multiBlock_withdrawOfExpiredPositionMidWindow_doesNotCorruptTotals() public {
        // Long-lived position survives the carry-fix walk.
        (, uint256 longEnd) = _mintLocked(alice, LOCK_AMOUNT, LOCK_2Y);
        // Short-lived position: 2*SIX_DAYS is the minimum lock duration. Its
        // SIX_DAYS-rounded `lock.end` is roughly 12 days out.
        (uint256 shortId, uint256 shortEnd) = _mintLocked(bob, LOCK_AMOUNT, LOCK_SHORT);

        // Warp so the short position is STILL non-expired at markSeedingStarted
        // (subEnd > block.timestamp) but only by a small margin — well inside
        // a realistic multi-block seeding window.
        vm.warp(shortEnd - 5 minutes);
        assertGt(shortEnd, block.timestamp, "short position must be non-expired at mark time");

        veHemi.markSeedingStarted();
        veHemi.seedBatch(type(uint256).max);
        // The short position WAS recorded (lock.end > block.timestamp at scan
        // time): accumulator count == 2.
        assertEq(_progressCount(), 2, "both positions recorded by seedBatch");
        // Earliest seeded subEnd recorded for the walk-back trigger.
        assertEq(uint256(_progressMinSubEnd()), shortEnd, "minSubEnd captured short subEnd");

        // Warp PAST the short position's subEnd. Now the owner can withdraw,
        // which burns the NFT. The seedBatch-written accumulator and slope
        // change at `shortEnd` are intentionally untouched (no withdraw-side
        // accumulator mutation exists during seeding) — the walk-back at
        // finalize is what consumes them.
        vm.warp(shortEnd + 1 hours);
        vm.prank(bob);
        veHemi.withdraw(shortId);
        assertEq(veHemi.balanceOf(bob), 0, "withdraw burned the short position");

        // Finalize at tsFinal > shortEnd. The walk-back from minSubEnd
        // consumes `lockedSlopeChanges[shortEnd]` before writing the
        // LockedPoint, so the materialized state has only the long
        // position's slope active.
        veHemi.finalizeSeeding();

        uint256 slope = LOCK_AMOUNT / MAX_TIME;
        uint256 expectedAtFinal = slope * (longEnd - block.timestamp);
        assertEq(
            veHemi.nonTransferableTotalVeHemiSupply(),
            expectedAtFinal,
            "walk-back: finalized supply reflects only the surviving long position"
        );

        // 30 days later, only the long position is still decaying; the
        // short position's slope was consumed at finalize, so the supply
        // walk forward from tsFinal applies only the long's slope of 1
        // (not the pre-fix carried 2). longEnd is 2y out, so no slope
        // change fires within 30 days.
        uint256 queryTs = block.timestamp + 30 days;
        uint256 expectedAtQuery = slope * (longEnd - queryTs);
        assertEq(
            veHemi.nonTransferableTotalVeHemiSupplyAt(queryTs),
            expectedAtQuery,
            "walk-back: forward query agrees with truthful single-slope decay"
        );
    }

    /// @notice A transferable mint inside the multi-block window is allowed
    ///         (subcurve membership is non-transferable-only) and does NOT
    ///         shift `seedingTargetId` (frozen at markSeedingStarted).
    function test_multiBlock_transferableMintDuringWindow_allowedAndIgnoredByScan() public {
        _mintLocked(alice, LOCK_AMOUNT, LOCK_2Y);
        veHemi.markSeedingStarted();
        uint256 frozenTarget = veHemi.seedingTargetId();

        // Mid-window transferable mint: allowed, and the position lands
        // OUTSIDE the seed range (id >= frozenTarget).
        vm.warp(block.timestamp + 1 hours);
        vm.roll(block.number + 1);
        (uint256 tid,) = _mintTransferable(carol, LOCK_AMOUNT, LOCK_2Y);
        assertGe(tid, frozenTarget, "transferable mint lands outside the frozen seed range");

        // Complete and finalize. The transferable position contributes
        // nothing to the locked subcurve.
        veHemi.seedBatch(type(uint256).max);
        veHemi.finalizeSeeding();

        uint256 slope = LOCK_AMOUNT / MAX_TIME;
        uint256 expected = slope * (veHemi.getLockedBalance(1).end - block.timestamp);
        assertEq(
            veHemi.nonTransferableTotalVeHemiSupply(),
            expected,
            "transferable mid-window mint must not affect locked subcurve"
        );
    }

    // ─────────────────────────────────────────────────────────────────────
    // Phantom-carry mitigation: minSubEnd accumulator + walk-back in finalize
    //
    // The carry fires when a seeded position's subEnd falls between
    // markSeedingStarted and finalizeSeeding. The fix tracks the earliest
    // included subEnd in `_seedingProgress.minSubEnd` and walks the subcurve
    // from minSubEnd forward to tsFinal in finalize, consuming the otherwise-
    // stranded slope-change entries before writing the LockedPoint.
    // ─────────────────────────────────────────────────────────────────────

    /// @notice Happy-path regression — when no seeded position's subEnd
    ///         lapses during the window, the walk-back must produce the
    ///         same LockedPoint as the direct formula. Confirms zero
    ///         behavioral drift for well-run seedings.
    function test_carry_happyPath_noWalkRequired() public {
        // All positions are 2-year locks; no subEnd is close to now.
        (, uint256 endA) = _mintLocked(alice, LOCK_AMOUNT, LOCK_2Y);
        (, uint256 endB) = _mintLocked(bob, LOCK_AMOUNT, LOCK_2Y);
        (, uint256 endC) = _mintLocked(carol, LOCK_AMOUNT, LOCK_2Y);

        veHemi.markSeedingStarted();
        veHemi.seedBatch(type(uint256).max);
        veHemi.finalizeSeeding();

        // minSubEnd is now cleared (delete _seedingProgress). Pre-clear it
        // would equal min(endA, endB, endC). Verify the supply matches the
        // truthful per-position sum.
        uint256 slope = LOCK_AMOUNT / MAX_TIME;
        uint256 expected =
              slope * (endA - block.timestamp)
            + slope * (endB - block.timestamp)
            + slope * (endC - block.timestamp);
        assertEq(
            veHemi.nonTransferableTotalVeHemiSupply(),
            expected,
            "happy path: walk-back must not perturb correct totals"
        );
    }

    /// @notice The original phantom-carry trigger: a single seeded position
    ///         whose subEnd lapses BETWEEN seedBatch and finalize. Without
    ///         the fix, the lapsed position's slope is "carried" past its
    ///         true subEnd and bias decays at the wrong rate. With the fix,
    ///         the walk-back consumes the slope-change at the lapsed subEnd
    ///         before writing the LockedPoint.
    function test_carry_singlePositionLapses_walkBackRestoresTruth() public {
        // Long-lived position. Its full bias must survive.
        (, uint256 longEnd) = _mintLocked(alice, LOCK_AMOUNT, LOCK_2Y);
        // Short-lived position: subEnd ~12 days out (the MIN_LOCK_DURATION
        // floor). We'll warp past its subEnd before finalizing.
        (, uint256 shortEnd) = _mintLocked(bob, LOCK_AMOUNT, LOCK_SHORT);

        // Warp to just before short subEnd so the position is still live
        // at markSeedingStarted time and gets included in the accumulator.
        vm.warp(shortEnd - 1 hours);
        assertGt(shortEnd, block.timestamp, "short must be non-expired at mark time");

        veHemi.markSeedingStarted();
        veHemi.seedBatch(type(uint256).max);

        // Warp PAST the short position's subEnd. Phantom-carry trigger.
        vm.warp(shortEnd + 2 hours);
        veHemi.finalizeSeeding();

        // Truth at tsFinal: only the long position contributes.
        uint256 slope = LOCK_AMOUNT / MAX_TIME;
        uint256 expected = slope * (longEnd - block.timestamp);
        assertEq(
            veHemi.nonTransferableTotalVeHemiSupply(),
            expected,
            "walk-back must produce truthful supply when one subEnd lapses"
        );
    }

    /// @notice Multiple positions with staggered subEnds inside the window.
    ///         The walk-back must consume EACH lapsed slope-change as it
    ///         strides forward in SIX_DAYS buckets.
    function test_carry_multipleStaggeredLapses_walkBackConsumesAll() public {
        // One long position survives finalize.
        (, uint256 longEnd) = _mintLocked(alice, LOCK_AMOUNT, LOCK_2Y);
        // Three short positions, all with similar subEnd (MIN_LOCK_DURATION
        // rounds them to the same SIX_DAYS bucket since they're created in
        // the same block).
        (, uint256 shortEnd) = _mintLocked(bob, LOCK_AMOUNT, LOCK_SHORT);
        _mintLocked(carol, LOCK_AMOUNT, LOCK_SHORT);
        _mintLocked(attacker, LOCK_AMOUNT, LOCK_SHORT);

        vm.warp(shortEnd - 1 hours);
        veHemi.markSeedingStarted();
        veHemi.seedBatch(type(uint256).max);
        assertEq(_progressCount(), 4, "all four positions included");

        vm.warp(shortEnd + 2 hours);
        veHemi.finalizeSeeding();

        uint256 slope = LOCK_AMOUNT / MAX_TIME;
        uint256 expected = slope * (longEnd - block.timestamp);
        assertEq(
            veHemi.nonTransferableTotalVeHemiSupply(),
            expected,
            "walk-back must consume all stranded slope-changes"
        );
    }

    /// @notice Edge: every seeded position's subEnd lapses inside the
    ///         window. The subcurve must be exactly zero post-finalize
    ///         (no carry, no negative residue).
    function test_carry_allPositionsLapse_subcurveIsZero() public {
        (, uint256 endA) = _mintLocked(alice, LOCK_AMOUNT, LOCK_SHORT);
        _mintLocked(bob, LOCK_AMOUNT, LOCK_SHORT);
        _mintLocked(carol, LOCK_AMOUNT, LOCK_SHORT);

        vm.warp(endA - 1 hours);
        veHemi.markSeedingStarted();
        veHemi.seedBatch(type(uint256).max);

        vm.warp(endA + 1 hours);
        veHemi.finalizeSeeding();

        assertEq(
            veHemi.nonTransferableTotalVeHemiSupply(),
            0,
            "all-lapsed: subcurve must clamp to 0 cleanly"
        );
    }

    /// @notice Forfeitable subcurve must walk back independently of locked.
    ///         A forfeitable position that lapses during the window must
    ///         also be correctly removed from the forfeitable subcurve.
    function test_carry_forfeitablePositionLapses_walkBackOnBothCurves() public {
        (, uint256 longEnd) = _mintLocked(alice, LOCK_AMOUNT, LOCK_2Y);
        (, uint256 shortEnd) = _mintForfeitable(bob, LOCK_AMOUNT, LOCK_SHORT);

        vm.warp(shortEnd - 1 hours);
        veHemi.markSeedingStarted();
        veHemi.seedBatch(type(uint256).max);

        vm.warp(shortEnd + 2 hours);
        veHemi.finalizeSeeding();

        // Locked: only the long survives.
        uint256 slope = LOCK_AMOUNT / MAX_TIME;
        uint256 expectedLocked = slope * (longEnd - block.timestamp);
        assertEq(
            veHemi.nonTransferableTotalVeHemiSupply(),
            expectedLocked,
            "walk-back: locked subcurve correct after forfeitable lapse"
        );
        // Forfeitable: zero (the only forfeitable position lapsed).
        assertEq(
            veHemi.forfeitableTotalVeHemiSupply(),
            0,
            "walk-back: forfeitable subcurve correct after lapse"
        );
    }

    /// @notice The skip predicate at seedBatch line 1280-1287 must filter
    ///         out positions whose subEnd is ALREADY in the past at scan
    ///         time. Such positions never enter the accumulator AND never
    ///         influence minSubEnd. Verify by mixing one already-lapsed
    ///         position (filtered) with one in-window position (tracked).
    function test_carry_minSubEnd_ignoresFilteredPositions() public {
        // Position A: subEnd will be in the past at seedBatch time.
        (, uint256 lapsedEnd) = _mintLocked(alice, LOCK_AMOUNT, LOCK_SHORT);
        // Position B: subEnd well in the future.
        (, uint256 farEnd) = _mintLocked(bob, LOCK_AMOUNT, LOCK_2Y);

        // Warp past A's subEnd. A is now filtered by seedBatch's skip
        // (transferableAfter <= block.timestamp).
        vm.warp(lapsedEnd + 1 hours);

        veHemi.markSeedingStarted();
        veHemi.seedBatch(type(uint256).max);

        // minSubEnd should equal farEnd (B), not lapsedEnd (A).
        uint64 minSubEnd = _progressMinSubEnd();
        assertEq(uint256(minSubEnd), farEnd, "minSubEnd must reflect INCLUDED set only");
        assertEq(_progressCount(), 1, "only B was included");
    }

    /// @notice minSubEnd must converge to the global minimum across many
    ///         seedBatch calls. Each batch flushes its local min via
    ///         compare-and-swap into the persistent accumulator.
    function test_carry_minSubEnd_convergesAcrossMultipleBatches() public {
        // Five positions, varying subEnds. The minimum subEnd is in the
        // middle of the id range, so a single batch covering the range
        // and multiple smaller batches must produce the same final min.
        (, uint256 e1) = _mintLocked(_user(1), LOCK_AMOUNT, LOCK_2Y);
        (, uint256 e2) = _mintLocked(_user(2), LOCK_AMOUNT, LOCK_3Y); // larger subEnd
        (, uint256 e3) = _mintLocked(_user(3), LOCK_AMOUNT, LOCK_SHORT); // smallest subEnd
        (, uint256 e4) = _mintLocked(_user(4), LOCK_AMOUNT, LOCK_3Y);
        (, uint256 e5) = _mintLocked(_user(5), LOCK_AMOUNT, LOCK_2Y);

        // Expected global min.
        uint256 expectedMin = e3;
        // Sanity: other ends are larger.
        assertGt(e1, expectedMin, "sanity");
        assertGt(e2, expectedMin, "sanity");
        assertGt(e4, expectedMin, "sanity");
        assertGt(e5, expectedMin, "sanity");

        veHemi.markSeedingStarted();

        // Three batches of varying size, with block boundaries between.
        vm.warp(block.timestamp + 12);
        vm.roll(block.number + 1);
        veHemi.seedBatch(2); // ids 1-2: min so far = min(e1, e2) = e1
        assertEq(uint256(_progressMinSubEnd()), e1, "batch1: min = e1");

        vm.warp(block.timestamp + 12);
        vm.roll(block.number + 1);
        veHemi.seedBatch(2); // ids 3-4: includes e3 (smallest); new min = e3
        assertEq(uint256(_progressMinSubEnd()), expectedMin, "batch2: min drops to e3");

        vm.warp(block.timestamp + 12);
        vm.roll(block.number + 1);
        veHemi.seedBatch(2); // id 5: e5 > e3, no change
        assertEq(uint256(_progressMinSubEnd()), expectedMin, "batch3: min unchanged");
    }

    /// @notice An empty seedBatch (all positions filtered, or zero
    ///         iterations) MUST NOT corrupt the persistent minSubEnd.
    function test_carry_minSubEnd_emptyBatchPreservesPersistentMin() public {
        _mintLocked(alice, LOCK_AMOUNT, LOCK_2Y);

        veHemi.markSeedingStarted();
        // First batch includes the position.
        veHemi.seedBatch(1);
        uint64 minAfterFirst = _progressMinSubEnd();
        assertGt(uint256(minAfterFirst), 0, "first batch sets min");

        // Second batch is a no-op (cursor at target).
        veHemi.seedBatch(type(uint256).max);
        assertEq(_progressMinSubEnd(), minAfterFirst, "empty batch must not touch min");

        // Zero-maxIterations batch: also a no-op.
        veHemi.seedBatch(0);
        assertEq(_progressMinSubEnd(), minAfterFirst, "zero-iter batch must not touch min");
    }

    /// @notice Cross-check: after finalize, querying the supply via
    ///         `nonTransferableTotalVeHemiSupplyAt(tsFinal)` must produce
    ///         the same value as the freshly-materialized LockedPoint.
    ///         Pins the walk-back's self-consistency between finalize and
    ///         subsequent reads.
    function test_carry_finalizeOutputMatchesSubsequentQuery() public {
        _mintLocked(alice, LOCK_AMOUNT, LOCK_2Y);
        (, uint256 shortEnd) = _mintLocked(bob, LOCK_AMOUNT, LOCK_SHORT);

        vm.warp(shortEnd - 30 minutes);
        veHemi.markSeedingStarted();
        veHemi.seedBatch(type(uint256).max);

        vm.warp(shortEnd + 30 minutes);
        veHemi.finalizeSeeding();
        uint256 tsFinal = block.timestamp;

        uint256 atFinalizeTs = veHemi.nonTransferableTotalVeHemiSupplyAt(tsFinal);
        uint256 atNow = veHemi.nonTransferableTotalVeHemiSupply();
        assertEq(atFinalizeTs, atNow, "current supply must match supply-at-tsFinal query");
    }

    // ─────────────────────────────────────────────────────────────────────
    // Helpers
    // ─────────────────────────────────────────────────────────────────────

    function _mintLocked(address account, uint256 amount, uint256 duration)
        internal
        returns (uint256 tokenId, uint256 lockEnd)
    {
        tokenId = veHemi.createLockFor(amount, duration, account, false, false);
        lockEnd = veHemi.getLockedBalance(tokenId).end;
    }

    function _mintForfeitable(address account, uint256 amount, uint256 duration)
        internal
        returns (uint256 tokenId, uint256 lockEnd)
    {
        tokenId = veHemi.createLockFor(amount, duration, account, false, true);
        lockEnd = veHemi.getLockedBalance(tokenId).end;
    }

    function _mintTransferable(address account, uint256 amount, uint256 duration)
        internal
        returns (uint256 tokenId, uint256 lockEnd)
    {
        vm.prank(account);
        tokenId = veHemi.createLock(amount, duration);
        lockEnd = veHemi.getLockedBalance(tokenId).end;
    }

    function _populateLockedPositions(uint256 n) internal {
        for (uint256 i; i < n; ++i) {
            _mintLocked(_user(i), LOCK_AMOUNT, LOCK_2Y);
        }
    }

    function _user(uint256 i) internal pure returns (address) {
        return address(uint160(uint256(keccak256(abi.encode("seed-user", i)))));
    }

    // ─── Direct storage probes into _seedingProgress ────────────────────
    // The struct lives at VeHemi storage slot 23 (5 packed slots: 23-27).
    // Layout:
    //   slot 23: lastProcessedId (uint256)
    //   slot 24: totalSlope (int128, low) | totalBias (int128, high)
    //   slot 25: totalForfeitableSlope (int128, low) | totalForfeitableBias (int128, high)
    //   slot 26: count (uint256)
    //   slot 27: minSubEnd (uint64, low; upper 24 bytes reserved)

    function _progressLastProcessedId() internal view returns (uint256) {
        return uint256(vm.load(address(veHemi), bytes32(SLOT_SEEDING_PROGRESS_BASE)));
    }

    function _progressCount() internal view returns (uint256) {
        return uint256(vm.load(address(veHemi), bytes32(SLOT_SEEDING_PROGRESS_COUNT)));
    }

    function _progressMinSubEnd() internal view returns (uint64) {
        return uint64(uint256(vm.load(address(veHemi), bytes32(SLOT_SEEDING_PROGRESS_MIN_SUBEND))));
    }
}
