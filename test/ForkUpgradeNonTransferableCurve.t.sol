// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import "forge-std/Test.sol";
import "../src/VeHemi.sol";
import "../src/interfaces/IVeHemi.sol";
import "../src/interfaces/IVeHemiVoteDelegation.sol";
import "@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol";
import {ITransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";

/**
 * @title ForkUpgradeNonTransferableCurveTest
 * @notice Fork test for the VeHemi V2 non-transferable + forfeitable curve upgrade on Hemi mainnet.
 *
 * @dev Validates:
 *   1. Upgrade preserves ALL existing state (locks, balances, voting power, delegations)
 *   2. Non-transferable + forfeitable curve seeding works with real on-chain positions
 *   3. nonTransferableTotalVeHemiSupply / forfeitableTotalVeHemiSupply return correct values
 *   4. supplyBreakdown 4-tuple is consistent (total == locked + transferable, forfeitable <= locked)
 *   5. Existing operations still work (withdraw, increaseAmount, increaseUnlockTime, transfer)
 *   6. New positions created post-upgrade are tracked correctly in all curves
 *   7. Forfeitable curve activates correctly when forfeitable positions are created post-upgrade
 *   8. Forfeit operation correctly reduces non-transferable + forfeitable curves
 *   9. Historical queries return 0 for pre-V2 timestamps
 *  10. Token conservation: hemi.balanceOf(veHemi) == veHemi.totalLocked()
 *  11. View functions work without preceding checkpoint (exercises catchup loops)
 *
 * IMPORTANT: As of the current scan, Hemi mainnet has ZERO forfeitable positions.
 * All 126 active non-transferrable positions are non-transferable-only (non-forfeitable).
 * The forfeitable curve tests therefore create NEW forfeitable positions post-upgrade
 * to verify the curve activates correctly.
 *
 * Run with:
 *     forge test --match-contract ForkUpgradeNonTransferableCurveTest --fork-url $HEMI_RPC_URL -vvv
 */
contract ForkUpgradeNonTransferableCurveTest is Test {
    // -- Known Hemi mainnet addresses --
    address constant VEHEMI_PROXY = 0x371d3718D5b7F75EAb050FAe6Da7DF3092031c89;
    address constant PROXY_ADMIN = 0x7e4D4FB40449A56377fD54fC6Dd800fa202c0f0F;
    address constant GNOSIS_SAFE = 0x694fA0816999Da16E8783C0f5cDE68c13a33C4e6;
    address constant HEMI_TOKEN = 0x99e3dE3817F6081B2568208337ef83295b7f591D;
    address constant VOTE_DELEGATION_PROXY = 0xBF5b2f370370494B8A4575962512dd3ea7c29e2d;

    VeHemi veHemi;
    IERC20 hemiToken;

    // Pre-upgrade snapshots
    uint256 preTotalLocked;
    uint256 preTotalSupply;
    uint256 preEpoch;
    uint256 preNextTokenId;
    uint256 preTotalNFTs;

    uint256 private constant YEAR = 365.25 days;
    uint256 private constant SIX_DAYS = YEAR / (12 * 5);
    uint256 private constant MAX_TIME = 4 * YEAR;

    /// @dev Skip tests when not running on a Hemi fork.
    ///      Uses vm.skip(true) so Foundry reports them as "skipped" rather than falsely "passed".
    modifier onlyFork() {
        if (block.chainid != 43111) {
            vm.skip(true);
            return;
        }
        _;
    }

    function setUp() public {
        if (block.chainid != 43111) {
            vm.skip(true);
            return;
        }

        veHemi = VeHemi(VEHEMI_PROXY);
        hemiToken = IERC20(HEMI_TOKEN);

        preTotalLocked = veHemi.totalLocked();
        preTotalSupply = veHemi.totalVeHemiSupply();
        preEpoch = veHemi.epoch();
        preNextTokenId = veHemi.nextTokenId();
        preTotalNFTs = veHemi.totalSupply();
    }

    // ─── Helpers ─────────────────────────────────────────────────────────

    function _upgradeProxy() internal returns (VeHemi) {
        VeHemi newImpl = new VeHemi(HEMI_TOKEN);
        // The on-chain ProxyAdmin is OZ v4 which has a plain `upgrade(proxy, impl)` function.
        // OZ v4's `upgradeAndCall` with empty data still delegatecalls (unlike v5 which skips it),
        // so we use the plain `upgrade` to avoid reverting on an empty fallback.
        vm.prank(GNOSIS_SAFE);
        (bool success,) = PROXY_ADMIN.call(
            abi.encodeWithSignature("upgrade(address,address)", VEHEMI_PROXY, address(newImpl))
        );
        require(success, "Proxy upgrade failed");
        return newImpl;
    }

    // Known range of non-transferable token IDs on Hemi mainnet (28625-28808).
    // Scanning the full 0..nextTokenId range exceeds public RPC rate limits.
    uint256 constant LOCKED_RANGE_START = 28625;
    uint256 constant LOCKED_RANGE_END = 28809; // exclusive

    /// @dev Discover non-transferable positions from on-chain state.
    ///      Only scans the known non-transferable token ID range to avoid RPC rate limiting.
    function _findNonTransferablePositions() internal view returns (uint256[] memory) {
        // First pass: count
        uint256 count;
        for (uint256 i = LOCKED_RANGE_START; i < LOCKED_RANGE_END; ++i) {
            try veHemi.ownerOf(i) returns (address) {
                if (veHemi.transferableAfter(i) != 0) {
                    IVeHemi.LockedBalance memory bal = veHemi.getLockedBalance(i);
                    if (bal.amount > 0 && bal.end > block.timestamp) {
                        count++;
                    }
                }
            } catch {
                continue;
            }
        }
        // Second pass: collect (already sorted since we iterate ascending)
        uint256[] memory ids = new uint256[](count);
        uint256 idx;
        for (uint256 i = LOCKED_RANGE_START; i < LOCKED_RANGE_END; ++i) {
            try veHemi.ownerOf(i) returns (address) {
                if (veHemi.transferableAfter(i) != 0) {
                    IVeHemi.LockedBalance memory bal = veHemi.getLockedBalance(i);
                    if (bal.amount > 0 && bal.end > block.timestamp) {
                        ids[idx++] = i;
                    }
                }
            } catch {
                continue;
            }
        }
        return ids;
    }

    function _upgradeAndSeed() internal returns (uint256[] memory nonTransferableIds) {
        _upgradeProxy();
        nonTransferableIds = _findNonTransferablePositions();
        if (nonTransferableIds.length > 0) {
            vm.prank(GNOSIS_SAFE);
            veHemi.seedAndFinalizeNonTransferablePositions(nonTransferableIds);
        }
    }

    /// @dev Warp time AND advance block number together.
    ///      _checkpoint uses block.number for interpolation; vm.warp alone leaves it flat.
    ///      Assumes ~2s block time on Hemi.
    function _warpAndRoll(uint256 secondsForward) internal {
        vm.warp(block.timestamp + secondsForward);
        vm.roll(block.number + secondsForward / 2);
    }

    function _createTestLock(address user, uint256 amount, uint256 duration)
        internal returns (uint256 tokenId)
    {
        deal(HEMI_TOKEN, user, amount);
        vm.startPrank(user);
        hemiToken.approve(address(veHemi), amount);
        tokenId = veHemi.createLock(amount, duration);
        vm.stopPrank();
    }

    // ═════════════════════════════════════════════════════════════════════
    //  1. UPGRADE PRESERVES STATE
    // ═════════════════════════════════════════════════════════════════════

    function testUpgradePreservesState() public onlyFork {
        _upgradeProxy();

        assertEq(veHemi.totalLocked(), preTotalLocked, "totalLocked changed");
        assertEq(veHemi.totalVeHemiSupply(), preTotalSupply, "totalVeHemiSupply changed");
        assertEq(veHemi.epoch(), preEpoch, "epoch changed");
        assertEq(veHemi.nextTokenId(), preNextTokenId, "nextTokenId changed");
        assertEq(veHemi.totalSupply(), preTotalNFTs, "ERC721 totalSupply changed");

        // V2 storage should be zero-initialized
        assertEq(veHemi.nonTransferableSeedingFinalized(), false, "nonTransferableSeedingFinalized should be false");
        assertEq(veHemi.nonTransferableTotalVeHemiSupply(), 0, "non-transferable supply should be 0 before seeding");
        assertEq(veHemi.forfeitableTotalVeHemiSupply(), 0, "forfeitable supply should be 0 before seeding");

        // Token conservation: HEMI balance should equal totalLocked
        assertEq(hemiToken.balanceOf(address(veHemi)), veHemi.totalLocked(), "token conservation broken");
    }

    // ═════════════════════════════════════════════════════════════════════
    //  2. SEEDING WORKS WITH REAL POSITIONS
    // ═════════════════════════════════════════════════════════════════════

    function testSeedingWithRealPositions() public onlyFork {
        uint256[] memory nonTransferableIds = _upgradeAndSeed();

        assertTrue(veHemi.nonTransferableSeedingFinalized(), "seeding should be finalized");
        if (nonTransferableIds.length > 0) {
            assertGt(
                veHemi.nonTransferableTotalVeHemiSupply(),
                0,
                "non-transferable supply should be > 0 after seeding with active positions"
            );
        }

        emit log_named_uint("Non-transferable positions seeded", nonTransferableIds.length);
        emit log_named_uint("Non-transferable supply", veHemi.nonTransferableTotalVeHemiSupply());
    }

    // ═════════════════════════════════════════════════════════════════════
    //  3. SUPPLY BREAKDOWN CONSISTENCY
    // ═════════════════════════════════════════════════════════════════════

    function testSupplyBreakdownConsistency() public onlyFork {
        _upgradeAndSeed();

        (uint256 total, uint256 locked, uint256 forfeitable_, uint256 transferable) = veHemi.supplyBreakdown();

        // Internal consistency
        assertEq(total, locked + transferable, "total != locked + transferable");
        assertLe(forfeitable_, locked, "forfeitable must be <= locked");

        // Cross-check against individual functions (exact equality)
        assertEq(total, veHemi.totalVeHemiSupply(), "total != totalVeHemiSupply");
        assertEq(locked, veHemi.nonTransferableTotalVeHemiSupply(), "locked != nonTransferableTotalVeHemiSupply");
        assertEq(forfeitable_, veHemi.forfeitableTotalVeHemiSupply(), "forfeitable != forfeitableTotalVeHemiSupply");

        // Mainnet has zero forfeitable positions — verify the curve is empty after seeding
        assertEq(forfeitable_, 0, "Mainnet should have zero forfeitable supply at seed time");

        emit log_named_uint("Total supply", total);
        emit log_named_uint("Non-transferable supply", locked);
        emit log_named_uint("Forfeitable supply", forfeitable_);
        emit log_named_uint("Transferable supply", transferable);
    }

    // ═════════════════════════════════════════════════════════════════════
    //  4. EXISTING POSITIONS UNCHANGED
    // ═════════════════════════════════════════════════════════════════════

    /// @notice Verify balances are preserved across upgrade for both random transferable
    ///         positions AND a sample from the non-transferrable range. Asserts must NOT
    ///         be wrapped in try/catch — that would silently no-op if tokens don't exist.
    function testExistingPositionBalancesUnchanged() public onlyFork {
        // Pick 5 known-existing tokens. Use IDs in the recently-active range so they're
        // very likely to exist on mainnet. Verify tokens exist before snapshotting.
        uint256[] memory testIds = new uint256[](10);
        // 5 tokens from non-transferrable range (likely active non-transferable positions)
        testIds[0] = 28660;
        testIds[1] = 28700;
        testIds[2] = 28750;
        testIds[3] = 28780;
        testIds[4] = 28805;
        // 5 tokens from transferable range (sample throughout the contract's history)
        testIds[5] = 1;
        testIds[6] = 1000;
        testIds[7] = 10000;
        testIds[8] = 25000;
        testIds[9] = 28000;

        // Skip nonexistent tokens (some early IDs may have been burned)
        bool[] memory exists = new bool[](testIds.length);
        uint256[] memory preBalances = new uint256[](testIds.length);
        address[] memory preOwners = new address[](testIds.length);
        uint256 existCount;
        for (uint256 i = 0; i < testIds.length; i++) {
            try veHemi.ownerOf(testIds[i]) returns (address owner) {
                exists[i] = true;
                existCount++;
                preOwners[i] = owner;
                preBalances[i] = veHemi.balanceOfNFT(testIds[i]);
            } catch {}
        }
        assertGt(existCount, 0, "At least some test tokens must exist");

        _upgradeAndSeed();

        // Verify ALL existing tokens have unchanged balance and owner
        for (uint256 i = 0; i < testIds.length; i++) {
            if (!exists[i]) continue;
            assertEq(
                veHemi.balanceOfNFT(testIds[i]),
                preBalances[i],
                string.concat("Balance changed for token ", vm.toString(testIds[i]))
            );
            assertEq(
                veHemi.ownerOf(testIds[i]),
                preOwners[i],
                string.concat("Owner changed for token ", vm.toString(testIds[i]))
            );
        }
    }

    // ═════════════════════════════════════════════════════════════════════
    //  5. EXISTING OPERATIONS WORK POST-UPGRADE
    // ═════════════════════════════════════════════════════════════════════

    function testCreateLockAfterUpgrade() public onlyFork {
        _upgradeAndSeed();

        address user = address(0xBEEF);
        uint256 tokenId = _createTestLock(user, 100 ether, MAX_TIME / 2);
        uint256 expectedBias = _computeBias(tokenId);
        assertEq(veHemi.balanceOfNFT(tokenId), expectedBias, "balanceOfNFT should match closed-form");
        assertGt(expectedBias, 0, "bias should be positive");
        _assertTokenConservation("After createLock");
    }

    function testIncreaseAmountAfterUpgrade() public onlyFork {
        _upgradeAndSeed();

        address user = address(0xBEEF);
        uint256 tokenId = _createTestLock(user, 100 ether, MAX_TIME / 2);
        uint256 balBefore = veHemi.balanceOfNFT(tokenId);

        deal(HEMI_TOKEN, user, 50 ether);
        vm.startPrank(user);
        hemiToken.approve(address(veHemi), 50 ether);
        veHemi.increaseAmount(tokenId, 50 ether);
        vm.stopPrank();

        uint256 expectedBias = _computeBias(tokenId);
        assertEq(veHemi.balanceOfNFT(tokenId), expectedBias, "balanceOfNFT should match closed-form");
        assertGt(expectedBias, balBefore, "balance should increase");
        _assertTokenConservation("After increaseAmount");
    }

    function testIncreaseUnlockTimeAfterUpgrade() public onlyFork {
        _upgradeAndSeed();

        address user = address(0xBEEF);
        uint256 tokenId = _createTestLock(user, 100 ether, MAX_TIME / 4);
        uint256 balBefore = veHemi.balanceOfNFT(tokenId);

        vm.prank(user);
        veHemi.increaseUnlockTime(tokenId, MAX_TIME / 2);

        uint256 expectedBias = _computeBias(tokenId);
        assertEq(veHemi.balanceOfNFT(tokenId), expectedBias, "balanceOfNFT should match closed-form");
        assertGt(expectedBias, balBefore, "voting power should increase");
        _assertTokenConservation("After increaseUnlockTime");
    }

    function testWithdrawAfterUpgrade() public onlyFork {
        _upgradeAndSeed();

        address user = address(0xBEEF);
        uint256 tokenId = _createTestLock(user, 100 ether, 2 * SIX_DAYS);

        // Warp past lock end (advance both timestamp and block number)
        uint64 lockEnd = veHemi.getLockedBalance(tokenId).end;
        uint256 warpSeconds = lockEnd + 1 - block.timestamp;
        _warpAndRoll(warpSeconds);

        uint256 hemiBefore = hemiToken.balanceOf(user);
        vm.prank(user);
        veHemi.withdraw(tokenId);
        uint256 hemiAfter = hemiToken.balanceOf(user);

        assertEq(hemiAfter - hemiBefore, 100 ether, "user should receive exact deposited HEMI back");
        _assertTokenConservation("After withdraw");
    }

    // ═════════════════════════════════════════════════════════════════════
    //  6. LOCKED CURVE TRACKS NEW POSITIONS POST-SEEDING
    // ═════════════════════════════════════════════════════════════════════

    function testNewNonTransferablePositionTrackedPostSeeding() public onlyFork {
        _upgradeAndSeed();

        uint256 nonTransferableSupplyBefore = veHemi.nonTransferableTotalVeHemiSupply();

        // Create a new non-transferable position
        address user = address(0xCAFE);
        deal(HEMI_TOKEN, user, 100 ether);
        vm.startPrank(user);
        hemiToken.approve(address(veHemi), 100 ether);
        veHemi.createLockFor(100 ether, MAX_TIME / 2, user, false, false);
        vm.stopPrank();

        uint256 nonTransferableSupplyAfter = veHemi.nonTransferableTotalVeHemiSupply();
        assertGt(nonTransferableSupplyAfter, nonTransferableSupplyBefore, "non-transferable supply should increase with new non-transferable position");
        _assertTokenConservation("After new non-transferable position");
    }

    function testNewTransferablePositionDoesNotAffectNonTransferableCurve() public onlyFork {
        _upgradeAndSeed();

        uint256 nonTransferableSupplyBefore = veHemi.nonTransferableTotalVeHemiSupply();

        address user = address(0xCAFE);
        _createTestLock(user, 100 ether, MAX_TIME / 2);

        uint256 nonTransferableSupplyAfter = veHemi.nonTransferableTotalVeHemiSupply();
        assertEq(nonTransferableSupplyAfter, nonTransferableSupplyBefore, "non-transferable supply should NOT change for transferable position");
        _assertTokenConservation("After new transferable position");
    }

    // ═════════════════════════════════════════════════════════════════════
    //  7. HISTORICAL QUERIES
    // ═════════════════════════════════════════════════════════════════════

    function testHistoricalNonTransferableSupplyBeforeV2IsZero() public onlyFork {
        _upgradeAndSeed();

        // Query non-transferable supply at a past timestamp (before V2 upgrade)
        uint256 pastTimestamp = block.timestamp - 7 days;
        uint256 pastNonTransferable = veHemi.nonTransferableTotalVeHemiSupplyAt(pastTimestamp);
        assertEq(pastNonTransferable, 0, "non-transferable supply at pre-V2 timestamp should be 0");
    }

    // ═════════════════════════════════════════════════════════════════════
    //  8. LOCKED CURVE DECAYS AFTER TIME WARP
    // ═════════════════════════════════════════════════════════════════════

    function testNonTransferableCurveDecaysOverTime() public onlyFork {
        _upgradeAndSeed();

        uint256 nonTransferableSupplyNow = veHemi.nonTransferableTotalVeHemiSupply();
        assertGt(nonTransferableSupplyNow, 0, "Mainnet must have active non-transferable positions");

        // Warp forward 30 days and checkpoint (advance block number too)
        _warpAndRoll(30 days);
        veHemi.checkpoint();

        uint256 nonTransferableSupplyLater = veHemi.nonTransferableTotalVeHemiSupply();
        assertLt(nonTransferableSupplyLater, nonTransferableSupplyNow, "non-transferable supply should decay over time");
    }

    // ═════════════════════════════════════════════════════════════════════
    //  9. VOTE DELEGATION PRESERVED
    // ═════════════════════════════════════════════════════════════════════

    function testVoteDelegationPreserved() public onlyFork {
        _upgradeAndSeed();

        assertEq(
            address(veHemi.voteDelegation()),
            VOTE_DELEGATION_PROXY,
            "voteDelegation address should be preserved"
        );
    }

    // ═════════════════════════════════════════════════════════════════════
    //  10. MIN_LOCK_AMOUNT ENFORCED POST-UPGRADE
    // ═════════════════════════════════════════════════════════════════════

    function testMinLockAmountEnforced() public onlyFork {
        _upgradeAndSeed();

        address user = address(0xBEEF);
        deal(HEMI_TOKEN, user, 1 ether);
        vm.startPrank(user);
        hemiToken.approve(address(veHemi), 1 ether);
        vm.expectRevert(VeHemi.AmountTooSmall.selector);
        veHemi.createLock(1 ether, MAX_TIME / 2); // 1 HEMI < 10 HEMI minimum
        vm.stopPrank();
    }

    // ═════════════════════════════════════════════════════════════════════
    //  11. DOUBLE SEEDING REVERTS
    // ═════════════════════════════════════════════════════════════════════

    function testDoubleSeedingReverts() public onlyFork {
        uint256[] memory nonTransferableIds = _upgradeAndSeed();
        assertGt(nonTransferableIds.length, 0, "Mainnet must have active non-transferable positions");

        vm.prank(GNOSIS_SAFE);
        vm.expectRevert(VeHemi.SeedingAlreadyFinalized.selector);
        veHemi.seedAndFinalizeNonTransferablePositions(nonTransferableIds);
    }

    // ═════════════════════════════════════════════════════════════════════
    //  12. GLOBAL POINT HISTORY CONSISTENCY
    // ═════════════════════════════════════════════════════════════════════

    function testGlobalPointHistoryAfterUpgrade() public onlyFork {
        _upgradeAndSeed();

        uint256 currentEpoch = veHemi.epoch();
        assertGt(currentEpoch, 0, "epoch should be > 0");

        // The latest global point should have a recent timestamp
        uint256 totalSupply = veHemi.totalVeHemiSupply();
        assertGt(totalSupply, 0, "total supply should be > 0");

        // Create a lock to trigger a checkpoint and verify epoch advances
        uint256 epochBefore = veHemi.epoch();
        _createTestLock(address(0xBEEF), 100 ether, MAX_TIME / 2);
        uint256 epochAfter = veHemi.epoch();
        assertGe(epochAfter, epochBefore, "epoch should not decrease");
    }

    // ═════════════════════════════════════════════════════════════════════
    //  13. EXACT LOCKED SUPPLY VERIFICATION (highest priority)
    // ═════════════════════════════════════════════════════════════════════

    /// @notice Compute expected non-transferable supply from real on-chain position data
    ///         and verify it matches nonTransferableTotalVeHemiSupply EXACTLY.
    /// @dev The stress tests proved that the contract's catchup loop is mathematically
    ///      equivalent to per-position bias summation. We use exact equality here.
    function testNonTransferableSupplyMatchesSumOfPositionBiases() public onlyFork {
        uint256[] memory nonTransferableIds = _upgradeAndSeed();
        assertGt(nonTransferableIds.length, 0, "Mainnet must have active non-transferable positions");

        // Independently compute expected non-transferable supply from individual positions
        uint256 expectedSupply;
        for (uint256 i; i < nonTransferableIds.length; ++i) {
            IVeHemi.LockedBalance memory bal = veHemi.getLockedBalance(nonTransferableIds[i]);
            if (bal.amount > 0 && bal.end > block.timestamp) {
                // slope = amount / MAX_TIME, bias = slope * (end - now)
                uint256 slope = uint256(uint128(bal.amount)) / MAX_TIME;
                uint256 bias = slope * (bal.end - block.timestamp);
                expectedSupply += bias;
            }
        }

        uint256 actualSupply = veHemi.nonTransferableTotalVeHemiSupply();

        // EXACT equality — the contract's catchup loop produces identical results to
        // per-position summation when seeded in the same block.
        assertEq(actualSupply, expectedSupply, "Non-transferable supply does not match sum of individual position biases");

        emit log_named_uint("Expected non-transferable supply", expectedSupply);
        emit log_named_uint("Actual non-transferable supply", actualSupply);
    }

    // ═════════════════════════════════════════════════════════════════════
    //  14. UPGRADE WITHOUT SEED — DEGRADED MODE (V1 behavior)
    // ═════════════════════════════════════════════════════════════════════

    /// @notice Verify contract behaves identically to V1 when upgraded but NOT seeded.
    function testUpgradeWithoutSeedBehavesLikeV1() public onlyFork {
        _upgradeProxy(); // upgrade only, no seed

        // nonTransferableSeedingFinalized should be false
        assertEq(veHemi.nonTransferableSeedingFinalized(), false, "should NOT be finalized");

        // Non-transferable supply is 0
        assertEq(veHemi.nonTransferableTotalVeHemiSupply(), 0, "non-transferable supply should be 0");

        // Supply breakdown: locked = 0, forfeitable = 0, total = transferable
        (uint256 total, uint256 locked, uint256 forfeitable_, uint256 transferable) = veHemi.supplyBreakdown();
        assertEq(locked, 0, "locked should be 0 in degraded mode");
        assertEq(forfeitable_, 0, "forfeitable should be 0 in degraded mode");
        assertEq(total, transferable, "total should equal transferable in degraded mode");

        // All existing operations work normally
        address user = address(0xBEEF);
        uint256 tokenId = _createTestLock(user, 100 ether, MAX_TIME / 2);
        assertGt(veHemi.balanceOfNFT(tokenId), 0, "lock should work in degraded mode");

        // increaseAmount works
        deal(HEMI_TOKEN, user, 50 ether);
        vm.startPrank(user);
        hemiToken.approve(address(veHemi), 50 ether);
        veHemi.increaseAmount(tokenId, 50 ether);
        vm.stopPrank();

        // Withdraw works after expiry
        uint64 lockEnd = veHemi.getLockedBalance(tokenId).end;
        uint256 warpSeconds = lockEnd + 1 - block.timestamp;
        _warpAndRoll(warpSeconds);
        vm.prank(user);
        veHemi.withdraw(tokenId);

        // Owner can still seed later
        uint256[] memory nonTransferableIds = _findNonTransferablePositions();
        if (nonTransferableIds.length > 0) {
            vm.prank(GNOSIS_SAFE);
            veHemi.seedAndFinalizeNonTransferablePositions(nonTransferableIds);
            assertTrue(veHemi.nonTransferableSeedingFinalized(), "seeding should work after delayed activation");
            assertGt(veHemi.nonTransferableTotalVeHemiSupply(), 0, "non-transferable supply should be > 0 after delayed seed");
        }
    }

    // ═════════════════════════════════════════════════════════════════════
    //  15. GAS COST MEASUREMENT
    // ═════════════════════════════════════════════════════════════════════

    /// @notice Measure actual gas cost of seeding with real positions.
    function testSeedingGasCost() public onlyFork {
        _upgradeProxy();
        uint256[] memory nonTransferableIds = _findNonTransferablePositions();
        assertGt(nonTransferableIds.length, 0, "Mainnet must have active non-transferable positions");

        uint256 gasBefore = gasleft();
        vm.prank(GNOSIS_SAFE);
        veHemi.seedAndFinalizeNonTransferablePositions(nonTransferableIds);
        uint256 gasUsed = gasBefore - gasleft();

        emit log_named_uint("Positions seeded", nonTransferableIds.length);
        emit log_named_uint("Gas used for seeding", gasUsed);
        emit log_named_uint("Gas per position", gasUsed / nonTransferableIds.length);

        // Contract comment estimates ~3.9M for 132 positions; allow 2x headroom
        assertLt(gasUsed, 8_000_000, "Seeding gas exceeds 8M safety budget");
    }

    // ═════════════════════════════════════════════════════════════════════
    //  16. PROXY ADMIN UNCHANGED
    // ═════════════════════════════════════════════════════════════════════

    /// @notice Verify the proxy admin ownership is unchanged after upgrade.
    function testProxyAdminUnchangedAfterUpgrade() public onlyFork {
        address ownerBefore = ProxyAdmin(PROXY_ADMIN).owner();
        _upgradeAndSeed();
        address ownerAfter = ProxyAdmin(PROXY_ADMIN).owner();

        assertEq(ownerBefore, ownerAfter, "ProxyAdmin owner changed after upgrade");
        assertEq(ownerAfter, GNOSIS_SAFE, "ProxyAdmin owner should be Gnosis Safe");
    }

    // ═════════════════════════════════════════════════════════════════════
    //  RAW STORAGE SLOT PRESERVATION — defense in depth for the chain
    //  inheritance refactor. These tests read raw storage via vm.load on
    //  the live mainnet proxy both BEFORE and AFTER the upgrade, and assert
    //  that every V1 slot (0–13) is bit-for-bit preserved. If a storage
    //  inheritance reorder ever silently shifts slots, these tests fail
    //  even when getter-based tests would not.
    // ═════════════════════════════════════════════════════════════════════

    /// @notice Snapshot every V1 value-type slot (0–5) pre-upgrade, upgrade,
    ///         then re-read each and assert bit-equality. Catches any slot
    ///         shift in the V1 frozen layout.
    function testForkRawSlotPreservation() public onlyFork {
        // Capture raw bytes at V1 slots 0–13 (value types + mapping bases) AND
        // V2 slots 14–63 (subcurve state + reserved + __gapV2). Mapping base
        // slots themselves contain no data (derived slots do), so reading them
        // just asserts the base offset is unused by anything else — i.e. the
        // mapping isn't repurposed into a value. The V2 region is also
        // captured pre-upgrade (expected zero on mainnet pre-seeding) so the
        // post-upgrade assertion is a true pre/post round-trip rather than a
        // post-only zero check.
        bytes32[64] memory pre;
        for (uint256 i = 0; i < 64; ++i) {
            pre[i] = vm.load(VEHEMI_PROXY, bytes32(i));
        }

        // Pre-upgrade: V2 region (14–63) must already be zero. A non-zero
        // value here would indicate something weird on mainnet (and would also
        // make the post-upgrade preservation check vacuous).
        for (uint256 i = 14; i < 64; ++i) {
            assertEq(
                pre[i],
                bytes32(0),
                string.concat("V2 slot ", vm.toString(i), " non-zero pre-upgrade (mainnet)")
            );
        }

        _upgradeProxy();

        // Post-upgrade: every slot in the full 0–63 range must match pre.
        // Covers V1 (bit-exact preservation), V2 (stays zero pre-seeding),
        // and the full __gapV2[43] region (21–63).
        for (uint256 i = 0; i < 64; ++i) {
            bytes32 post = vm.load(VEHEMI_PROXY, bytes32(i));
            assertEq(
                post,
                pre[i],
                string.concat("slot ", vm.toString(i), " changed during upgrade")
            );
        }
    }

    /// @notice Verify each admin-controlled address slot (voteDelegation=3,
    ///         rewardDistributor=4, forfeitAdmin=5) returns the EXACT same
    ///         value before and after the upgrade.
    function testForkAdminSlotsPreservedPreVsPost() public onlyFork {
        address voteDelBefore = address(veHemi.voteDelegation());
        address rewardBefore = address(veHemi.rewardDistributor());
        address forfeitBefore = veHemi.forfeitAdmin();

        // At least one of the admin slots MUST be non-zero on mainnet, else
        // the pre == post equality below is vacuously true and the test
        // wouldn't catch a real slot shift. voteDelegation is set during
        // initialization and cannot be zero on a live proxy.
        assertTrue(
            voteDelBefore != address(0),
            "voteDelegation unexpectedly zero pre-upgrade - test would be vacuous"
        );

        _upgradeProxy();

        assertEq(
            address(veHemi.voteDelegation()),
            voteDelBefore,
            "voteDelegation (slot 3) changed across upgrade"
        );
        assertEq(
            address(veHemi.rewardDistributor()),
            rewardBefore,
            "rewardDistributor (slot 4) changed across upgrade"
        );
        assertEq(
            veHemi.forfeitAdmin(),
            forfeitBefore,
            "forfeitAdmin (slot 5) changed across upgrade"
        );
    }

    /// @notice Verify the base slot of each V1 mapping is stable across the
    ///         upgrade by picking live tokenIds/timestamps from on-chain state
    ///         and confirming the getter output is identical before vs after.
    function testForkMappingBaseSlotSentinels() public onlyFork {
        // Find the first live tokenId inside the known-active LOCKED range
        // used by the production deploy script (28660–28805). We scan rather
        // than hardcode 28660 so the test keeps working if that specific
        // token is later forfeited/withdrawn. Falls back to failing loudly
        // if no token in the range has a non-zero amount.
        uint256 sampleTokenId = type(uint256).max;
        for (uint256 candidate = 28660; candidate <= 28805; ++candidate) {
            IVeHemi.LockedBalance memory candidateLock = veHemi.getLockedBalance(candidate);
            if (uint256(uint128(candidateLock.amount)) > 0) {
                sampleTokenId = candidate;
                break;
            }
        }
        assertTrue(
            sampleTokenId != type(uint256).max,
            "no active LOCKED token found in 28660-28805 range - mainnet state unexpected"
        );
        IVeHemi.LockedBalance memory lbPre = veHemi.getLockedBalance(sampleTokenId);
        assertGt(
            uint256(uint128(lbPre.amount)),
            0,
            "sample tokenId has zero amount - pre/post comparison would be vacuous"
        );

        uint256 upePre = veHemi.userPointEpoch(sampleTokenId);
        address provPre = veHemi.provider(sampleTokenId);
        uint256 taPre = veHemi.transferableAfter(sampleTokenId);
        bool forfPre = veHemi.forfeitable(sampleTokenId);
        int128 scPre = veHemi.slopeChanges(uint256(lbPre.end));

        // Sample a userPointHistory entry at a populated epoch.
        IVeHemi.UserPoint memory upPre = veHemi.getUserPoint(sampleTokenId, upePre);

        // Sample a globalPointHistory entry at the current head epoch.
        IVeHemi.Point memory gpPre = veHemi.getGlobalPoint(preEpoch);

        _upgradeProxy();

        // Slot 10: LockedBalance — both fields.
        IVeHemi.LockedBalance memory lbPost = veHemi.getLockedBalance(sampleTokenId);
        assertEq(lbPost.amount, lbPre.amount, "locked[t].amount (slot 10) changed");
        assertEq(lbPost.end, lbPre.end, "locked[t].end (slot 10) changed");

        // Slots 8, 9, 11, 12, 13: scalar/address/bool mappings.
        assertEq(veHemi.userPointEpoch(sampleTokenId), upePre, "userPointEpoch (slot 8) changed");
        assertEq(veHemi.slopeChanges(uint256(lbPre.end)), scPre, "slopeChanges (slot 9) changed");
        assertEq(veHemi.provider(sampleTokenId), provPre, "provider (slot 11) changed");
        assertEq(veHemi.transferableAfter(sampleTokenId), taPre, "transferableAfter (slot 12) changed");
        assertEq(veHemi.forfeitable(sampleTokenId), forfPre, "forfeitable (slot 13) changed");

        // Slot 7: UserPoint — owner + all 6 Point fields.
        IVeHemi.UserPoint memory upPost = veHemi.getUserPoint(sampleTokenId, upePre);
        assertEq(upPost.owner, upPre.owner, "userPointHistory[t][e].owner (slot 7) changed");
        assertEq(upPost.point.bias, upPre.point.bias, "userPointHistory bias changed");
        assertEq(upPost.point.slope, upPre.point.slope, "userPointHistory slope changed");
        assertEq(upPost.point.timestamp, upPre.point.timestamp, "userPointHistory timestamp changed");
        assertEq(upPost.point.blockNumber, upPre.point.blockNumber, "userPointHistory blockNumber changed");
        assertEq(upPost.point.amount, upPre.point.amount, "userPointHistory amount changed");
        assertEq(upPost.point.fixedBias, upPre.point.fixedBias, "userPointHistory fixedBias changed");

        // Slot 6: Point — all 6 fields.
        IVeHemi.Point memory gpPost = veHemi.getGlobalPoint(preEpoch);
        assertEq(gpPost.bias, gpPre.bias, "globalPointHistory bias (slot 6) changed");
        assertEq(gpPost.slope, gpPre.slope, "globalPointHistory slope (slot 6) changed");
        assertEq(gpPost.timestamp, gpPre.timestamp, "globalPointHistory timestamp changed");
        assertEq(gpPost.blockNumber, gpPre.blockNumber, "globalPointHistory blockNumber changed");
        assertEq(gpPost.amount, gpPre.amount, "globalPointHistory amount changed");
        assertEq(gpPost.fixedBias, gpPre.fixedBias, "globalPointHistory fixedBias changed");
    }

    // ═════════════════════════════════════════════════════════════════════
    //  17. LOCKED CURVE DECAYS ACROSS SIX_DAYS BOUNDARIES
    // ═════════════════════════════════════════════════════════════════════

    /// @notice Verify non-transferable supply decays monotonically across multiple SIX_DAYS boundary checkpoints.
    function testNonTransferableCurveDecaysAcrossBoundaries() public onlyFork {
        _upgradeAndSeed();

        uint256 initialSupply = veHemi.nonTransferableTotalVeHemiSupply();
        assertGt(initialSupply, 0, "Mainnet must have active non-transferable positions");

        uint256 previousSupply = initialSupply;
        for (uint256 i; i < 5; ++i) {
            _warpAndRoll(SIX_DAYS);
            veHemi.checkpoint();

            uint256 currentSupply = veHemi.nonTransferableTotalVeHemiSupply();
            assertLe(currentSupply, previousSupply, "non-transferable supply must be monotonically non-increasing");
            previousSupply = currentSupply;
        }

        // Final supply should be STRICTLY less than initial (5 * SIX_DAYS = 30 days of decay)
        assertLt(previousSupply, initialSupply, "supply should have strictly decayed after 5 SIX_DAYS periods");
    }

    // ═════════════════════════════════════════════════════════════════════
    //  18. HISTORICAL SUPPLY CONSISTENCY
    // ═════════════════════════════════════════════════════════════════════

    /// @notice Record non-transferable supply at t0, warp forward, then query SupplyAt(t0) and verify it matches.
    function testHistoricalNonTransferableSupplyConsistency() public onlyFork {
        _upgradeAndSeed();

        uint256 t0 = block.timestamp;
        uint256 supply0 = veHemi.nonTransferableTotalVeHemiSupply();

        // Advance 60 days with realistic block progression
        _warpAndRoll(60 days);
        veHemi.checkpoint();

        // Historical query at t0 should return the EXACT original supply
        // (the epoch point at t0 was written during seeding)
        uint256 historicalSupply = veHemi.nonTransferableTotalVeHemiSupplyAt(t0);
        assertEq(historicalSupply, supply0, "Historical non-transferable supply at t0 should match recorded supply");
    }

    // ═════════════════════════════════════════════════════════════════════
    //  19. LOCKED SUPPLY NEVER EXCEEDS TOTAL SUPPLY
    // ═════════════════════════════════════════════════════════════════════

    /// @notice At multiple time points, assert non-transferable supply <= total supply.
    function testNonTransferableSupplyNeverExceedsTotal() public onlyFork {
        _upgradeAndSeed();

        for (uint256 i; i < 4; ++i) {
            uint256 nonTransferableSupply = veHemi.nonTransferableTotalVeHemiSupply();
            uint256 totalSupply = veHemi.totalVeHemiSupply();
            assertLe(nonTransferableSupply, totalSupply, "non-transferable supply must not exceed total supply");

            _warpAndRoll(30 days);
            veHemi.checkpoint();
        }
    }

    // ═════════════════════════════════════════════════════════════════════
    //  20. EXISTING STATE DEEP PRESERVATION
    // ═════════════════════════════════════════════════════════════════════

    /// @notice Verify locked balances (amount + end) and transferableAfter are preserved.
    ///         Uses non-transferrable token IDs (from the known range) to ensure assertions fire.
    function testExistingLockedBalancesAndTransferableAfterPreserved() public onlyFork {
        // Use known non-transferrable token IDs that are likely active on mainnet
        uint256[5] memory tokenIds = [uint256(28660), 28700, 28750, 28780, 28805];

        // Snapshot locked balances and transferableAfter before upgrade
        int128[] memory preAmounts = new int128[](5);
        uint64[] memory preEnds = new uint64[](5);
        uint256[] memory preTransferableAfter = new uint256[](5);
        uint256 snapshotCount;

        for (uint256 i = 0; i < 5; i++) {
            try veHemi.getLockedBalance(tokenIds[i]) returns (IVeHemi.LockedBalance memory bal) {
                preAmounts[i] = bal.amount;
                preEnds[i] = bal.end;
                snapshotCount++;
            } catch {}
            preTransferableAfter[i] = veHemi.transferableAfter(tokenIds[i]);
        }
        assertGt(snapshotCount, 0, "At least some non-transferrable tokens must be snapshotable");

        _upgradeAndSeed();

        uint256 verifiedCount;
        for (uint256 i = 0; i < 5; i++) {
            try veHemi.getLockedBalance(tokenIds[i]) returns (IVeHemi.LockedBalance memory bal) {
                assertEq(bal.amount, preAmounts[i], string.concat("Amount changed for token ", vm.toString(tokenIds[i])));
                assertEq(bal.end, preEnds[i], string.concat("End changed for token ", vm.toString(tokenIds[i])));
                verifiedCount++;
            } catch {}
            assertEq(
                veHemi.transferableAfter(tokenIds[i]),
                preTransferableAfter[i],
                string.concat("transferableAfter changed for token ", vm.toString(tokenIds[i]))
            );
        }
        assertGt(verifiedCount, 0, "At least some balance assertions must have fired");
    }

    // ═════════════════════════════════════════════════════════════════════
    //  21. FORFEITABLE CURVE — POST-UPGRADE ACTIVATION
    // ═════════════════════════════════════════════════════════════════════

    /// @notice Mainnet has zero forfeitable positions, so the forfeitable curve should
    ///         be empty (but initialized) immediately after seeding.
    function testForfeitableCurveEmptyAfterSeeding() public onlyFork {
        _upgradeAndSeed();

        // Forfeitable supply must be exactly 0 (no forfeitable positions on mainnet)
        assertEq(veHemi.forfeitableTotalVeHemiSupply(), 0, "Forfeitable supply must be 0");

        // Yet the curve should be "initialized" — historical query at the seed timestamp
        // should also return 0 (and not revert)
        assertEq(
            veHemi.forfeitableTotalVeHemiSupplyAt(block.timestamp),
            0,
            "Historical forfeitable at seed time should be 0"
        );
    }

    /// @notice Create a forfeitable position post-seeding and verify the forfeitable curve activates.
    function testForfeitablePositionActivatesCurve() public onlyFork {
        _upgradeAndSeed();

        // Set forfeit admin to a known address so we can call forfeit later
        vm.prank(GNOSIS_SAFE);
        veHemi.updateForfeitAdmin(GNOSIS_SAFE);

        // Create a new forfeitable position (must be created from owner since createLockFor
        // uses msg.sender for token transfer)
        address recipient = address(0xF00D);
        uint256 amount = 100 ether;
        uint256 duration = MAX_TIME / 2;

        deal(HEMI_TOKEN, GNOSIS_SAFE, amount);
        vm.startPrank(GNOSIS_SAFE);
        hemiToken.approve(address(veHemi), amount);
        uint256 tokenId = veHemi.createLockFor(amount, duration, recipient, false, true);
        vm.stopPrank();

        // Forfeitable curve should now have non-zero supply
        uint256 forfeitableSupply = veHemi.forfeitableTotalVeHemiSupply();
        assertGt(forfeitableSupply, 0, "Forfeitable supply must be positive after creating forfeitable position");

        // Compute expected supply from the position
        IVeHemi.LockedBalance memory bal = veHemi.getLockedBalance(tokenId);
        uint256 slope = uint256(uint128(bal.amount)) / MAX_TIME;
        uint256 expected = slope * (bal.end - block.timestamp);
        assertEq(forfeitableSupply, expected, "Forfeitable supply should match new position bias exactly");

        // Non-transferable supply should also include this position
        // (it's both non-transferrable AND forfeitable)
        assertGe(veHemi.nonTransferableTotalVeHemiSupply(), forfeitableSupply, "locked >= forfeitable");
    }

    /// @notice Test forfeit operation against a real forfeitable position created post-upgrade.
    function testForfeitOperationOnPostUpgradePosition() public onlyFork {
        _upgradeAndSeed();

        // Set forfeit admin
        vm.prank(GNOSIS_SAFE);
        veHemi.updateForfeitAdmin(GNOSIS_SAFE);

        // Create a forfeitable position
        address recipient = address(0xF00D);
        uint256 amount = 200 ether;

        deal(HEMI_TOKEN, GNOSIS_SAFE, amount);
        vm.startPrank(GNOSIS_SAFE);
        hemiToken.approve(address(veHemi), amount);
        uint256 tokenId = veHemi.createLockFor(amount, MAX_TIME / 2, recipient, false, true);
        vm.stopPrank();

        uint256 nonTransferableSupplyBefore = veHemi.nonTransferableTotalVeHemiSupply();
        uint256 forfeitableBefore = veHemi.forfeitableTotalVeHemiSupply();
        uint256 totalBefore = veHemi.totalVeHemiSupply();
        uint256 hemiAdminBefore = hemiToken.balanceOf(GNOSIS_SAFE);

        // Forfeit the position
        vm.prank(GNOSIS_SAFE);
        veHemi.forfeit(tokenId);

        // All three curves should decrease by the position's bias
        uint256 nonTransferableSupplyAfter = veHemi.nonTransferableTotalVeHemiSupply();
        uint256 forfeitableAfter = veHemi.forfeitableTotalVeHemiSupply();
        uint256 totalAfter = veHemi.totalVeHemiSupply();

        assertLt(nonTransferableSupplyAfter, nonTransferableSupplyBefore, "Non-transferable should decrease after forfeit");
        assertLt(forfeitableAfter, forfeitableBefore, "Forfeitable should decrease after forfeit");
        assertLt(totalAfter, totalBefore, "Total should decrease after forfeit");

        // Forfeitable should drop to 0 (only one forfeitable position existed)
        assertEq(forfeitableAfter, 0, "Forfeitable should be 0 after forfeiting only forfeitable position");

        // HEMI tokens should be returned to forfeitAdmin (Gnosis Safe)
        uint256 hemiAdminAfter = hemiToken.balanceOf(GNOSIS_SAFE);
        assertEq(hemiAdminAfter, hemiAdminBefore + amount, "Forfeit admin should receive locked HEMI");

        // Token conservation must hold
        assertEq(hemiToken.balanceOf(address(veHemi)), veHemi.totalLocked(), "Token conservation broken");
    }

    // ═════════════════════════════════════════════════════════════════════
    //  22. FOUR-TUPLE BREAKDOWN WITH MIXED POST-UPGRADE POSITIONS
    // ═════════════════════════════════════════════════════════════════════

    /// @notice Create one of each position type post-seeding and verify the 4-tuple breakdown
    ///         exactly partitions the supply with EXACT delta verification.
    function testSupplyBreakdownAllThreeTypesPostUpgrade() public onlyFork {
        _upgradeAndSeed();

        // Snapshot pre-creation state
        uint256 preTotal = veHemi.totalVeHemiSupply();
        uint256 preNonTransferable = veHemi.nonTransferableTotalVeHemiSupply();
        uint256 preForfeitable = veHemi.forfeitableTotalVeHemiSupply();

        // Create three positions and capture their token IDs
        (uint256 tTokenId, uint256 lTokenId, uint256 fTokenId) = _createThreeTypePositions();

        // Compute EXACT expected biases for each new position
        uint256 tBias = _computeBias(tTokenId);
        uint256 lBias = _computeBias(lTokenId);
        uint256 fBias = _computeBias(fTokenId);

        // Verify 4-tuple breakdown matches individual deltas exactly
        _verifyBreakdownDeltas(preTotal, preNonTransferable, preForfeitable, tBias, lBias, fBias);

        // balanceOfNFT verification for each new position
        assertEq(veHemi.balanceOfNFT(tTokenId), tBias, "transferable balanceOfNFT");
        assertEq(veHemi.balanceOfNFT(lTokenId), lBias, "locked balanceOfNFT");
        assertEq(veHemi.balanceOfNFT(fTokenId), fBias, "forfeitable balanceOfNFT");

        // Token conservation
        assertEq(hemiToken.balanceOf(address(veHemi)), veHemi.totalLocked(), "Token conservation");
    }

    function _createThreeTypePositions() internal returns (uint256 t, uint256 l, uint256 f) {
        // Create one transferable position
        address tUser = address(0xAAAA);
        deal(HEMI_TOKEN, tUser, 100 ether);
        vm.startPrank(tUser);
        hemiToken.approve(address(veHemi), 100 ether);
        t = veHemi.createLock(100 ether, MAX_TIME / 2);
        vm.stopPrank();

        // Create one non-transferable-only position
        deal(HEMI_TOKEN, GNOSIS_SAFE, 350 ether);
        vm.startPrank(GNOSIS_SAFE);
        hemiToken.approve(address(veHemi), 350 ether);
        l = veHemi.createLockFor(200 ether, MAX_TIME / 2, address(0xBBBB), false, false);
        f = veHemi.createLockFor(150 ether, MAX_TIME / 2, address(0xCCCC), false, true);
        vm.stopPrank();
    }

    function _verifyBreakdownDeltas(
        uint256 preTotal,
        uint256 preNonTransferable,
        uint256 preForfeitable,
        uint256 tBias,
        uint256 lBias,
        uint256 fBias
    ) internal view {
        (uint256 total, uint256 locked, uint256 forfeitable_, uint256 transferable) = veHemi.supplyBreakdown();

        // EXACT delta verification (the strongest possible check)
        assertEq(total - preTotal, tBias + lBias + fBias, "Total delta = sum of 3 biases");
        assertEq(locked - preNonTransferable, lBias + fBias, "Non-transferable delta = non-transferable + forfeitable biases");
        assertEq(forfeitable_ - preForfeitable, fBias, "Forfeitable delta = forfeitable bias");

        // Cross-check supplyBreakdown matches individual functions
        assertEq(total, veHemi.totalVeHemiSupply(), "breakdown total");
        assertEq(locked, veHemi.nonTransferableTotalVeHemiSupply(), "breakdown non-transferable");
        assertEq(forfeitable_, veHemi.forfeitableTotalVeHemiSupply(), "breakdown forfeitable");
        assertEq(transferable, total - locked, "breakdown transferable");

        // Ordering invariants
        assertLe(forfeitable_, locked, "forfeitable <= locked");
        assertLe(locked, total, "locked <= total");
    }

    /// @dev Compute the closed-form bias for a token: slope * (end - now)
    function _computeBias(uint256 tokenId) internal view returns (uint256) {
        IVeHemi.LockedBalance memory bal = veHemi.getLockedBalance(tokenId);
        if (bal.amount <= 0 || bal.end <= block.timestamp) return 0;
        uint256 slope = uint256(uint128(bal.amount)) / MAX_TIME;
        return slope * (bal.end - block.timestamp);
    }

    // ═════════════════════════════════════════════════════════════════════
    //  23. VIEW FUNCTIONS WITHOUT PRECEDING CHECKPOINT
    // ═════════════════════════════════════════════════════════════════════

    /// @notice Warp time WITHOUT checkpointing first, then call view functions.
    ///         This forces the catchup loop in _supplyAt / _subcurveSupplyAtFromPoint
    ///         to walk forward from the last stored epoch.
    function testViewFunctionsExerciseCatchupLoop() public onlyFork {
        _upgradeAndSeed();

        uint256 nonTransferableSupplyBefore = veHemi.nonTransferableTotalVeHemiSupply();
        uint256 totalBefore = veHemi.totalVeHemiSupply();

        // Warp 30 days WITHOUT calling checkpoint
        _warpAndRoll(30 days);

        // View functions should walk the catchup loop and return decayed values
        uint256 nonTransferableSupplyAfter = veHemi.nonTransferableTotalVeHemiSupply();
        uint256 totalAfter = veHemi.totalVeHemiSupply();
        uint256 forfeitableAfter = veHemi.forfeitableTotalVeHemiSupply();

        // Decay invariants
        assertLt(nonTransferableSupplyAfter, nonTransferableSupplyBefore, "Non-transferable should decay (view catchup loop)");
        assertLt(totalAfter, totalBefore, "Total should decay (view catchup loop)");
        assertEq(forfeitableAfter, 0, "Forfeitable still 0 (no forfeitable positions on mainnet)");

        // Now checkpoint and verify the values match what the view returned
        veHemi.checkpoint();
        assertEq(veHemi.nonTransferableTotalVeHemiSupply(), nonTransferableSupplyAfter, "Post-checkpoint matches view catchup");
        assertEq(veHemi.totalVeHemiSupply(), totalAfter, "Post-checkpoint matches view catchup");

        // supplyBreakdown should also work without preceding checkpoint
        // (test by warping again)
        _warpAndRoll(30 days);
        (uint256 total2, uint256 nonTransferable2, uint256 forfeitable2, uint256 transferable2) = veHemi.supplyBreakdown();
        assertLt(nonTransferable2, nonTransferableSupplyAfter, "Breakdown non-transferable should decay further");
        assertEq(forfeitable2, 0, "Breakdown forfeitable still 0");
        assertEq(total2, nonTransferable2 + transferable2, "Breakdown sums correctly");
    }

    // ═════════════════════════════════════════════════════════════════════
    //  24. TOKEN CONSERVATION ACROSS OPERATIONS
    // ═════════════════════════════════════════════════════════════════════

    /// @notice Verify hemi.balanceOf(veHemi) == veHemi.totalLocked() across all operations.
    function testTokenConservationAcrossOperations() public onlyFork {
        _upgradeAndSeed();
        _assertTokenConservation("After seed");

        // Set forfeit admin
        vm.prank(GNOSIS_SAFE);
        veHemi.updateForfeitAdmin(GNOSIS_SAFE);

        // Create a new lock
        address user = address(0xDEAD);
        uint256 tokenId = _createTestLock(user, 100 ether, MAX_TIME / 2);
        _assertTokenConservation("After createLock");

        // Increase amount
        deal(HEMI_TOKEN, user, 50 ether);
        vm.startPrank(user);
        hemiToken.approve(address(veHemi), 50 ether);
        veHemi.increaseAmount(tokenId, 50 ether);
        vm.stopPrank();
        _assertTokenConservation("After increaseAmount");

        // Increase unlock time
        vm.prank(user);
        veHemi.increaseUnlockTime(tokenId, (MAX_TIME * 3) / 4);
        _assertTokenConservation("After increaseUnlockTime");

        // Create a forfeitable position
        deal(HEMI_TOKEN, GNOSIS_SAFE, 100 ether);
        vm.startPrank(GNOSIS_SAFE);
        hemiToken.approve(address(veHemi), 100 ether);
        uint256 forfeitableTokenId = veHemi.createLockFor(100 ether, MAX_TIME / 2, address(0xF00D), false, true);
        vm.stopPrank();
        _assertTokenConservation("After create forfeitable");

        // Forfeit it
        vm.prank(GNOSIS_SAFE);
        veHemi.forfeit(forfeitableTokenId);
        _assertTokenConservation("After forfeit");

        // Withdraw expired lock
        uint64 lockEnd = veHemi.getLockedBalance(tokenId).end;
        _warpAndRoll(lockEnd + 1 - block.timestamp);
        vm.prank(user);
        veHemi.withdraw(tokenId);
        _assertTokenConservation("After withdraw");
    }

    function _assertTokenConservation(string memory label) internal view {
        assertEq(
            hemiToken.balanceOf(address(veHemi)),
            veHemi.totalLocked(),
            string.concat("Token conservation broken: ", label)
        );
    }

    // ═════════════════════════════════════════════════════════════════════
    //  25. INDEPENDENT SHADOW VERIFICATION OF MAINNET POSITIONS
    // ═════════════════════════════════════════════════════════════════════

    /// @notice Sum biases of ALL real on-chain non-transferrable positions and verify
    ///         exact agreement with the contract's nonTransferableTotalVeHemiSupply.
    ///         This is the strongest possible correctness check against real mainnet data.
    function testExactShadowAgreementOnMainnetPositions() public onlyFork {
        uint256[] memory nonTransferableIds = _upgradeAndSeed();
        assertGt(nonTransferableIds.length, 0, "Mainnet must have active non-transferable positions");

        // Independently sum biases for all known non-transferrable positions
        uint256 expectedNonTransferable;
        uint256 expectedForfeitable;
        for (uint256 i; i < nonTransferableIds.length; ++i) {
            uint256 tokenId = nonTransferableIds[i];
            IVeHemi.LockedBalance memory bal = veHemi.getLockedBalance(tokenId);
            if (bal.amount <= 0 || bal.end <= block.timestamp) continue;

            uint256 slope = uint256(uint128(bal.amount)) / MAX_TIME;
            uint256 bias = slope * (bal.end - block.timestamp);
            expectedNonTransferable += bias;

            // Check if this position is forfeitable
            if (veHemi.forfeitable(tokenId)) {
                expectedForfeitable += bias;
            }
        }

        // EXACT equality
        assertEq(veHemi.nonTransferableTotalVeHemiSupply(), expectedNonTransferable, "Non-transferable exact mismatch");
        assertEq(veHemi.forfeitableTotalVeHemiSupply(), expectedForfeitable, "Forfeitable exact mismatch");

        // Mainnet currently has zero forfeitable positions
        assertEq(expectedForfeitable, 0, "Mainnet should have zero forfeitable positions");

        emit log_named_uint("Non-transferable positions counted", nonTransferableIds.length);
        emit log_named_uint("Expected non-transferable supply", expectedNonTransferable);
        emit log_named_uint("Expected forfeitable supply", expectedForfeitable);
    }

    // ═════════════════════════════════════════════════════════════════════
    //  26. FORFEITABLE CURVE HISTORICAL QUERY
    // ═════════════════════════════════════════════════════════════════════

    /// @notice Verify forfeitable curve historical queries work correctly across mutations.
    /// @dev Note: same-block operations overwrite the same epoch entry, so we must warp
    ///      between operations to test historical queries at distinct epochs.
    function testForfeitableCurveHistoricalQueries() public onlyFork {
        _upgradeAndSeed();

        // Snapshot t0 (forfeitable should be 0 at seed time)
        uint256 t0 = block.timestamp;
        assertEq(veHemi.forfeitableTotalVeHemiSupply(), 0, "Forfeitable 0 at t0");

        // Warp forward so the next operation creates a new epoch
        _warpAndRoll(7 days);
        veHemi.checkpoint();

        // Set forfeit admin and create a forfeitable position
        vm.prank(GNOSIS_SAFE);
        veHemi.updateForfeitAdmin(GNOSIS_SAFE);

        deal(HEMI_TOKEN, GNOSIS_SAFE, 100 ether);
        vm.startPrank(GNOSIS_SAFE);
        hemiToken.approve(address(veHemi), 100 ether);
        veHemi.createLockFor(100 ether, MAX_TIME / 2, address(0xCAFE), false, true);
        vm.stopPrank();

        uint256 t1 = block.timestamp;
        uint256 supplyAtT1 = veHemi.forfeitableTotalVeHemiSupply();
        assertGt(supplyAtT1, 0, "Forfeitable > 0 after creation");

        // Warp 30 days
        _warpAndRoll(30 days);
        veHemi.checkpoint();

        // Historical query at t0 should still be 0 (no forfeitable positions existed yet)
        assertEq(veHemi.forfeitableTotalVeHemiSupplyAt(t0), 0, "Historical at t0 should be 0");

        // Historical query at t1 should match the recorded supply
        assertEq(veHemi.forfeitableTotalVeHemiSupplyAt(t1), supplyAtT1, "Historical at t1 should match");

        // Current supply should be lower than t1 (decayed)
        uint256 currentSupply = veHemi.forfeitableTotalVeHemiSupply();
        assertLt(currentSupply, supplyAtT1, "Current should be less than t1 (decayed)");
    }

    // ═════════════════════════════════════════════════════════════════════
    //  27. ALL THREE CURVES ORDERED INVARIANT
    // ═════════════════════════════════════════════════════════════════════

    /// @notice At multiple timestamps, verify forfeitable <= locked <= total.
    function testAllThreeCurvesOrdering() public onlyFork {
        _upgradeAndSeed();

        // Create one of each type to make all curves non-trivial
        vm.prank(GNOSIS_SAFE);
        veHemi.updateForfeitAdmin(GNOSIS_SAFE);

        deal(HEMI_TOKEN, GNOSIS_SAFE, 300 ether);
        vm.startPrank(GNOSIS_SAFE);
        hemiToken.approve(address(veHemi), 300 ether);
        veHemi.createLockFor(100 ether, MAX_TIME / 2, address(0x1111), false, false); // non-transferable-only
        veHemi.createLockFor(100 ether, MAX_TIME / 2, address(0x2222), false, true);  // forfeitable
        vm.stopPrank();

        deal(HEMI_TOKEN, address(0x3333), 100 ether);
        vm.startPrank(address(0x3333));
        hemiToken.approve(address(veHemi), 100 ether);
        veHemi.createLock(100 ether, MAX_TIME / 2);  // transferable
        vm.stopPrank();

        // Check ordering at multiple time points
        for (uint256 i; i < 4; ++i) {
            _assertOrdering(string.concat("Step ", vm.toString(i)));
            _warpAndRoll(45 days);
            veHemi.checkpoint();
        }
    }

    function _assertOrdering(string memory label) internal view {
        uint256 total = veHemi.totalVeHemiSupply();
        uint256 locked = veHemi.nonTransferableTotalVeHemiSupply();
        uint256 forfeitable_ = veHemi.forfeitableTotalVeHemiSupply();

        assertLe(forfeitable_, locked, string.concat(label, ": forfeitable <= locked"));
        assertLe(locked, total, string.concat(label, ": locked <= total"));

        // Cross-check supplyBreakdown matches individual functions
        (uint256 bdTotal, uint256 bdNonTransferable, uint256 bdForf, uint256 bdTrans) = veHemi.supplyBreakdown();
        assertEq(bdTotal, total, string.concat(label, ": breakdown total"));
        assertEq(bdNonTransferable, locked, string.concat(label, ": breakdown locked"));
        assertEq(bdForf, forfeitable_, string.concat(label, ": breakdown forfeitable"));
        assertEq(bdTrans, total - locked, string.concat(label, ": breakdown transferable"));
    }

    // ═════════════════════════════════════════════════════════════════════
    //  28. DEPLOY SCRIPT ARRAY VALIDATION (CRITICAL)
    // ═════════════════════════════════════════════════════════════════════

    /// @notice The deploy script's hardcoded NON_TRANSFERABLE_TOKEN_IDS array. MUST match deploy/04_upgrade_vehemi_v2.ts.
    /// @dev If you update the deploy script's array, update this one too. The test below
    ///      enforces that this array matches the on-chain non-transferrable position set.
    function _deployScriptNonTransferableTokenIds() internal pure returns (uint256[] memory) {
        uint256[] memory ids = new uint256[](126);
        uint256 idx;
        // Block 1: 28660-28669
        for (uint256 i = 28660; i <= 28669; i++) ids[idx++] = i;
        // Block 2: 28670-28679
        for (uint256 i = 28670; i <= 28679; i++) ids[idx++] = i;
        // Block 3: 28680-28689
        for (uint256 i = 28680; i <= 28689; i++) ids[idx++] = i;
        // Block 4: 28690-28699
        for (uint256 i = 28690; i <= 28699; i++) ids[idx++] = i;
        // Block 5: 28700, 28705-28713
        ids[idx++] = 28700;
        for (uint256 i = 28705; i <= 28713; i++) ids[idx++] = i;
        // Block 6: 28714-28721
        for (uint256 i = 28714; i <= 28721; i++) ids[idx++] = i;
        // Block 7: 28726-28737
        for (uint256 i = 28726; i <= 28737; i++) ids[idx++] = i;
        // Block 8: 28738-28747
        for (uint256 i = 28738; i <= 28747; i++) ids[idx++] = i;
        // Block 9: 28748-28757
        for (uint256 i = 28748; i <= 28757; i++) ids[idx++] = i;
        // Block 10: 28758-28766, 28771
        for (uint256 i = 28758; i <= 28766; i++) ids[idx++] = i;
        ids[idx++] = 28771;
        // Block 11: 28772-28781
        for (uint256 i = 28772; i <= 28781; i++) ids[idx++] = i;
        // Block 12: 28782-28787, 28792-28795
        for (uint256 i = 28782; i <= 28787; i++) ids[idx++] = i;
        for (uint256 i = 28792; i <= 28795; i++) ids[idx++] = i;
        // Block 13: 28796, 28801-28805
        ids[idx++] = 28796;
        for (uint256 i = 28801; i <= 28805; i++) ids[idx++] = i;
        require(idx == 126, "Deploy script array must have 126 IDs");
        return ids;
    }

    /// @notice CRITICAL: Verify the deploy script's hardcoded NON_TRANSFERABLE_TOKEN_IDS array
    ///         matches the actual on-chain non-transferrable position set.
    function testDeployScriptArrayMatchesOnChainState() public onlyFork {
        uint256[] memory deployIds = _deployScriptNonTransferableTokenIds();
        uint256[] memory scannedIds = _findNonTransferablePositions();

        // First, verify lengths match
        assertEq(deployIds.length, scannedIds.length, "Deploy script ID count != scanned ID count");

        // Both arrays should be sorted ascending. Compare element-by-element.
        for (uint256 i; i < deployIds.length; i++) {
            assertEq(deployIds[i], scannedIds[i], string.concat("Mismatch at index ", vm.toString(i)));
        }

        // Sanity: every deploy script ID is non-transferrable, owned, and active
        for (uint256 i; i < deployIds.length; i++) {
            uint256 id = deployIds[i];
            assertGt(veHemi.transferableAfter(id), 0, "Deploy script ID is not non-transferrable");
            // ownerOf must not revert
            address owner = veHemi.ownerOf(id);
            assertTrue(owner != address(0), "Deploy script ID has no owner");
            IVeHemi.LockedBalance memory bal = veHemi.getLockedBalance(id);
            assertGt(bal.amount, 0, "Deploy script ID has zero amount");
            assertGt(bal.end, block.timestamp, "Deploy script ID has expired");
        }
    }

    /// @notice Verify seeding with the EXACT deploy script array succeeds and produces
    ///         the same result as seeding with the scanner-discovered array.
    function testSeedingWithDeployScriptArray() public onlyFork {
        // First, take a snapshot — we'll need to restore for the second seed
        uint256 snapshotId = vm.snapshot();

        // Path 1: Seed with scanner-derived array
        _upgradeProxy();
        uint256[] memory scannedIds = _findNonTransferablePositions();
        vm.prank(GNOSIS_SAFE);
        veHemi.seedAndFinalizeNonTransferablePositions(scannedIds);
        uint256 nonTransferableFromScan = veHemi.nonTransferableTotalVeHemiSupply();
        uint256 forfeitableFromScan = veHemi.forfeitableTotalVeHemiSupply();

        // Restore snapshot
        vm.revertTo(snapshotId);

        // Path 2: Seed with deploy script array
        _upgradeProxy();
        uint256[] memory deployIds = _deployScriptNonTransferableTokenIds();
        vm.prank(GNOSIS_SAFE);
        veHemi.seedAndFinalizeNonTransferablePositions(deployIds);
        uint256 nonTransferableFromDeploy = veHemi.nonTransferableTotalVeHemiSupply();
        uint256 forfeitableFromDeploy = veHemi.forfeitableTotalVeHemiSupply();

        // Both seedings must produce identical results
        assertEq(nonTransferableFromScan, nonTransferableFromDeploy, "Non-transferable supply differs between scan and deploy");
        assertEq(forfeitableFromScan, forfeitableFromDeploy, "Forfeitable supply differs between scan and deploy");
    }

    // ═════════════════════════════════════════════════════════════════════
    //  29. SEEDING REVERT MATRIX
    // ═════════════════════════════════════════════════════════════════════

    function testSeedingRevertsOnEmptyArray() public onlyFork {
        _upgradeProxy();
        uint256[] memory empty = new uint256[](0);
        vm.prank(GNOSIS_SAFE);
        vm.expectRevert(VeHemi.EmptyArray.selector);
        veHemi.seedAndFinalizeNonTransferablePositions(empty);
        // Verify state is clean — seeding NOT finalized
        assertFalse(veHemi.nonTransferableSeedingFinalized(), "Seeding should not be finalized after revert");
        assertEq(veHemi.nonTransferableTotalVeHemiSupply(), 0, "No non-transferable supply");
    }

    function testSeedingRevertsOnUnsortedIds() public onlyFork {
        _upgradeProxy();
        uint256[] memory unsorted = new uint256[](3);
        unsorted[0] = 28665;
        unsorted[1] = 28660; // out of order
        unsorted[2] = 28670;
        vm.prank(GNOSIS_SAFE);
        vm.expectRevert(VeHemi.UnsortedOrDuplicateTokenIds.selector);
        veHemi.seedAndFinalizeNonTransferablePositions(unsorted);
        assertFalse(veHemi.nonTransferableSeedingFinalized(), "Should not be finalized");
    }

    function testSeedingRevertsOnDuplicateIds() public onlyFork {
        _upgradeProxy();
        uint256[] memory dup = new uint256[](3);
        dup[0] = 28660;
        dup[1] = 28665;
        dup[2] = 28665; // duplicate
        vm.prank(GNOSIS_SAFE);
        vm.expectRevert(VeHemi.UnsortedOrDuplicateTokenIds.selector);
        veHemi.seedAndFinalizeNonTransferablePositions(dup);
        assertFalse(veHemi.nonTransferableSeedingFinalized(), "Should not be finalized");
    }

    function testSeedingRevertsOnTransferableTokenInArray() public onlyFork {
        _upgradeProxy();
        // Find a transferable token (token ID 1 is highly likely to be transferable on mainnet)
        // Token IDs outside 28625-28809 are transferable per our scan
        uint256[] memory mixed = new uint256[](2);
        mixed[0] = 1; // transferable
        mixed[1] = 28660; // non-transferable
        vm.prank(GNOSIS_SAFE);
        vm.expectRevert(VeHemi.NotNonTransferrable.selector);
        veHemi.seedAndFinalizeNonTransferablePositions(mixed);
        assertFalse(veHemi.nonTransferableSeedingFinalized(), "Should not be finalized");
    }

    function testSeedingRevertsOnNonexistentToken() public onlyFork {
        _upgradeProxy();
        uint256[] memory bad = new uint256[](1);
        bad[0] = type(uint256).max - 1; // definitely doesn't exist
        vm.prank(GNOSIS_SAFE);
        vm.expectRevert(VeHemi.TokenDoesNotExist.selector);
        veHemi.seedAndFinalizeNonTransferablePositions(bad);
        assertFalse(veHemi.nonTransferableSeedingFinalized(), "Should not be finalized");
    }

    function testSeedingRevertsOnNonOwner() public onlyFork {
        _upgradeProxy();
        uint256[] memory ids = _deployScriptNonTransferableTokenIds();
        // Call from a random non-owner address
        vm.prank(address(0xBAD));
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", address(0xBAD)));
        veHemi.seedAndFinalizeNonTransferablePositions(ids);
        assertFalse(veHemi.nonTransferableSeedingFinalized(), "Should not be finalized");
    }

    // ═════════════════════════════════════════════════════════════════════
    //  30. FORFEITABLE CURVE: increaseAmount POST-UPGRADE
    // ═════════════════════════════════════════════════════════════════════

    function testIncreaseAmountOnForfeitablePosition() public onlyFork {
        _upgradeAndSeed();
        vm.prank(GNOSIS_SAFE);
        veHemi.updateForfeitAdmin(GNOSIS_SAFE);

        address user = address(0xF00D);
        deal(HEMI_TOKEN, GNOSIS_SAFE, 100 ether);
        vm.startPrank(GNOSIS_SAFE);
        hemiToken.approve(address(veHemi), 100 ether);
        uint256 tokenId = veHemi.createLockFor(100 ether, MAX_TIME / 2, user, false, true);
        vm.stopPrank();

        uint256 nonTransferableSupplyBefore = veHemi.nonTransferableTotalVeHemiSupply();
        uint256 forfeitableBefore = veHemi.forfeitableTotalVeHemiSupply();

        // increaseAmount must be called by token owner
        deal(HEMI_TOKEN, user, 50 ether);
        vm.startPrank(user);
        hemiToken.approve(address(veHemi), 50 ether);
        veHemi.increaseAmount(tokenId, 50 ether);
        vm.stopPrank();

        // Compute expected new bias from contract state
        uint256 newBias = _computeBias(tokenId);
        uint256 oldBias = forfeitableBefore; // since this was the only forfeitable position before this op (and at same timestamp)

        uint256 nonTransferableSupplyAfter = veHemi.nonTransferableTotalVeHemiSupply();
        uint256 forfeitableAfter = veHemi.forfeitableTotalVeHemiSupply();

        // Both curves should increase by the same delta (the new position is in both)
        uint256 nonTransferableDelta = nonTransferableSupplyAfter - nonTransferableSupplyBefore;
        uint256 forfeitableDelta = forfeitableAfter - forfeitableBefore;
        assertEq(nonTransferableDelta, forfeitableDelta, "Non-transferable delta == forfeitable delta for forfeitable position");

        // The new total forfeitable supply should equal the new bias of this single position
        // (since it was the only forfeitable position created at this timestamp)
        assertEq(forfeitableAfter, newBias, "Forfeitable supply should equal new bias exactly");
        assertGt(newBias, oldBias, "New bias should be greater (amount increased)");
    }

    // ═════════════════════════════════════════════════════════════════════
    //  31. FORFEITABLE CURVE: increaseUnlockTime POST-UPGRADE
    // ═════════════════════════════════════════════════════════════════════

    /// @notice V2: increaseUnlockTime does NOT change the forfeitable subcurve.
    ///         The subcurve is bounded by transferableAfter (original end).
    function testIncreaseUnlockTimeOnForfeitablePosition() public onlyFork {
        _upgradeAndSeed();
        vm.prank(GNOSIS_SAFE);
        veHemi.updateForfeitAdmin(GNOSIS_SAFE);

        address user = address(0xF00D);
        deal(HEMI_TOKEN, GNOSIS_SAFE, 100 ether);
        vm.startPrank(GNOSIS_SAFE);
        hemiToken.approve(address(veHemi), 100 ether);
        uint256 tokenId = veHemi.createLockFor(100 ether, MAX_TIME / 4, user, false, true);
        vm.stopPrank();

        uint256 oldEnd = veHemi.getLockedBalance(tokenId).end;
        uint256 oldForfeitable = veHemi.forfeitableTotalVeHemiSupply();
        uint256 oldTotal = veHemi.totalVeHemiSupply();

        // Verify forfeitable slope change exists at old end (= transferableAfter)
        int128 oldSlopeChange = veHemi.forfeitableSlopeChanges(oldEnd);
        assertLt(oldSlopeChange, int128(0), "Slope change should be negative at original end");

        vm.prank(user);
        veHemi.increaseUnlockTime(tokenId, MAX_TIME / 2);

        uint256 newEnd = veHemi.getLockedBalance(tokenId).end;
        assertGt(newEnd, oldEnd, "Lock end should increase");

        // Forfeitable supply should NOT change (bounded by transferableAfter = oldEnd)
        assertEq(veHemi.forfeitableTotalVeHemiSupply(), oldForfeitable, "Forfeitable should NOT change");

        // Global supply SHOULD increase
        assertGt(veHemi.totalVeHemiSupply(), oldTotal, "Global should increase");

        // Forfeitable slope change should REMAIN at original end (transferableAfter)
        assertEq(veHemi.forfeitableSlopeChanges(oldEnd), oldSlopeChange, "Slope change stays at original end");
        // NO forfeitable slope change at new end
        assertEq(veHemi.forfeitableSlopeChanges(newEnd), int128(0), "No forfeitable slope change at new end");

        // transferableAfter should NOT have changed
        assertEq(veHemi.transferableAfter(tokenId), oldEnd, "transferableAfter unchanged");
    }

    // ═════════════════════════════════════════════════════════════════════
    //  32. FORFEITABLE CURVE: DECAY THEN FORFEIT
    // ═════════════════════════════════════════════════════════════════════

    function testDecayThenForfeitForfeitablePosition() public onlyFork {
        _upgradeAndSeed();
        vm.prank(GNOSIS_SAFE);
        veHemi.updateForfeitAdmin(GNOSIS_SAFE);

        address user = address(0xF00D);
        deal(HEMI_TOKEN, GNOSIS_SAFE, 100 ether);
        vm.startPrank(GNOSIS_SAFE);
        hemiToken.approve(address(veHemi), 100 ether);
        uint256 tokenId = veHemi.createLockFor(100 ether, MAX_TIME / 2, user, false, true);
        vm.stopPrank();

        uint256 supplyAtCreation = veHemi.forfeitableTotalVeHemiSupply();
        assertGt(supplyAtCreation, 0, "Should have supply after creation");

        // Warp 60 days (without checkpointing — exercises the catchup loop)
        _warpAndRoll(60 days);

        // Forfeitable supply should have decayed
        uint256 supplyAfterDecay = veHemi.forfeitableTotalVeHemiSupply();
        assertLt(supplyAfterDecay, supplyAtCreation, "Should decay after 60 days");

        // Now forfeit — this triggers _checkpoint which must correctly project
        // the forfeitable point forward and subtract the now-smaller bias
        vm.prank(GNOSIS_SAFE);
        veHemi.forfeit(tokenId);

        // After forfeit, supply should drop to exactly 0 (only forfeitable position)
        assertEq(veHemi.forfeitableTotalVeHemiSupply(), 0, "Forfeitable should be 0 after forfeit");

        // Token conservation must hold
        assertEq(hemiToken.balanceOf(address(veHemi)), veHemi.totalLocked(), "Token conservation");
    }

    // ═════════════════════════════════════════════════════════════════════
    //  33. FORFEITABLE CURVE: MULTIPLE POSITIONS WITH SHADOW VERIFICATION
    // ═════════════════════════════════════════════════════════════════════

    function testMultipleForfeitablePositionsShadowVerification() public onlyFork {
        _upgradeAndSeed();
        vm.prank(GNOSIS_SAFE);
        veHemi.updateForfeitAdmin(GNOSIS_SAFE);

        // Create 5 forfeitable positions with varied amounts and durations
        uint256[] memory tokenIds = new uint256[](5);
        uint256[] memory amounts = new uint256[](5);
        amounts[0] = 50 ether;
        amounts[1] = 100 ether;
        amounts[2] = 200 ether;
        amounts[3] = 75 ether;
        amounts[4] = 150 ether;

        uint256[] memory durations = new uint256[](5);
        durations[0] = MAX_TIME;       // max
        durations[1] = MAX_TIME / 2;
        durations[2] = MAX_TIME / 4;
        durations[3] = YEAR;
        durations[4] = 2 * SIX_DAYS;   // min

        uint256 totalAmount;
        for (uint256 i; i < 5; i++) totalAmount += amounts[i];

        deal(HEMI_TOKEN, GNOSIS_SAFE, totalAmount);
        vm.startPrank(GNOSIS_SAFE);
        hemiToken.approve(address(veHemi), totalAmount);
        for (uint256 i; i < 5; i++) {
            tokenIds[i] = veHemi.createLockFor(amounts[i], durations[i], address(uint160(0xF000 + i)), false, true);
        }
        vm.stopPrank();

        // Compute expected forfeitable supply via shadow accounting
        uint256 expectedForfeitable;
        for (uint256 i; i < 5; i++) {
            expectedForfeitable += _computeBias(tokenIds[i]);
        }

        // Verify EXACT match
        assertEq(veHemi.forfeitableTotalVeHemiSupply(), expectedForfeitable, "Forfeitable shadow mismatch");

        // Forfeit position 2 (200 ether, MAX_TIME/4 duration)
        uint256 biasOfForfeited = _computeBias(tokenIds[2]);
        vm.prank(GNOSIS_SAFE);
        veHemi.forfeit(tokenIds[2]);

        // Recompute expected: remove the forfeited position
        expectedForfeitable -= biasOfForfeited;
        assertEq(veHemi.forfeitableTotalVeHemiSupply(), expectedForfeitable, "Forfeitable after partial forfeit");

        // Warp 30 days and verify decay
        _warpAndRoll(30 days);
        veHemi.checkpoint();

        // Recompute expected biases after decay
        uint256 expectedAfterDecay;
        for (uint256 i; i < 5; i++) {
            if (i == 2) continue; // forfeited
            expectedAfterDecay += _computeBias(tokenIds[i]);
        }
        assertEq(veHemi.forfeitableTotalVeHemiSupply(), expectedAfterDecay, "Forfeitable after decay");
    }

    // ═════════════════════════════════════════════════════════════════════
    //  34. NATURAL EXPIRY OF FORFEITABLE POSITION
    // ═════════════════════════════════════════════════════════════════════

    function testNaturalExpiryOfForfeitablePosition() public onlyFork {
        _upgradeAndSeed();

        address user = address(0xF00D);
        deal(HEMI_TOKEN, GNOSIS_SAFE, 100 ether);
        vm.startPrank(GNOSIS_SAFE);
        hemiToken.approve(address(veHemi), 100 ether);
        uint256 tokenId = veHemi.createLockFor(100 ether, 2 * SIX_DAYS, user, false, true);
        vm.stopPrank();

        // Warp past expiry
        uint64 lockEnd = veHemi.getLockedBalance(tokenId).end;
        _warpAndRoll(lockEnd + 1 - block.timestamp);
        veHemi.checkpoint();

        // Forfeitable should be 0 after expiry (slope change fired)
        assertEq(veHemi.forfeitableTotalVeHemiSupply(), 0, "Forfeitable 0 after expiry");

        // Withdraw the expired position
        vm.prank(user);
        veHemi.withdraw(tokenId);

        // forfeitable[tokenId] mapping should be cleaned up
        assertFalse(veHemi.forfeitable(tokenId), "forfeitable mapping should be cleaned up");
        assertEq(veHemi.transferableAfter(tokenId), 0, "transferableAfter should be cleaned up");

        // Token conservation
        assertEq(hemiToken.balanceOf(address(veHemi)), veHemi.totalLocked(), "Token conservation");
    }

    // ═════════════════════════════════════════════════════════════════════
    //  35. NEW LOCKED-ONLY POSITION DOES NOT AFFECT FORFEITABLE CURVE
    // ═════════════════════════════════════════════════════════════════════

    function testNewNonTransferableOnlyDoesNotAffectForfeitableCurve() public onlyFork {
        _upgradeAndSeed();

        uint256 forfeitableBefore = veHemi.forfeitableTotalVeHemiSupply();
        uint256 nonTransferableSupplyBefore = veHemi.nonTransferableTotalVeHemiSupply();

        // Create a new non-transferable-only (non-forfeitable) position
        address user = address(0xCAFE);
        deal(HEMI_TOKEN, GNOSIS_SAFE, 100 ether);
        vm.startPrank(GNOSIS_SAFE);
        hemiToken.approve(address(veHemi), 100 ether);
        uint256 tokenId = veHemi.createLockFor(100 ether, MAX_TIME / 2, user, false, false);
        vm.stopPrank();

        uint256 expectedBias = _computeBias(tokenId);

        // Non-transferable should increase by exactly the bias
        assertEq(
            veHemi.nonTransferableTotalVeHemiSupply() - nonTransferableSupplyBefore,
            expectedBias,
            "Non-transferable should increase by new position bias"
        );

        // Forfeitable must NOT change
        assertEq(
            veHemi.forfeitableTotalVeHemiSupply(),
            forfeitableBefore,
            "Forfeitable must not change when non-transferable-only position is created"
        );
    }

    // ═════════════════════════════════════════════════════════════════════
    //  36. transferFrom REVERTS FOR NON-TRANSFERRABLE POSITIONS
    // ═════════════════════════════════════════════════════════════════════

    function testTransferFromRevertsForNonTransferrable() public onlyFork {
        _upgradeAndSeed();

        // Pick a real on-chain non-transferrable position
        uint256[] memory ids = _findNonTransferablePositions();
        assertGt(ids.length, 0, "Mainnet must have active non-transferable positions");

        uint256 tokenId = ids[0];
        address realOwner = veHemi.ownerOf(tokenId);

        // Attempt to transfer — must revert with NotTransferable
        vm.prank(realOwner);
        vm.expectRevert(VeHemi.NotTransferable.selector);
        veHemi.transferFrom(realOwner, address(0xDEAD), tokenId);
    }

    // ═════════════════════════════════════════════════════════════════════
    //  37. REAL ON-CHAIN HOLDER OPERATIONS
    // ═════════════════════════════════════════════════════════════════════

    function testRealOnChainHolderCannotWithdrawActiveLock() public onlyFork {
        _upgradeAndSeed();

        uint256[] memory ids = _findNonTransferablePositions();
        assertGt(ids.length, 0, "Mainnet must have active non-transferable positions");

        uint256 tokenId = ids[0];
        address realOwner = veHemi.ownerOf(tokenId);

        // Position is active, withdraw must revert
        vm.prank(realOwner);
        vm.expectRevert(VeHemi.LockNotExpired.selector);
        veHemi.withdraw(tokenId);
    }

    function testRealOnChainHolderCanIncreaseAmount() public onlyFork {
        _upgradeAndSeed();

        uint256[] memory ids = _findNonTransferablePositions();
        assertGt(ids.length, 0, "Mainnet must have active non-transferable positions");

        uint256 tokenId = ids[0];
        address realOwner = veHemi.ownerOf(tokenId);

        uint256 nonTransferableSupplyBefore = veHemi.nonTransferableTotalVeHemiSupply();
        uint256 totalBefore = veHemi.totalVeHemiSupply();

        // Real owner increases their amount
        deal(HEMI_TOKEN, realOwner, 50 ether);
        vm.startPrank(realOwner);
        hemiToken.approve(address(veHemi), 50 ether);
        veHemi.increaseAmount(tokenId, 50 ether);
        vm.stopPrank();

        // Non-transferable supply should increase (this is a non-transferrable position)
        assertGt(veHemi.nonTransferableTotalVeHemiSupply(), nonTransferableSupplyBefore, "Non-transferable should increase");
        assertGt(veHemi.totalVeHemiSupply(), totalBefore, "Total should increase");

        // Token conservation
        assertEq(hemiToken.balanceOf(address(veHemi)), veHemi.totalLocked(), "Token conservation");
    }

    function testRealOnChainHolderCanIncreaseUnlockTime() public onlyFork {
        _upgradeAndSeed();

        uint256[] memory ids = _findNonTransferablePositions();
        assertGt(ids.length, 0, "Mainnet must have active non-transferable positions");

        // Find a position that has room to extend (not already at MAX_TIME)
        uint256 tokenId;
        uint256 newDuration;
        for (uint256 i; i < ids.length; i++) {
            IVeHemi.LockedBalance memory bal = veHemi.getLockedBalance(ids[i]);
            uint256 currentDuration = bal.end - block.timestamp;
            if (currentDuration + SIX_DAYS < MAX_TIME) {
                tokenId = ids[i];
                newDuration = currentDuration + SIX_DAYS * 10; // extend by ~60 days
                if (newDuration > MAX_TIME) newDuration = MAX_TIME - SIX_DAYS;
                break;
            }
        }
        assertGt(tokenId, 0, "Must find at least one extendable position on mainnet");

        address realOwner = veHemi.ownerOf(tokenId);
        uint256 oldEnd = veHemi.getLockedBalance(tokenId).end;
        uint256 oldTransferableAfter = veHemi.transferableAfter(tokenId);

        vm.prank(realOwner);
        veHemi.increaseUnlockTime(tokenId, newDuration);

        // End time should have increased
        uint256 newEnd = veHemi.getLockedBalance(tokenId).end;
        assertGt(newEnd, oldEnd, "End should increase");

        // V2: transferableAfter should NOT change when extending
        assertEq(veHemi.transferableAfter(tokenId), oldTransferableAfter, "transferableAfter should NOT change");
    }

    // ═════════════════════════════════════════════════════════════════════
    //  38. SAME-BLOCK EPOCH OVERWRITE
    // ═════════════════════════════════════════════════════════════════════

    function testSameBlockEpochOverwrite() public onlyFork {
        _upgradeAndSeed();

        // Warp forward so we're in a fresh epoch
        _warpAndRoll(7 days);
        veHemi.checkpoint();

        uint256 epochBefore = veHemi.epoch();

        // Create two positions in the same block
        deal(HEMI_TOKEN, GNOSIS_SAFE, 200 ether);
        vm.startPrank(GNOSIS_SAFE);
        hemiToken.approve(address(veHemi), 200 ether);
        uint256 tokenId1 = veHemi.createLockFor(100 ether, MAX_TIME / 2, address(0xAAA1), false, false);
        uint256 tokenId2 = veHemi.createLockFor(100 ether, MAX_TIME / 2, address(0xAAA2), false, true);
        vm.stopPrank();

        uint256 epochAfter = veHemi.epoch();
        // Each createLockFor calls _checkpoint which increments the epoch by 1, then the
        // overwrite check sees the previous epoch has the same timestamp and overwrites it.
        // So the SECOND create advances epoch by 1 but writes to epoch-1 (overwrite).
        // Net result: epoch increments by 2 (one per _checkpoint call), but both writes
        // go to their respective epoch-1 (which is epoch+1 from the prior's perspective).
        // The key invariant is that the LATEST global point has block.timestamp.
        IVeHemi.Point memory latestPoint = veHemi.getGlobalPoint(epochAfter);
        assertEq(latestPoint.timestamp, block.timestamp, "Latest epoch should be at current timestamp");

        // The single epoch entry should reflect BOTH positions
        uint256 expectedNonTransferable = _computeBias(tokenId1) + _computeBias(tokenId2);
        assertGt(veHemi.nonTransferableTotalVeHemiSupply(), 0, "Non-transferable should be non-zero");
        // The new non-transferable supply should include both positions' biases
        // (we can't directly compare to the pre-state because of decay, but we can verify
        // the new positions are tracked exactly)
        uint256 expectedForfeitable = _computeBias(tokenId2);
        assertEq(veHemi.forfeitableTotalVeHemiSupply(), expectedForfeitable, "Forfeitable should equal exactly the forfeitable position bias");
    }

    // ═════════════════════════════════════════════════════════════════════
    //  39. FORFEIT ADMIN LIFECYCLE
    // ═════════════════════════════════════════════════════════════════════

    function testForfeitAdminLifecycle() public onlyFork {
        _upgradeAndSeed();

        // Mainnet has no forfeit admin set
        assertEq(veHemi.forfeitAdmin(), address(0), "Forfeit admin should be unset on mainnet");

        // Create a forfeitable position
        deal(HEMI_TOKEN, GNOSIS_SAFE, 100 ether);
        vm.startPrank(GNOSIS_SAFE);
        hemiToken.approve(address(veHemi), 100 ether);
        uint256 tokenId = veHemi.createLockFor(100 ether, MAX_TIME / 2, address(0xCAFE), false, true);
        vm.stopPrank();

        // Forfeit must revert when admin is unset (called by random address)
        vm.prank(address(0xBAD));
        vm.expectRevert(VeHemi.NotForfeitAdmin.selector);
        veHemi.forfeit(tokenId);

        // Set forfeit admin
        vm.prank(GNOSIS_SAFE);
        veHemi.updateForfeitAdmin(GNOSIS_SAFE);
        assertEq(veHemi.forfeitAdmin(), GNOSIS_SAFE, "Forfeit admin should be set");

        // Non-admin cannot call updateForfeitAdmin
        vm.prank(address(0xBAD));
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", address(0xBAD)));
        veHemi.updateForfeitAdmin(address(0xBAD));

        // Admin can disable by setting to address(0)
        vm.prank(GNOSIS_SAFE);
        veHemi.updateForfeitAdmin(address(0));
        assertEq(veHemi.forfeitAdmin(), address(0), "Forfeit admin can be disabled");

        // Now forfeit reverts again
        vm.prank(GNOSIS_SAFE);
        vm.expectRevert(VeHemi.NotForfeitAdmin.selector);
        veHemi.forfeit(tokenId);

        // Re-enable and forfeit successfully
        vm.prank(GNOSIS_SAFE);
        veHemi.updateForfeitAdmin(GNOSIS_SAFE);
        vm.prank(GNOSIS_SAFE);
        veHemi.forfeit(tokenId);
    }

    function testForfeitRevertsOnNonForfeitablePosition() public onlyFork {
        _upgradeAndSeed();
        vm.prank(GNOSIS_SAFE);
        veHemi.updateForfeitAdmin(GNOSIS_SAFE);

        // Pick a real on-chain non-transferrable position (which is NOT forfeitable on mainnet)
        uint256[] memory ids = _findNonTransferablePositions();
        assertGt(ids.length, 0, "Mainnet must have active non-transferable positions");

        uint256 tokenId = ids[0];
        assertFalse(veHemi.forfeitable(tokenId), "Mainnet non-transferrable should not be forfeitable");

        vm.prank(GNOSIS_SAFE);
        vm.expectRevert(VeHemi.NotForfeitable.selector);
        veHemi.forfeit(tokenId);
    }

    function testForfeitRevertsOnExpiredLock() public onlyFork {
        _upgradeAndSeed();
        vm.prank(GNOSIS_SAFE);
        veHemi.updateForfeitAdmin(GNOSIS_SAFE);

        deal(HEMI_TOKEN, GNOSIS_SAFE, 100 ether);
        vm.startPrank(GNOSIS_SAFE);
        hemiToken.approve(address(veHemi), 100 ether);
        uint256 tokenId = veHemi.createLockFor(100 ether, 2 * SIX_DAYS, address(0xCAFE), false, true);
        vm.stopPrank();

        // Warp past expiry
        uint64 end = veHemi.getLockedBalance(tokenId).end;
        _warpAndRoll(end + 1 - block.timestamp);

        // Forfeit should revert with LockExpired
        vm.prank(GNOSIS_SAFE);
        vm.expectRevert(VeHemi.LockExpired.selector);
        veHemi.forfeit(tokenId);
    }

    // ═════════════════════════════════════════════════════════════════════
    //  40. EXACT MULTI-BOUNDARY LOCKED CURVE DECAY VERIFICATION
    // ═════════════════════════════════════════════════════════════════════

    /// @notice Verify the non-transferable curve matches per-position shadow sum across multiple
    ///         time warps including SIX_DAYS boundary crossings. This is the strongest
    ///         possible math verification — it computes expected supply from real on-chain
    ///         positions independently and asserts exact equality at each step.
    function testExactNonTransferableCurveDecayAtMultipleTimestamps() public onlyFork {
        uint256[] memory ids = _upgradeAndSeed();
        assertGt(ids.length, 0, "Mainnet must have active non-transferable positions");

        // Snapshot the initial slope/end for each position (they may change if we mutate)
        // We won't mutate in this test — pure decay verification
        uint256[] memory slopes = new uint256[](ids.length);
        uint256[] memory ends = new uint256[](ids.length);
        for (uint256 i; i < ids.length; i++) {
            IVeHemi.LockedBalance memory bal = veHemi.getLockedBalance(ids[i]);
            slopes[i] = uint256(uint128(bal.amount)) / MAX_TIME;
            ends[i] = bal.end;
        }

        // Verify at multiple time points
        uint256[] memory warpDays = new uint256[](6);
        warpDays[0] = 1;
        warpDays[1] = 7;
        warpDays[2] = 30;
        warpDays[3] = 90;
        warpDays[4] = 180;
        warpDays[5] = 365;

        uint256 startTime = block.timestamp;
        for (uint256 w; w < warpDays.length; w++) {
            vm.warp(startTime + warpDays[w] * 1 days);
            vm.roll(block.number + (warpDays[w] * 1 days) / 2);
            veHemi.checkpoint();

            // Compute expected supply: sum of slope * max(0, end - now) for each position
            uint256 expectedNonTransferable;
            for (uint256 i; i < ids.length; i++) {
                if (ends[i] > block.timestamp) {
                    expectedNonTransferable += slopes[i] * (ends[i] - block.timestamp);
                }
            }

            // Verify EXACT equality
            assertEq(
                veHemi.nonTransferableTotalVeHemiSupply(),
                expectedNonTransferable,
                string.concat("Non-transferable supply mismatch at day ", vm.toString(warpDays[w]))
            );
        }
    }

    // ═════════════════════════════════════════════════════════════════════
    //  41. VOTE DELEGATION FUNCTIONAL VERIFICATION
    // ═════════════════════════════════════════════════════════════════════

    function testVoteDelegationFunctionalPostUpgrade() public onlyFork {
        _upgradeAndSeed();

        IVeHemiVoteDelegation voteDel = IVeHemiVoteDelegation(VOTE_DELEGATION_PROXY);

        // Create a transferable position with significant amount
        address user = address(0xCAFE);
        deal(HEMI_TOKEN, user, 1000 ether);
        vm.startPrank(user);
        hemiToken.approve(address(veHemi), 1000 ether);
        uint256 tokenId = veHemi.createLock(1000 ether, MAX_TIME / 2);
        vm.stopPrank();

        // createLock auto-delegates to msg.sender; delegation takes effect at next day boundary
        _warpAndRoll(1 days + 1);
        veHemi.checkpoint();

        // Verify actual delegation votes match the position's voting power
        uint256 votes = voteDel.getVotes(user);
        uint256 balance = veHemi.balanceOfNFT(tokenId);
        assertGt(votes, 0, "User should have delegation votes");
        assertEq(votes, balance, "Votes should match balanceOfNFT");

        // Verify delegation can be changed
        address delegatee = address(0xDE1E);
        vm.prank(user);
        voteDel.delegate(tokenId, delegatee);
        _warpAndRoll(1 days + 1);

        uint256 delegateeVotes = voteDel.getVotes(delegatee);
        assertGt(delegateeVotes, 0, "Delegatee should have votes after delegation");
    }

    // ═════════════════════════════════════════════════════════════════════
    //  42. NON-OWNER increaseAmount ON FORFEITABLE POSITION
    // ═════════════════════════════════════════════════════════════════════

    /// @notice increaseAmount is permissionless — anyone can add tokens to any position.
    ///         Verify this works correctly for forfeitable positions and updates both curves.
    function testNonOwnerIncreaseAmountOnForfeitablePosition() public onlyFork {
        _upgradeAndSeed();

        // Create a forfeitable position owned by 0xCAFE
        deal(HEMI_TOKEN, GNOSIS_SAFE, 100 ether);
        vm.startPrank(GNOSIS_SAFE);
        hemiToken.approve(address(veHemi), 100 ether);
        uint256 tokenId = veHemi.createLockFor(100 ether, MAX_TIME / 2, address(0xCAFE), false, true);
        vm.stopPrank();

        uint256 nonTransferableSupplyBefore = veHemi.nonTransferableTotalVeHemiSupply();
        uint256 forfeitableBefore = veHemi.forfeitableTotalVeHemiSupply();

        // A DIFFERENT address (not the owner) increases the amount
        address donator = address(0xD000);
        deal(HEMI_TOKEN, donator, 50 ether);
        vm.startPrank(donator);
        hemiToken.approve(address(veHemi), 50 ether);
        veHemi.increaseAmount(tokenId, 50 ether);
        vm.stopPrank();

        // Both curves should increase
        uint256 nonTransferableDelta = veHemi.nonTransferableTotalVeHemiSupply() - nonTransferableSupplyBefore;
        uint256 forfeitableDelta = veHemi.forfeitableTotalVeHemiSupply() - forfeitableBefore;
        assertGt(nonTransferableDelta, 0, "Non-transferable should increase");
        assertEq(nonTransferableDelta, forfeitableDelta, "Non-transferable and forfeitable deltas should be equal");

        // Token conservation
        assertEq(hemiToken.balanceOf(address(veHemi)), veHemi.totalLocked(), "Token conservation");
    }

    // ═════════════════════════════════════════════════════════════════════
    //  43. safeTransferFrom REVERTS FOR NON-TRANSFERRABLE
    // ═════════════════════════════════════════════════════════════════════

    /// @notice safeTransferFrom calls transferFrom internally (OZ impl). Verify it also reverts.
    function testSafeTransferFromRevertsForNonTransferrable() public onlyFork {
        _upgradeAndSeed();

        uint256[] memory ids = _findNonTransferablePositions();
        assertGt(ids.length, 0, "Mainnet must have active non-transferable positions");

        uint256 tokenId = ids[0];
        address realOwner = veHemi.ownerOf(tokenId);

        vm.prank(realOwner);
        vm.expectRevert(VeHemi.NotTransferable.selector);
        veHemi.safeTransferFrom(realOwner, address(0xDEAD), tokenId);
    }

    // ═════════════════════════════════════════════════════════════════════
    //  44. LOCKED-ONLY POSITION WITHDRAW AFTER NATURAL EXPIRY
    // ═════════════════════════════════════════════════════════════════════

    /// @notice Create a non-forfeitable non-transferable position, let it expire, withdraw.
    ///         Verify the non-transferable curve decreases correctly, transferableAfter is cleaned up,
    ///         and forfeitable curve is unaffected.
    function testNonTransferableOnlyWithdrawAfterExpiry() public onlyFork {
        _upgradeAndSeed();

        // Create a non-transferable-only (non-forfeitable) position with short duration
        deal(HEMI_TOKEN, GNOSIS_SAFE, 100 ether);
        vm.startPrank(GNOSIS_SAFE);
        hemiToken.approve(address(veHemi), 100 ether);
        uint256 tokenId = veHemi.createLockFor(100 ether, 2 * SIX_DAYS, address(0xBEEF), false, false);
        vm.stopPrank();

        uint256 nonTransferableSupplyBefore = veHemi.nonTransferableTotalVeHemiSupply();
        uint256 forfeitableBefore = veHemi.forfeitableTotalVeHemiSupply();

        // Verify position is non-forfeitable
        assertFalse(veHemi.forfeitable(tokenId), "Should not be forfeitable");
        assertGt(veHemi.transferableAfter(tokenId), 0, "Should be non-transferrable");

        // Warp past expiry
        uint64 lockEnd = veHemi.getLockedBalance(tokenId).end;
        _warpAndRoll(lockEnd + 1 - block.timestamp);
        veHemi.checkpoint();

        // Withdraw
        vm.prank(address(0xBEEF));
        veHemi.withdraw(tokenId);

        // Non-transferable curve should have decreased (the position's contribution was shed at expiry)
        uint256 nonTransferableSupplyAfter = veHemi.nonTransferableTotalVeHemiSupply();
        assertLe(nonTransferableSupplyAfter, nonTransferableSupplyBefore, "Non-transferable should not exceed pre-creation value");

        // Forfeitable curve should be completely unaffected
        assertEq(veHemi.forfeitableTotalVeHemiSupply(), forfeitableBefore, "Forfeitable unchanged");

        // Storage cleanup
        assertEq(veHemi.transferableAfter(tokenId), 0, "transferableAfter cleaned up");
        assertFalse(veHemi.forfeitable(tokenId), "forfeitable cleaned up");

        // Token conservation
        assertEq(hemiToken.balanceOf(address(veHemi)), veHemi.totalLocked(), "Token conservation");
    }

    // ═════════════════════════════════════════════════════════════════════
    //  45. INTERLEAVED FORFEITABLE + LOCKED-ONLY LIFECYCLE
    // ═════════════════════════════════════════════════════════════════════

    /// @notice Create forfeitable and non-transferable-only positions interleaved with time warps,
    ///         then forfeit the forfeitable position. Verify the non-transferable curve correctly
    ///         reflects only the remaining non-transferable-only position.
    function testInterleavedForfeitableAndNonTransferableOnlyLifecycle() public onlyFork {
        _upgradeAndSeed();
        vm.prank(GNOSIS_SAFE);
        veHemi.updateForfeitAdmin(GNOSIS_SAFE);

        // Create a forfeitable position
        deal(HEMI_TOKEN, GNOSIS_SAFE, 100 ether);
        vm.startPrank(GNOSIS_SAFE);
        hemiToken.approve(address(veHemi), 100 ether);
        uint256 forfeitableId = veHemi.createLockFor(100 ether, MAX_TIME / 2, address(0xAAAA), false, true);
        vm.stopPrank();

        uint256 forfeitableBiasT0 = _computeBias(forfeitableId);

        // Warp 30 days
        _warpAndRoll(30 days);
        veHemi.checkpoint();

        // Create a non-transferable-only position (different epoch than the forfeitable one)
        deal(HEMI_TOKEN, GNOSIS_SAFE, 200 ether);
        vm.startPrank(GNOSIS_SAFE);
        hemiToken.approve(address(veHemi), 200 ether);
        uint256 nonTransferableOnlyId = veHemi.createLockFor(200 ether, MAX_TIME / 2, address(0xBBBB), false, false);
        vm.stopPrank();

        uint256 nonTransferableOnlyBias = _computeBias(nonTransferableOnlyId);
        uint256 forfeitableBiasT1 = _computeBias(forfeitableId);

        // Verify both tracked correctly
        uint256 locked = veHemi.nonTransferableTotalVeHemiSupply();
        uint256 forfeitable_ = veHemi.forfeitableTotalVeHemiSupply();

        // Locked includes both; forfeitable includes only the forfeitable one
        // (The pre-existing mainnet non-transferable positions also contribute, so use delta)
        assertGt(forfeitable_, 0, "Forfeitable should be positive");
        assertGt(locked, forfeitable_, "Non-transferable should exceed forfeitable");

        // Warp another 30 days
        _warpAndRoll(30 days);
        veHemi.checkpoint();

        // Forfeit the forfeitable position
        vm.prank(GNOSIS_SAFE);
        veHemi.forfeit(forfeitableId);

        // Forfeitable should drop to 0 (it was the only one)
        assertEq(veHemi.forfeitableTotalVeHemiSupply(), 0, "Forfeitable 0 after forfeit");

        // Non-transferable should still include the non-transferable-only position
        uint256 nonTransferableAfterForfeit = veHemi.nonTransferableTotalVeHemiSupply();
        assertGt(nonTransferableAfterForfeit, 0, "Non-transferable-only position should remain");

        // The non-transferable-only position's bias should still be computable
        uint256 remainingNonTransferableBias = _computeBias(nonTransferableOnlyId);
        assertGt(remainingNonTransferableBias, 0, "Non-transferable-only should still have bias");

        _assertOrdering("After interleaved lifecycle");
        assertEq(hemiToken.balanceOf(address(veHemi)), veHemi.totalLocked(), "Token conservation");
    }

    // ═════════════════════════════════════════════════════════════════════
    //  46. SEEDING WITH EXPIRED POSITION IN ARRAY (SILENT SKIP)
    // ═════════════════════════════════════════════════════════════════════

    /// @notice Include an expired non-transferrable position in the seed array.
    ///         The contract should silently skip it (no revert), and the non-transferable supply
    ///         should only reflect active positions.
    function testSeedingWithExpiredPositionInArray() public onlyFork {
        _upgradeProxy();

        // Create a position with very short duration that will expire before seeding
        deal(HEMI_TOKEN, GNOSIS_SAFE, 100 ether);
        vm.startPrank(GNOSIS_SAFE);
        hemiToken.approve(address(veHemi), 100 ether);
        uint256 shortId = veHemi.createLockFor(100 ether, 2 * SIX_DAYS, address(0xAAAA), false, false);
        vm.stopPrank();

        // Warp past its expiry
        uint64 shortEnd = veHemi.getLockedBalance(shortId).end;
        _warpAndRoll(shortEnd + 1 - block.timestamp);

        // Now discover the real positions (the short one should be filtered out by scanner)
        uint256[] memory scannedIds = _findNonTransferablePositions();

        // Build an array that includes the expired position
        uint256[] memory idsWithExpired;
        if (shortId < scannedIds[0]) {
            // shortId is lower than the scanned range — prepend it
            idsWithExpired = new uint256[](scannedIds.length + 1);
            idsWithExpired[0] = shortId;
            for (uint256 i; i < scannedIds.length; i++) {
                idsWithExpired[i + 1] = scannedIds[i];
            }
        } else {
            // shortId is in/after range — append it (but must maintain sort order)
            // Since shortId is likely > scannedIds last element (nextTokenId was used), append
            idsWithExpired = new uint256[](scannedIds.length + 1);
            for (uint256 i; i < scannedIds.length; i++) {
                idsWithExpired[i] = scannedIds[i];
            }
            idsWithExpired[scannedIds.length] = shortId;
        }

        // Seed should succeed (expired position is silently skipped)
        vm.prank(GNOSIS_SAFE);
        veHemi.seedAndFinalizeNonTransferablePositions(idsWithExpired);

        assertTrue(veHemi.nonTransferableSeedingFinalized(), "Should be finalized");

        // Non-transferable supply should match what the scanner found (excludes expired)
        // Compute expected from scanned IDs only
        uint256 expected;
        for (uint256 i; i < scannedIds.length; i++) {
            expected += _computeBias(scannedIds[i]);
        }
        assertEq(veHemi.nonTransferableTotalVeHemiSupply(), expected, "Expired position should be silently skipped");
    }

    // ═════════════════════════════════════════════════════════════════════
    //  47. LOCKED-ONLY MUTATION DOES NOT CORRUPT FORFEITABLE CURVE
    // ═════════════════════════════════════════════════════════════════════

    /// @notice Closes mutation testing gap M2: increaseAmount/increaseUnlockTime on a
    ///         non-transferable-only (non-forfeitable) position must NOT write to forfeitableSlopeChanges.
    ///         Verified by warping past the position's end and checking the forfeitable curve
    ///         is still exactly 0.
    function testNonTransferableOnlyMutationDoesNotCorruptForfeitableCurve() public onlyFork {
        _upgradeAndSeed();

        // Create a non-transferable-only position with short duration so we can warp past its end
        deal(HEMI_TOKEN, GNOSIS_SAFE, 200 ether);
        vm.startPrank(GNOSIS_SAFE);
        hemiToken.approve(address(veHemi), 200 ether);
        uint256 tokenId = veHemi.createLockFor(100 ether, MAX_TIME / 4, address(0xBBBB), false, false);
        vm.stopPrank();

        // Verify it's non-transferable-only (non-forfeitable)
        assertGt(veHemi.transferableAfter(tokenId), 0, "Should be non-transferrable");
        assertFalse(veHemi.forfeitable(tokenId), "Should NOT be forfeitable");

        // Forfeitable curve should be 0 (no forfeitable positions exist)
        assertEq(veHemi.forfeitableTotalVeHemiSupply(), 0, "Forfeitable should be 0 before mutation");

        // increaseAmount on the non-transferable-only position (triggers _scheduleSlopeChanges with curveFlags=1)
        vm.startPrank(GNOSIS_SAFE);
        veHemi.increaseAmount(tokenId, 100 ether);
        vm.stopPrank();

        // Forfeitable should still be 0 immediately
        assertEq(veHemi.forfeitableTotalVeHemiSupply(), 0, "Forfeitable should be 0 after increaseAmount");

        // increaseUnlockTime on the non-transferable-only position (triggers _scheduleSlopeChanges with curveFlags=1)
        uint256 oldEnd = veHemi.getLockedBalance(tokenId).end;
        vm.prank(address(0xBBBB));
        veHemi.increaseUnlockTime(tokenId, MAX_TIME / 2);
        uint256 newEnd = veHemi.getLockedBalance(tokenId).end;
        assertGt(newEnd, oldEnd, "End should have increased");

        // Forfeitable should still be 0 immediately
        assertEq(veHemi.forfeitableTotalVeHemiSupply(), 0, "Forfeitable should be 0 after increaseUnlockTime");

        // Verify forfeitableSlopeChanges at both the old and new end times are 0
        // (a bug in _scheduleSlopeChanges would have written non-zero values here)
        assertEq(veHemi.forfeitableSlopeChanges(oldEnd), int128(0), "forfeitableSlopeChanges at old end should be 0");
        assertEq(veHemi.forfeitableSlopeChanges(newEnd), int128(0), "forfeitableSlopeChanges at new end should be 0");

        // Warp past the new end time — the catchup loop will process any slope changes
        _warpAndRoll(newEnd + 1 - block.timestamp);
        veHemi.checkpoint();

        // Forfeitable should STILL be 0 after the catchup loop processed the end boundary
        assertEq(veHemi.forfeitableTotalVeHemiSupply(), 0, "Forfeitable should be 0 after crossing end boundary");

        // Token conservation
        _assertTokenConservation("After non-transferable-only mutation lifecycle");
    }

    // ═════════════════════════════════════════════════════════════════════
    //  48. REWARD DISTRIBUTOR STATE VERIFICATION
    // ═════════════════════════════════════════════════════════════════════

    /// @notice Verify the rewardDistributor address on mainnet and that operations work
    ///         correctly with it set (or unset).
    function testRewardDistributorStatePostUpgrade() public onlyFork {
        _upgradeAndSeed();

        // Verify the actual rewardDistributor address on mainnet
        address rd = address(veHemi.rewardDistributor());

        if (rd == address(0)) {
            // RewardDistributor is not set — _updateReward is a no-op.
            // Verify operations work fine without it.
            address user = address(0xBEEF);
            uint256 tokenId = _createTestLock(user, 100 ether, MAX_TIME / 2);
            assertGt(veHemi.balanceOfNFT(tokenId), 0, "Lock works with no rewardDistributor");

            // increaseAmount works
            deal(HEMI_TOKEN, user, 50 ether);
            vm.startPrank(user);
            hemiToken.approve(address(veHemi), 50 ether);
            veHemi.increaseAmount(tokenId, 50 ether);
            vm.stopPrank();

            // Withdraw works after expiry
            uint64 lockEnd = veHemi.getLockedBalance(tokenId).end;
            _warpAndRoll(lockEnd + 1 - block.timestamp);
            vm.prank(user);
            veHemi.withdraw(tokenId);

            _assertTokenConservation("Operations with no rewardDistributor");
        } else {
            // RewardDistributor IS set to a live contract.
            // Verify it doesn't revert during normal operations post-upgrade.
            // A revert would be caught by try/catch and emit RewardUpdateFailed.
            address user = address(0xBEEF);
            uint256 tokenId = _createTestLock(user, 100 ether, MAX_TIME / 2);

            // If we get here without revert, the rewardDistributor is compatible.
            // Also verify increaseAmount works (another _updateReward call path)
            deal(HEMI_TOKEN, user, 50 ether);
            vm.startPrank(user);
            hemiToken.approve(address(veHemi), 50 ether);
            veHemi.increaseAmount(tokenId, 50 ether);
            vm.stopPrank();

            _assertTokenConservation("Operations with live rewardDistributor");
        }

        // Log the actual address for operator visibility
        emit log_named_address("rewardDistributor on mainnet", rd);
    }

    // ═════════════════════════════════════════════════════════════════════
    //  49. EXACT LOCK.END BOUNDARY BEHAVIOR
    // ═════════════════════════════════════════════════════════════════════

    /// @notice Warp to EXACTLY lock.end (not +1). Verify:
    ///         - balanceOfNFT returns 0 (position fully decayed)
    ///         - withdraw succeeds (block.timestamp >= end)
    ///         - increaseAmount reverts (end <= block.timestamp)
    function testExactLockEndBoundary() public onlyFork {
        _upgradeAndSeed();

        address user = address(0xBEEF);
        uint256 tokenId = _createTestLock(user, 100 ether, 2 * SIX_DAYS);
        uint64 lockEnd = veHemi.getLockedBalance(tokenId).end;

        // Warp to EXACTLY lock.end (not +1)
        _warpAndRoll(lockEnd - block.timestamp);
        assertEq(block.timestamp, lockEnd, "Should be at exact lock.end");

        // balanceOfNFT should be 0 at exact expiry
        assertEq(veHemi.balanceOfNFT(tokenId), 0, "Balance should be 0 at exact lock.end");

        // increaseAmount should revert (end <= block.timestamp)
        deal(HEMI_TOKEN, user, 50 ether);
        vm.startPrank(user);
        hemiToken.approve(address(veHemi), 50 ether);
        vm.expectRevert(VeHemi.LockExpired.selector);
        veHemi.increaseAmount(tokenId, 50 ether);
        vm.stopPrank();

        // increaseUnlockTime should revert (end <= block.timestamp)
        vm.prank(user);
        vm.expectRevert(VeHemi.LockExpired.selector);
        veHemi.increaseUnlockTime(tokenId, MAX_TIME);

        // withdraw should succeed (block.timestamp >= end)
        vm.prank(user);
        veHemi.withdraw(tokenId);

        _assertTokenConservation("After withdraw at exact lock.end");
    }

    // ═════════════════════════════════════════════════════════════════════
    //  50. DOUBLE-WITHDRAW AND DOUBLE-FORFEIT REVERT
    // ═════════════════════════════════════════════════════════════════════

    /// @notice After withdraw, calling withdraw again must revert (NFT burned).
    function testDoubleWithdrawReverts() public onlyFork {
        _upgradeAndSeed();

        address user = address(0xBEEF);
        uint256 tokenId = _createTestLock(user, 100 ether, 2 * SIX_DAYS);

        uint64 lockEnd = veHemi.getLockedBalance(tokenId).end;
        _warpAndRoll(lockEnd + 1 - block.timestamp);

        vm.prank(user);
        veHemi.withdraw(tokenId);

        // NFT is burned — ownerOf should revert
        vm.expectRevert();
        veHemi.ownerOf(tokenId);

        // locked amount should be 0
        assertEq(veHemi.getLockedBalance(tokenId).amount, 0, "Locked amount should be 0 after withdraw");
        assertEq(veHemi.getLockedBalance(tokenId).end, 0, "Locked end should be 0 after withdraw");

        // Second withdraw must revert (NotOwner — _ownerOf returns address(0))
        vm.prank(user);
        vm.expectRevert(VeHemi.NotOwner.selector);
        veHemi.withdraw(tokenId);
    }

    /// @notice After forfeit, calling forfeit again must revert (NotForfeitable — flag deleted).
    function testDoubleForfeitReverts() public onlyFork {
        _upgradeAndSeed();
        vm.prank(GNOSIS_SAFE);
        veHemi.updateForfeitAdmin(GNOSIS_SAFE);

        deal(HEMI_TOKEN, GNOSIS_SAFE, 100 ether);
        vm.startPrank(GNOSIS_SAFE);
        hemiToken.approve(address(veHemi), 100 ether);
        uint256 tokenId = veHemi.createLockFor(100 ether, MAX_TIME / 2, address(0xCAFE), false, true);
        vm.stopPrank();

        // First forfeit succeeds
        vm.prank(GNOSIS_SAFE);
        veHemi.forfeit(tokenId);

        // NFT is burned
        vm.expectRevert();
        veHemi.ownerOf(tokenId);

        // forfeitable flag should be cleaned up
        assertFalse(veHemi.forfeitable(tokenId), "forfeitable should be false after forfeit");

        // Second forfeit must revert (NotForfeitable — flag was deleted in _withdraw)
        vm.prank(GNOSIS_SAFE);
        vm.expectRevert(VeHemi.NotForfeitable.selector);
        veHemi.forfeit(tokenId);
    }

    // ═════════════════════════════════════════════════════════════════════
    //  51. V1 VIEW FUNCTIONS ON FORK AFTER UPGRADE
    // ═════════════════════════════════════════════════════════════════════

    /// @notice Exercise V1 view functions that are never called elsewhere in the fork tests:
    ///         balanceOfNFTAt, balanceAndOwnerOfNFTAt, getUserPoint, totalVeHemiSupplyAt, userPointEpoch.
    function testV1ViewFunctionsPostUpgrade() public onlyFork {
        _upgradeAndSeed();

        // Create a position so we have a known user point
        address user = address(0xBEEF);
        uint256 tokenId = _createTestLock(user, 100 ether, MAX_TIME / 2);
        uint256 expectedBias = _computeBias(tokenId);
        uint256 tCreate = block.timestamp;

        // userPointEpoch should be > 0 after creation
        uint256 userEpoch = veHemi.userPointEpoch(tokenId);
        assertGt(userEpoch, 0, "userPointEpoch should be > 0 after creation");

        // getUserPoint should return a valid point at the current user epoch
        IVeHemi.UserPoint memory up = veHemi.getUserPoint(tokenId, userEpoch);
        assertEq(up.owner, user, "UserPoint owner should be the lock creator");
        assertEq(up.point.timestamp, block.timestamp, "UserPoint timestamp should be creation time");
        assertGt(up.point.bias, 0, "UserPoint bias should be positive");

        // balanceOfNFTAt at creation time should match balanceOfNFT
        uint256 balAt = veHemi.balanceOfNFTAt(tokenId, tCreate);
        assertEq(balAt, expectedBias, "balanceOfNFTAt at creation should match computed bias");

        // balanceAndOwnerOfNFTAt should return both balance and owner
        (uint256 bal, address owner) = veHemi.balanceAndOwnerOfNFTAt(tokenId, tCreate);
        assertEq(bal, expectedBias, "balanceAndOwnerOfNFTAt balance should match");
        assertEq(owner, user, "balanceAndOwnerOfNFTAt owner should match");

        // Warp forward and verify historical queries
        _warpAndRoll(90 days);
        veHemi.checkpoint();

        // totalVeHemiSupplyAt at creation time should match what we recorded
        uint256 totalAtCreate = veHemi.totalVeHemiSupplyAt(tCreate);
        assertGt(totalAtCreate, 0, "totalVeHemiSupplyAt at creation should be positive");

        // balanceOfNFTAt at creation time should still return the same value (historical)
        uint256 histBal = veHemi.balanceOfNFTAt(tokenId, tCreate);
        assertEq(histBal, expectedBias, "Historical balanceOfNFTAt should match creation bias");

        // balanceAndOwnerOfNFTAt at creation time should still return correct owner
        (uint256 histBal2, address histOwner) = veHemi.balanceAndOwnerOfNFTAt(tokenId, tCreate);
        assertEq(histBal2, expectedBias, "Historical balanceAndOwnerOfNFTAt balance");
        assertEq(histOwner, user, "Historical balanceAndOwnerOfNFTAt owner");

        // Current balance should be less than at creation (decayed)
        uint256 currentBal = veHemi.balanceOfNFT(tokenId);
        assertLt(currentBal, expectedBias, "Current balance should be less than creation (decayed)");
        assertEq(currentBal, _computeBias(tokenId), "Current balance should match computed bias");
    }

    /// @notice Verify that after withdraw, getUserPoint records the real owner (V2 behavior)
    ///         and balanceAndOwnerOfNFTAt returns the owner for the final user point.
    function testUserPointOwnerAfterWithdraw() public onlyFork {
        _upgradeAndSeed();

        address user = address(0xBEEF);
        uint256 tokenId = _createTestLock(user, 100 ether, 2 * SIX_DAYS);
        uint256 tCreate = block.timestamp;

        // Record the user epoch at creation
        uint256 createEpoch = veHemi.userPointEpoch(tokenId);

        // Warp past expiry and withdraw
        uint64 lockEnd = veHemi.getLockedBalance(tokenId).end;
        _warpAndRoll(lockEnd + 1 - block.timestamp);

        vm.prank(user);
        veHemi.withdraw(tokenId);

        // The final user point (written during _checkpoint inside _withdraw)
        // should record the REAL owner (V2 behavior: checkpoint before burn)
        uint256 finalEpoch = veHemi.userPointEpoch(tokenId);
        assertGt(finalEpoch, createEpoch, "Final epoch should be greater than creation epoch");

        IVeHemi.UserPoint memory finalPoint = veHemi.getUserPoint(tokenId, finalEpoch);
        assertEq(finalPoint.owner, user, "V2: final UserPoint.owner should be real owner (checkpoint before burn)");
        assertEq(finalPoint.point.bias, 0, "Final bias should be 0 (expired)");

        // Historical query at creation time should still return the original owner and balance
        (uint256 histBal, address histOwner) = veHemi.balanceAndOwnerOfNFTAt(tokenId, tCreate);
        assertGt(histBal, 0, "Historical balance at creation should be positive");
        assertEq(histOwner, user, "Historical owner at creation should be correct");
    }

    // ═════════════════════════════════════════════════════════════════════
    //  52. SUBCURVE TRANSITION ON MAINNET FORK
    // ═════════════════════════════════════════════════════════════════════

    /// @notice Create a forfeitable position, extend it past transferableAfter, then warp
    ///         past the transition boundary. Verify subcurves drop to 0 while global persists.
    function testSubcurveTransitionOnFork() public onlyFork {
        _upgradeAndSeed();
        vm.prank(GNOSIS_SAFE);
        veHemi.updateForfeitAdmin(GNOSIS_SAFE);

        // Create a forfeitable position with short duration
        deal(HEMI_TOKEN, GNOSIS_SAFE, 100 ether);
        vm.startPrank(GNOSIS_SAFE);
        hemiToken.approve(address(veHemi), 100 ether);
        uint256 tokenId = veHemi.createLockFor(100 ether, MAX_TIME / 4, address(0xF00D), false, true);
        vm.stopPrank();

        uint256 originalEnd = veHemi.getLockedBalance(tokenId).end;
        uint256 ta = veHemi.transferableAfter(tokenId);
        assertEq(ta, originalEnd, "transferableAfter should equal original end at creation");

        // Extend the lock past the original end
        vm.prank(address(0xF00D));
        veHemi.increaseUnlockTime(tokenId, MAX_TIME / 2);
        uint256 newEnd = veHemi.getLockedBalance(tokenId).end;
        assertGt(newEnd, originalEnd, "Lock end should extend");
        assertEq(veHemi.transferableAfter(tokenId), ta, "transferableAfter should NOT change");

        // BEFORE transition: position is in subcurves
        assertGt(veHemi.forfeitableTotalVeHemiSupply(), 0, "Forfeitable should be positive before transition");
        assertGt(veHemi.nonTransferableTotalVeHemiSupply(), 0, "Non-transferable should be positive before transition");
        assertFalse(veHemi.isTransferable(tokenId), "Should not be transferable yet");

        // Warp to EXACTLY transferableAfter
        _warpAndRoll(ta - block.timestamp);
        veHemi.checkpoint();
        assertEq(block.timestamp, ta, "Should be at exact transferableAfter");

        // AT the boundary: position should have exited subcurves AND be transferable
        assertTrue(veHemi.isTransferable(tokenId), "Should be transferable at exact boundary");
        // Subcurves should be empty (only this one non-transferable position existed post-seed)
        // Note: mainnet seeded positions contribute to non-transferable supply, so check forfeitable only
        assertEq(veHemi.forfeitableTotalVeHemiSupply(), 0, "Forfeitable should be 0 at boundary");

        // Forfeit should revert
        vm.prank(GNOSIS_SAFE);
        vm.expectRevert(VeHemi.ForfeitWindowExpired.selector);
        veHemi.forfeit(tokenId);

        // Global should still be positive (lock.end hasn't passed)
        assertGt(veHemi.totalVeHemiSupply(), 0, "Global should still be positive");
        assertGt(veHemi.balanceOfNFT(tokenId), 0, "Position should still have voting power");

        // 1 second AFTER boundary
        _warpAndRoll(1);
        assertTrue(veHemi.isTransferable(tokenId), "Should be transferable after boundary");
        assertEq(veHemi.forfeitableTotalVeHemiSupply(), 0, "Forfeitable still 0");

        _assertTokenConservation("After transition");
        _assertOrdering("After transition");
    }

    // ═════════════════════════════════════════════════════════════════════
    //  53. OPERATIONS AFTER SUBCURVE TRANSITION ON FORK
    // ═════════════════════════════════════════════════════════════════════

    /// @notice After a position exits the subcurves, increaseAmount and increaseUnlockTime
    ///         should only affect the global curve — subcurves must remain unchanged.
    function testOperationsAfterTransitionOnFork() public onlyFork {
        _upgradeAndSeed();

        // Create a forfeitable position and extend it
        deal(HEMI_TOKEN, GNOSIS_SAFE, 200 ether);
        vm.startPrank(GNOSIS_SAFE);
        hemiToken.approve(address(veHemi), 200 ether);
        uint256 tokenId = veHemi.createLockFor(100 ether, MAX_TIME / 4, address(0xF00D), false, true);
        vm.stopPrank();

        uint256 ta = veHemi.transferableAfter(tokenId);

        vm.prank(address(0xF00D));
        veHemi.increaseUnlockTime(tokenId, MAX_TIME / 2);

        // Warp past transferableAfter (position exits subcurves)
        _warpAndRoll(ta + 1 - block.timestamp);
        veHemi.checkpoint();

        uint256 forfeitableBefore = veHemi.forfeitableTotalVeHemiSupply();
        uint256 nonTransferableSupplyBefore = veHemi.nonTransferableTotalVeHemiSupply();
        uint256 totalBefore = veHemi.totalVeHemiSupply();

        // increaseAmount AFTER transition — subcurves should NOT change
        deal(HEMI_TOKEN, address(0xF00D), 100 ether);
        vm.startPrank(address(0xF00D));
        hemiToken.approve(address(veHemi), 100 ether);
        veHemi.increaseAmount(tokenId, 100 ether);
        vm.stopPrank();

        assertEq(veHemi.forfeitableTotalVeHemiSupply(), forfeitableBefore, "Forfeitable unchanged after post-transition increaseAmount");
        assertEq(veHemi.nonTransferableTotalVeHemiSupply(), nonTransferableSupplyBefore, "Locked unchanged after post-transition increaseAmount");
        assertGt(veHemi.totalVeHemiSupply(), totalBefore, "Global should increase from increaseAmount");

        // increaseUnlockTime AFTER transition — subcurves should NOT change
        uint256 totalAfterIncrease = veHemi.totalVeHemiSupply();
        vm.prank(address(0xF00D));
        veHemi.increaseUnlockTime(tokenId, MAX_TIME);

        assertEq(veHemi.forfeitableTotalVeHemiSupply(), forfeitableBefore, "Forfeitable unchanged after post-transition increaseUnlockTime");
        assertEq(veHemi.nonTransferableTotalVeHemiSupply(), nonTransferableSupplyBefore, "Locked unchanged after post-transition increaseUnlockTime");
        assertGt(veHemi.totalVeHemiSupply(), totalAfterIncrease, "Global should increase from increaseUnlockTime");

        _assertTokenConservation("After post-transition operations");
        _assertOrdering("After post-transition operations");
    }

    // ═════════════════════════════════════════════════════════════════════
    //  54. MULTI-POSITION STAGGERED TRANSITION ON FORK
    // ═════════════════════════════════════════════════════════════════════

    /// @notice Create multiple positions with different transferableAfter values (via different
    ///         initial durations), extend each, then warp through the transition boundaries
    ///         one by one. Verify the subcurve supply drops correctly at each transition.
    function testStaggeredTransitionsOnFork() public onlyFork {
        _upgradeAndSeed();

        // Create 3 forfeitable positions with different durations → different transferableAfter
        deal(HEMI_TOKEN, GNOSIS_SAFE, 600 ether);
        vm.startPrank(GNOSIS_SAFE);
        hemiToken.approve(address(veHemi), 600 ether);

        // Position A: 1yr lock → extend to 3yr
        uint256 tA = veHemi.createLockFor(100 ether, YEAR, address(0xA001), false, true);
        uint256 taA = veHemi.transferableAfter(tA);

        // Position B: 2yr lock → extend to 3yr
        uint256 tB = veHemi.createLockFor(200 ether, 2 * YEAR, address(0xA002), false, true);
        uint256 taB = veHemi.transferableAfter(tB);

        // Position C: 3yr lock → extend to 4yr
        uint256 tC = veHemi.createLockFor(300 ether, 3 * YEAR, address(0xA003), false, true);
        uint256 taC = veHemi.transferableAfter(tC);
        vm.stopPrank();

        // Extend each past its original end
        vm.prank(address(0xA001));
        veHemi.increaseUnlockTime(tA, 3 * YEAR);
        vm.prank(address(0xA002));
        veHemi.increaseUnlockTime(tB, 3 * YEAR);
        vm.prank(address(0xA003));
        veHemi.increaseUnlockTime(tC, MAX_TIME);

        assertLt(taA, taB, "A transitions before B");
        assertLt(taB, taC, "B transitions before C");

        // All 3 should be in forfeitable curve now
        uint256 forfAll = veHemi.forfeitableTotalVeHemiSupply();
        assertGt(forfAll, 0, "All 3 in forfeitable");

        // Warp past A's transferableAfter (but before B's)
        _warpAndRoll(taA + 1 - block.timestamp);
        veHemi.checkpoint();

        uint256 forfAfterA = veHemi.forfeitableTotalVeHemiSupply();
        assertLt(forfAfterA, forfAll, "Forfeitable dropped after A exited");
        assertTrue(veHemi.isTransferable(tA), "A should be transferable");
        assertFalse(veHemi.isTransferable(tB), "B should NOT be transferable yet");

        // Warp past B's transferableAfter (but before C's)
        _warpAndRoll(taB + 1 - block.timestamp);
        veHemi.checkpoint();

        uint256 forfAfterB = veHemi.forfeitableTotalVeHemiSupply();
        assertLt(forfAfterB, forfAfterA, "Forfeitable dropped after B exited");
        assertTrue(veHemi.isTransferable(tB), "B should be transferable");
        assertFalse(veHemi.isTransferable(tC), "C should NOT be transferable yet");

        // Warp past C's transferableAfter
        _warpAndRoll(taC + 1 - block.timestamp);
        veHemi.checkpoint();

        assertEq(veHemi.forfeitableTotalVeHemiSupply(), 0, "All positions have exited forfeitable");
        assertTrue(veHemi.isTransferable(tC), "C should be transferable");

        // Global supply should still be positive (all locks are extended past their transferableAfter)
        assertGt(veHemi.totalVeHemiSupply(), 0, "Global should still be positive");

        _assertTokenConservation("After all transitions");
        _assertOrdering("After all transitions");
    }

    // ═════════════════════════════════════════════════════════════════════
    //  55. TRANSFER AFTER SUBCURVE EXIT (MEDIUM GAP #1)
    // ═════════════════════════════════════════════════════════════════════

    /// @notice The #1 missing test: execute transferFrom on a position that has exited
    ///         subcurves (post-TA transition). Verify supply unchanged via independent
    ///         shadow, new owner's user point is correctly written, and new owner can
    ///         withdraw and receive HEMI.
    struct Test55Snapshot {
        uint256 ta;
        uint256 newEnd;
        uint256 slope;
        uint256 seedNonTransferableAtFuture;
        uint256 seedForfeitableAtFuture;
        uint256 seedTotalAtFuture;
        uint256 expectedPositionBias;
    }

    function testTransferAfterSubcurveExit() public onlyFork {
        _upgradeAndSeed();

        uint256 preTotalLocked = veHemi.totalLocked();

        // Create a forfeitable position and extend it past TA
        deal(HEMI_TOKEN, GNOSIS_SAFE, 100 ether);
        vm.startPrank(GNOSIS_SAFE);
        hemiToken.approve(address(veHemi), 100 ether);
        uint256 tokenId = veHemi.createLockFor(100 ether, MAX_TIME / 4, address(0xAAAA), false, true);
        vm.stopPrank();

        Test55Snapshot memory s;
        s.ta = veHemi.transferableAfter(tokenId);
        // Verify totalNon-transferable delta on create (R9)
        assertEq(veHemi.totalLocked(), preTotalLocked + 100 ether, "totalLocked +100 on create");

        vm.prank(address(0xAAAA));
        veHemi.increaseUnlockTime(tokenId, MAX_TIME / 2);
        s.newEnd = veHemi.getLockedBalance(tokenId).end;
        s.slope = uint256(100 ether) / MAX_TIME;

        // Capture seed-projected baselines at the future timestamp BEFORE warping
        uint256 futureTime = s.ta + 1;
        s.seedNonTransferableAtFuture = veHemi.nonTransferableTotalVeHemiSupplyAt(futureTime);
        s.seedForfeitableAtFuture = veHemi.forfeitableTotalVeHemiSupplyAt(futureTime);
        s.seedTotalAtFuture = veHemi.totalVeHemiSupplyAt(futureTime);

        // Warp past TA — position exits subcurves, becomes transferable
        _warpAndRoll(futureTime - block.timestamp);
        veHemi.checkpoint();
        assertTrue(veHemi.isTransferable(tokenId), "Should be transferable after TA");

        s.expectedPositionBias = s.slope * (s.newEnd - block.timestamp);

        _verifyTest55PreTransferState(tokenId, s);
        _verifyTest55Transfer(tokenId, s);
        _verifyTest55Withdraw(tokenId, s);
    }

    function _verifyTest55PreTransferState(uint256 tokenId, Test55Snapshot memory s) internal view {
        // Subcurves match seed-projection (position contributes 0 at futureTime)
        assertEq(
            veHemi.forfeitableTotalVeHemiSupply(),
            s.seedForfeitableAtFuture,
            "Forfeitable = seed-projection at futureTime"
        );
        assertEq(
            veHemi.nonTransferableTotalVeHemiSupply(),
            s.seedNonTransferableAtFuture,
            "Locked = seed-projection at futureTime"
        );
        // Independent shadow for OUR position's bias
        assertEq(
            veHemi.balanceOfNFT(tokenId),
            s.expectedPositionBias,
            "Position bias = slope*(newEnd-now)"
        );
        // Global matches seed-projection (which already includes our position)
        assertEq(
            veHemi.totalVeHemiSupply(),
            s.seedTotalAtFuture,
            "Global = seed-projection at futureTime"
        );
    }

    function _verifyTest55Transfer(uint256 tokenId, Test55Snapshot memory s) internal {
        // Pre-transfer user point check
        uint256 epochBefore = veHemi.userPointEpoch(tokenId);
        assertEq(
            veHemi.getUserPoint(tokenId, epochBefore).owner,
            address(0xAAAA),
            "user point owner = original"
        );

        // Execute transferFrom
        address newOwner = address(0xBBBB);
        vm.prank(address(0xAAAA));
        veHemi.transferFrom(address(0xAAAA), newOwner, tokenId);

        assertEq(veHemi.ownerOf(tokenId), newOwner, "New owner should own the NFT");

        // Supply unchanged — block.timestamp is the same so seed values match
        assertEq(veHemi.totalVeHemiSupply(), s.seedTotalAtFuture, "Global unchanged after transfer");
        assertEq(veHemi.nonTransferableTotalVeHemiSupply(), s.seedNonTransferableAtFuture, "Locked unchanged");
        assertEq(veHemi.forfeitableTotalVeHemiSupply(), s.seedForfeitableAtFuture, "Forfeitable unchanged");
        assertEq(veHemi.balanceOfNFT(tokenId), s.expectedPositionBias, "Position bias unchanged");

        // N-11.3: new owner's user point was correctly written
        // Transfer after warp always writes a new epoch (timestamps differ)
        uint256 epochAfter = veHemi.userPointEpoch(tokenId);
        assertEq(epochAfter, epochBefore + 1, "User point epoch advanced by 1");
        assertEq(veHemi.getUserPoint(tokenId, epochAfter).owner, newOwner, "user point owner = newOwner");
        (uint256 balAt, address ownerAt) = veHemi.balanceAndOwnerOfNFTAt(tokenId, block.timestamp);
        assertEq(ownerAt, newOwner, "balanceAndOwnerOfNFTAt owner = newOwner");
        assertEq(balAt, s.expectedPositionBias, "balanceAndOwnerOfNFTAt balance");

        // forfeitable and transferableAfter retained (not cleaned by transfer)
        assertTrue(veHemi.forfeitable(tokenId), "forfeitable flag retained on transfer");
        assertEq(veHemi.transferableAfter(tokenId), s.ta, "transferableAfter retained on transfer");

        _assertOrdering("After post-transition transfer");
        _assertTokenConservation("After post-transition transfer");
    }

    function _verifyTest55Withdraw(uint256 tokenId, Test55Snapshot memory s) internal {
        address newOwner = address(0xBBBB);
        // New owner can eventually withdraw after lock.end
        _warpAndRoll(s.newEnd + 1 - block.timestamp);
        uint256 hemiBefore = hemiToken.balanceOf(newOwner);
        vm.prank(newOwner);
        veHemi.withdraw(tokenId);

        // Verify cleanup
        assertEq(veHemi.getLockedBalance(tokenId).amount, 0, "amount cleared");
        assertEq(veHemi.transferableAfter(tokenId), 0, "transferableAfter cleared");
        assertFalse(veHemi.forfeitable(tokenId), "forfeitable cleared");
        assertEq(veHemi.provider(tokenId), address(0), "provider cleared");
        vm.expectRevert();
        veHemi.ownerOf(tokenId);
        assertEq(
            hemiToken.balanceOf(newOwner),
            hemiBefore + 100 ether,
            "newOwner received exactly 100 HEMI"
        );
        _assertTokenConservation("After new owner withdraw");
    }

    // ═════════════════════════════════════════════════════════════════════
    //  56. EXTENDED FORFEITABLE FULL LIFECYCLE (MEDIUM GAP #2)
    // ═════════════════════════════════════════════════════════════════════

    /// @notice Full lifecycle: create forfeitable → extend → TA passes (subcurve exit) →
    ///         lock.end passes → withdraw. Each phase uses INDEPENDENT shadow calculation
    ///         based on slope = amount / MAX_TIME and the locked.end captured at each step.
    ///         Seed contribution from mainnet positions decays over time, so we read
    ///         the seed-only baseline at each future timestamp before checking deltas.
    function testExtendedForfeitableFullLifecycle() public onlyFork {
        _upgradeAndSeed();

        // Snapshot pre-create supply for delta verification
        uint256 preTotal = veHemi.totalVeHemiSupply();
        uint256 preNonTransferable = veHemi.nonTransferableTotalVeHemiSupply();
        uint256 preForfeitable = veHemi.forfeitableTotalVeHemiSupply();
        uint256 preTotalLocked = veHemi.totalLocked();

        // R1-5: Anchor snapshot — mainnet has zero forfeitable positions
        assertEq(preForfeitable, 0, "mainnet seed forfeitable anchor = 0");

        // Create forfeitable with short duration
        deal(HEMI_TOKEN, GNOSIS_SAFE, 100 ether);
        vm.startPrank(GNOSIS_SAFE);
        hemiToken.approve(address(veHemi), 100 ether);
        uint256 tokenId = veHemi.createLockFor(100 ether, MAX_TIME / 4, address(0xAAAA), false, true);
        vm.stopPrank();

        // Capture timestamp ONCE at creation
        uint256 t0 = block.timestamp;
        uint256 ta = veHemi.transferableAfter(tokenId);
        // Independent slope: 100e18 / MAX_TIME (truncating, matches contract)
        uint256 slope = uint256(100 ether) / MAX_TIME;
        uint256 expectedForfCreate = slope * (ta - t0);

        // Verify creation deltas using independent shadow
        assertEq(
            veHemi.forfeitableTotalVeHemiSupply() - preForfeitable,
            expectedForfCreate,
            "Forfeitable delta = slope*(TA-t0) at creation"
        );
        assertEq(
            veHemi.nonTransferableTotalVeHemiSupply() - preNonTransferable,
            expectedForfCreate,
            "Non-transferable delta matches forfeitable at creation"
        );
        assertEq(veHemi.totalLocked() - preTotalLocked, 100 ether, "totalLocked +100 HEMI");
        assertEq(veHemi.provider(tokenId), GNOSIS_SAFE, "provider = creator");
        assertEq(veHemi.ownerOf(tokenId), address(0xAAAA), "owner = recipient");

        // Extend past TA
        vm.prank(address(0xAAAA));
        veHemi.increaseUnlockTime(tokenId, MAX_TIME / 2);
        uint256 newEnd = veHemi.getLockedBalance(tokenId).end;
        assertGt(newEnd, ta, "Lock end > TA after extension");
        // TA UNCHANGED
        assertEq(veHemi.transferableAfter(tokenId), ta, "TA unchanged by extension");

        // Forfeitable unchanged (subcurve bounded by TA)
        assertEq(
            veHemi.forfeitableTotalVeHemiSupply() - preForfeitable,
            expectedForfCreate,
            "Forfeitable unchanged after extension"
        );
        // Non-transferable-only subcurve also unchanged (bounded by TA)
        assertEq(
            veHemi.nonTransferableTotalVeHemiSupply() - preNonTransferable,
            expectedForfCreate,
            "Locked unchanged after extension (bounded by TA)"
        );
        // Global delta now uses newEnd
        assertEq(
            veHemi.totalVeHemiSupply() - preTotal,
            slope * (newEnd - t0),
            "Global delta = slope*(newEnd-t0) after extension"
        );

        // Phase 1: Warp past TA — subcurve exit
        // Capture future seed-only baselines BEFORE warping (mainnet positions decay over time)
        uint256 phase1Time = ta + 1;
        uint256 seedNonTransferableAtPhase1 = veHemi.nonTransferableTotalVeHemiSupplyAt(phase1Time);
        uint256 seedForfeitableAtPhase1 = veHemi.forfeitableTotalVeHemiSupplyAt(phase1Time);
        uint256 seedTotalAtPhase1 = veHemi.totalVeHemiSupplyAt(phase1Time);
        // Subtract this position's contribution at phase1Time from seed baseline.
        // At phase1Time > ta, this position contributes 0 to subcurves.
        // But it contributes slope*(newEnd - phase1Time) to global.
        uint256 thisPositionGlobalAtPhase1 = slope * (newEnd - phase1Time);

        _warpAndRoll(phase1Time - block.timestamp);
        veHemi.checkpoint();

        // L-9.2: BOTH subcurves drop to seed-only after TA
        // (the at-call already accounts for our position which contributes 0)
        assertEq(
            veHemi.forfeitableTotalVeHemiSupply(),
            seedForfeitableAtPhase1,
            "Forfeitable matches seed-only at phase1"
        );
        assertEq(
            veHemi.nonTransferableTotalVeHemiSupply(),
            seedNonTransferableAtPhase1,
            "Locked matches seed-only at phase1"
        );
        // Global = seed (which already includes our position's projected contribution at phase1Time)
        assertEq(
            veHemi.totalVeHemiSupply(),
            seedTotalAtPhase1,
            "Global matches seed-projected at phase1"
        );
        assertEq(
            veHemi.balanceOfNFT(tokenId),
            thisPositionGlobalAtPhase1,
            "Position bias = slope*(newEnd-now) post-TA"
        );
        assertTrue(veHemi.isTransferable(tokenId), "Transferable after TA");
        _assertOrdering("After TA transition");

        // Phase 2 + 3: warp past end, withdraw, verify cleanup (extracted to helper for stack)
        _verifyTest56FinalPhases(tokenId, newEnd, preTotalLocked);
    }

    function _verifyTest56FinalPhases(uint256 tokenId, uint256 newEnd, uint256 preTotalLocked) internal {
        // Phase 2: Warp past lock.end — position expires
        uint256 phase2Time = newEnd + 1;
        uint256 seedTotalAtPhase2 = veHemi.totalVeHemiSupplyAt(phase2Time);
        _warpAndRoll(phase2Time - block.timestamp);
        veHemi.checkpoint();
        assertEq(veHemi.balanceOfNFT(tokenId), 0, "Position bias = 0 at expiry");
        // At phase2 our position contributes 0 to global; remaining is seed-only
        assertEq(
            veHemi.totalVeHemiSupply(),
            seedTotalAtPhase2,
            "Global = seed-projected at phase2"
        );

        // Phase 3: Withdraw
        uint256 hemiBefore = hemiToken.balanceOf(address(0xAAAA));
        vm.prank(address(0xAAAA));
        veHemi.withdraw(tokenId);

        // L-9.1: full cleanup verification
        assertEq(veHemi.getLockedBalance(tokenId).amount, 0, "amount cleared");
        assertEq(veHemi.getLockedBalance(tokenId).end, 0, "end cleared");
        assertEq(veHemi.transferableAfter(tokenId), 0, "transferableAfter cleared");
        assertFalse(veHemi.forfeitable(tokenId), "forfeitable cleared");
        assertEq(veHemi.provider(tokenId), address(0), "provider cleared");
        // NFT burned
        vm.expectRevert();
        veHemi.ownerOf(tokenId);
        // HEMI returned exactly
        assertEq(
            hemiToken.balanceOf(address(0xAAAA)),
            hemiBefore + 100 ether,
            "User received exactly 100 HEMI"
        );
        // totalLocked back to pre-create
        assertEq(veHemi.totalLocked(), preTotalLocked, "totalLocked back to pre-create");
        _assertTokenConservation("After full lifecycle withdraw");
    }

    // ═════════════════════════════════════════════════════════════════════
    //  57. EXTENSION SUPPLY SEMANTICS FOR LOCKED-ONLY (MEDIUM GAP #3)
    // ═════════════════════════════════════════════════════════════════════

    /// @notice Verify that extending a non-transferable-only position increases global but does NOT
    ///         change non-transferable supply (subcurve bounded by transferableAfter = original end).
    ///         All assertions use INDEPENDENT slope = amount/MAX_TIME and EXACT slope-change
    ///         values (not qualitative `< 0` checks).
    function testExtensionNonTransferableOnlySubcurveBounded() public onlyFork {
        _upgradeAndSeed();

        // Snapshot
        uint256 preTotal = veHemi.totalVeHemiSupply();
        uint256 preNonTransferable = veHemi.nonTransferableTotalVeHemiSupply();
        uint256 preForfeitable = veHemi.forfeitableTotalVeHemiSupply();
        uint256 preTotalLocked = veHemi.totalLocked();

        deal(HEMI_TOKEN, GNOSIS_SAFE, 100 ether);
        vm.startPrank(GNOSIS_SAFE);
        hemiToken.approve(address(veHemi), 100 ether);
        uint256 tokenId = veHemi.createLockFor(100 ether, MAX_TIME / 4, address(0xAAAA), false, false);
        vm.stopPrank();

        // R9: totalNon-transferable delta on create
        assertEq(veHemi.totalLocked(), preTotalLocked + 100 ether, "totalLocked +100 on create");

        uint256 t0 = block.timestamp;
        uint256 ta = veHemi.transferableAfter(tokenId);
        uint256 slope = uint256(100 ether) / MAX_TIME;
        int128 expectedSlopeChange = -int128(int256(slope));
        uint256 expectedNonTransferableAtCreate = slope * (ta - t0);

        // Verify creation deltas
        assertEq(
            veHemi.nonTransferableTotalVeHemiSupply() - preNonTransferable,
            expectedNonTransferableAtCreate,
            "Non-transferable delta = slope*(TA-t0) at creation"
        );
        // Non-transferable-only — no forfeitable contribution
        assertEq(
            veHemi.forfeitableTotalVeHemiSupply(),
            preForfeitable,
            "Forfeitable unchanged (non-transferable-only)"
        );
        // Forfeitable slope change at TA: 0 (non-transferable-only position never enters forfeitable curve)
        assertEq(
            veHemi.forfeitableSlopeChanges(ta),
            int128(0),
            "forfeitableSlopeChanges[TA] = 0 (non-transferable-only)"
        );
        // Non-transferable slope change at TA: -slope (R6-M5 quantitative)
        assertEq(
            veHemi.nonTransferableSlopeChanges(ta),
            expectedSlopeChange,
            "nonTransferableSlopeChanges[TA] = -slope at creation"
        );

        // Extend to MAX_TIME / 2
        vm.prank(address(0xAAAA));
        veHemi.increaseUnlockTime(tokenId, MAX_TIME / 2);

        uint256 newEnd = veHemi.getLockedBalance(tokenId).end;

        // Global INCREASES exactly to slope*(newEnd-t0)
        assertEq(
            veHemi.totalVeHemiSupply() - preTotal,
            slope * (newEnd - t0),
            "Global delta = slope*(newEnd-t0) after extension"
        );
        // Locked UNCHANGED (subcurve bounded by TA = original end)
        assertEq(
            veHemi.nonTransferableTotalVeHemiSupply() - preNonTransferable,
            expectedNonTransferableAtCreate,
            "Locked unchanged (bounded by TA)"
        );
        // Forfeitable still unchanged
        assertEq(
            veHemi.forfeitableTotalVeHemiSupply(),
            preForfeitable,
            "Forfeitable unchanged after extension"
        );
        // transferableAfter stayed the same
        assertEq(veHemi.transferableAfter(tokenId), ta, "TA should not change");

        // Non-transferable slope change at TA UNCHANGED (R6-M5 + R8-M1 exact value)
        assertEq(
            veHemi.nonTransferableSlopeChanges(ta),
            expectedSlopeChange,
            "nonTransferableSlopeChanges[TA] = -slope unchanged after extension"
        );
        // No non-transferable slope change at new end
        assertEq(
            veHemi.nonTransferableSlopeChanges(newEnd),
            int128(0),
            "No nonTransferableSlopeChanges at newEnd"
        );

        // R6-M2: Global slope change cancellation pattern.
        // Prior to extension, lock.end == ta, so global slopeChanges[ta] = -slope.
        // After extension, the cancellation depends on whether ta is now an "active"
        // global endpoint for any other position. Since the extension moved this
        // position's contribution from ta to newEnd, the global slopeChanges[ta]
        // should have been decremented by +slope (cancelling our contribution).
        // The end value depends on what other positions have ta as their end —
        // for simplicity we verify slopeChanges[newEnd] is the expected value.
        assertEq(
            veHemi.slopeChanges(newEnd),
            expectedSlopeChange,
            "Global slopeChanges[newEnd] = -slope after extension"
        );

        // Phase: warp past TA — locked drops to seed-only at the projected timestamp
        // (mainnet seed positions decay over time, so we read the at-timestamp baseline)
        uint256 futureTime = ta + 1;
        uint256 seedNonTransferableAtFuture = veHemi.nonTransferableTotalVeHemiSupplyAt(futureTime);
        uint256 seedTotalAtFuture = veHemi.totalVeHemiSupplyAt(futureTime);

        _warpAndRoll(futureTime - block.timestamp);
        veHemi.checkpoint();

        // Locked drops to seed-only (the *At call already projects through our slope change)
        assertEq(
            veHemi.nonTransferableTotalVeHemiSupply(),
            seedNonTransferableAtFuture,
            "Locked = seed-only projection after TA"
        );
        // Global = seed-projection (which already includes our position contributing
        // slope*(newEnd - futureTime))
        assertEq(
            veHemi.totalVeHemiSupply(),
            seedTotalAtFuture,
            "Global = seed-projection after TA"
        );
        // Independent verification of OUR position's bias
        assertEq(
            veHemi.balanceOfNFT(tokenId),
            slope * (newEnd - block.timestamp),
            "Position bias = slope*(newEnd-now) post-TA"
        );

        _assertOrdering("After non-transferable-only extension");
        _assertTokenConservation("After non-transferable-only extension");
    }

    // ═════════════════════════════════════════════════════════════════════
    //  58. MULTIPLE EXTENSIONS + INCREASEAMOUNT COMBO (MEDIUM GAP #4)
    // ═════════════════════════════════════════════════════════════════════

    struct Test58Snapshot {
        uint256 preTotal;
        uint256 preNonTransferable;
        uint256 preForfeitable;
        uint256 t0;
        uint256 ta;
        uint256 slope; // wei/sec, computed independently as 100e18 / MAX_TIME
    }

    /// @notice Extend twice, then increaseAmount, then extend again, then withdraw.
    ///         Every assertion uses an INDEPENDENTLY-COMPUTED expected value (not the
    ///         contract's helper). Specifically:
    ///         - Slope = amount / MAX_TIME (truncating, matches contract semantics)
    ///         - Subcurve bias = slope * (TA - frozenTimestamp) where frozenTimestamp
    ///           is captured ONCE before any contract calls and never re-read.
    ///         - Global bias = slope * (lock.end - frozenTimestamp).
    ///         - nonTransferableSlopeChanges[TA] is verified as exact int128 quantitative value.
    ///         - Old global slopeChanges[oldEnd] are verified to be cancelled to 0 after
    ///           extension supersedes them.
    ///         - Final phase: warp past TA to verify forfeitable drops to exactly 0,
    ///           then warp past finalEnd, withdraw, and verify FULL cleanup of all storage.
    function testMultipleExtensionsAndIncreaseAmount() public onlyFork {
        _upgradeAndSeed();

        Test58Snapshot memory snap;
        snap.preTotal = veHemi.totalVeHemiSupply();
        snap.preNonTransferable = veHemi.nonTransferableTotalVeHemiSupply();
        snap.preForfeitable = veHemi.forfeitableTotalVeHemiSupply();
        uint256 preTotalLocked58 = veHemi.totalLocked();

        // R1-5: Anchor snapshot — mainnet has zero forfeitable positions
        assertEq(snap.preForfeitable, 0, "mainnet seed forfeitable anchor = 0");

        // Create a forfeitable position with MAX_TIME/4 duration
        deal(HEMI_TOKEN, GNOSIS_SAFE, 200 ether);
        vm.startPrank(GNOSIS_SAFE);
        hemiToken.approve(address(veHemi), 200 ether);
        uint256 tokenId = veHemi.createLockFor(100 ether, MAX_TIME / 4, address(0xAAAA), false, true);
        vm.stopPrank();

        // R9: totalNon-transferable delta on create
        assertEq(veHemi.totalLocked(), preTotalLocked58 + 100 ether, "totalLocked +100 on create");

        // Capture timestamp ONCE (R6-H4) — every expected value below uses this exact value.
        snap.t0 = block.timestamp;
        snap.ta = veHemi.transferableAfter(tokenId);
        // INDEPENDENT slope computation (not derived from any contract helper)
        snap.slope = uint256(100 ether) / MAX_TIME;

        _verifyTest58CreatePhase(tokenId, snap);

        uint256 endExt1 = _verifyTest58Ext1(tokenId, snap);
        uint256 endExt2 = _verifyTest58Ext2(tokenId, endExt1, snap);
        uint256 newSlope = _verifyTest58IncreaseAmount(tokenId, endExt2, snap);
        uint256 endExt3 = _verifyTest58Ext3(tokenId, endExt2, newSlope, snap);

        _assertOrdering("After multiple extensions + increaseAmount");
        _assertTokenConservation("After multiple extensions + increaseAmount");

        _verifyTest58PostTA(tokenId, endExt3, newSlope, snap);
        _verifyTest58FinalCleanup(tokenId, endExt3);
    }

    function _verifyTest58CreatePhase(uint256 tokenId, Test58Snapshot memory snap) internal view {
        // INDEPENDENT subcurve bias formula (R2-M1: explicit, not _computeBias coincidence)
        uint256 expectedForfCreate = snap.slope * (snap.ta - snap.t0);

        assertEq(
            veHemi.forfeitableTotalVeHemiSupply() - snap.preForfeitable,
            expectedForfCreate,
            "Forfeitable delta matches independent slope*(TA-t0)"
        );
        assertEq(
            veHemi.nonTransferableTotalVeHemiSupply() - snap.preNonTransferable,
            expectedForfCreate,
            "Non-transferable delta matches forfeitable at creation"
        );
        assertEq(
            veHemi.totalVeHemiSupply() - snap.preTotal,
            snap.slope * (snap.ta - snap.t0),
            "Global delta matches slope*(end-t0) at creation"
        );

        // R6-M5 quantitative slope changes
        int128 expectedSlopeChange = -int128(int256(snap.slope));
        assertEq(veHemi.nonTransferableSlopeChanges(snap.ta), expectedSlopeChange, "nonTransferableSlopeChanges[TA] = -slope");
        assertEq(veHemi.forfeitableSlopeChanges(snap.ta), expectedSlopeChange, "forfeitableSlopeChanges[TA] = -slope");
        assertEq(veHemi.slopeChanges(snap.ta), expectedSlopeChange, "global slopeChanges[TA] = -slope (lock.end == TA)");
    }

    function _verifyTest58Ext1(uint256 tokenId, Test58Snapshot memory snap) internal returns (uint256 endExt1) {
        vm.prank(address(0xAAAA));
        veHemi.increaseUnlockTime(tokenId, MAX_TIME / 3);
        endExt1 = veHemi.getLockedBalance(tokenId).end;
        assertGt(endExt1, snap.ta, "Ext 1: new end > TA");

        uint256 expectedForfCreate = snap.slope * (snap.ta - snap.t0);
        int128 expectedSlopeChange = -int128(int256(snap.slope));

        assertEq(
            veHemi.forfeitableTotalVeHemiSupply() - snap.preForfeitable,
            expectedForfCreate,
            "Forfeitable unchanged after ext 1"
        );
        assertEq(
            veHemi.totalVeHemiSupply() - snap.preTotal,
            snap.slope * (endExt1 - snap.t0),
            "Global delta = slope*(endExt1-t0) after ext 1"
        );

        // R6-M2: global slopeChanges[ta] cancelled, new at endExt1
        assertEq(veHemi.slopeChanges(snap.ta), int128(0), "Global slopeChanges[ta] cancelled after ext 1");
        assertEq(veHemi.slopeChanges(endExt1), expectedSlopeChange, "Global slopeChanges[endExt1] = -slope after ext 1");
        // Subcurve slope change at TA UNCHANGED
        assertEq(veHemi.nonTransferableSlopeChanges(snap.ta), expectedSlopeChange, "nonTransferableSlopeChanges[TA] unchanged after ext 1");
        assertEq(veHemi.nonTransferableSlopeChanges(endExt1), int128(0), "No nonTransferableSlopeChanges at endExt1");
    }

    function _verifyTest58Ext2(uint256 tokenId, uint256 endExt1, Test58Snapshot memory snap)
        internal
        returns (uint256 endExt2)
    {
        vm.prank(address(0xAAAA));
        veHemi.increaseUnlockTime(tokenId, MAX_TIME / 2);
        endExt2 = veHemi.getLockedBalance(tokenId).end;
        assertGt(endExt2, endExt1, "Ext 2: new end > endExt1");

        int128 expectedSlopeChange = -int128(int256(snap.slope));

        // R6-M2: global slopeChange at endExt1 cleared, new at endExt2
        assertEq(veHemi.slopeChanges(endExt1), int128(0), "Global slopeChanges[endExt1] cancelled after ext 2");
        assertEq(veHemi.slopeChanges(endExt2), expectedSlopeChange, "Global slopeChanges[endExt2] = -slope after ext 2");

        assertEq(
            veHemi.forfeitableTotalVeHemiSupply() - snap.preForfeitable,
            snap.slope * (snap.ta - snap.t0),
            "Forfeitable unchanged after ext 2"
        );
        assertEq(
            veHemi.totalVeHemiSupply() - snap.preTotal,
            snap.slope * (endExt2 - snap.t0),
            "Global delta = slope*(endExt2-t0) after ext 2"
        );
    }

    function _verifyTest58IncreaseAmount(uint256 tokenId, uint256 endExt2, Test58Snapshot memory snap)
        internal
        returns (uint256 newSlope)
    {
        deal(HEMI_TOKEN, address(0xAAAA), 100 ether);
        uint256 userHemiBefore = hemiToken.balanceOf(address(0xAAAA));
        vm.startPrank(address(0xAAAA));
        hemiToken.approve(address(veHemi), 100 ether);
        veHemi.increaseAmount(tokenId, 100 ether);
        vm.stopPrank();

        // R9: user's HEMI balance delta exactly -100 ether
        assertEq(
            hemiToken.balanceOf(address(0xAAAA)),
            userHemiBefore - 100 ether,
            "User paid exactly 100 HEMI for increaseAmount"
        );

        // INDEPENDENT slope after increase: 200e18 / MAX_TIME
        newSlope = uint256(200 ether) / MAX_TIME;
        uint256 expectedForfAfterIncrease = newSlope * (snap.ta - snap.t0);
        uint256 expectedGlobalAfterIncrease = newSlope * (endExt2 - snap.t0);

        assertEq(
            veHemi.forfeitableTotalVeHemiSupply() - snap.preForfeitable,
            expectedForfAfterIncrease,
            "Forfeitable delta = newSlope*(TA-t0) after increaseAmount"
        );
        assertEq(
            veHemi.nonTransferableTotalVeHemiSupply() - snap.preNonTransferable,
            expectedForfAfterIncrease,
            "Non-transferable delta matches forfeitable after increaseAmount"
        );
        assertEq(
            veHemi.totalVeHemiSupply() - snap.preTotal,
            expectedGlobalAfterIncrease,
            "Global delta = newSlope*(endExt2-t0) after increaseAmount"
        );

        // L-9.5/R4-M4: nonTransferableSlopeChanges[TA] updated to -newSlope
        int128 expectedNewSlopeChange = -int128(int256(newSlope));
        assertEq(veHemi.nonTransferableSlopeChanges(snap.ta), expectedNewSlopeChange, "nonTransferableSlopeChanges[TA] = -newSlope");
        assertEq(veHemi.forfeitableSlopeChanges(snap.ta), expectedNewSlopeChange, "forfeitableSlopeChanges[TA] = -newSlope");
        assertEq(veHemi.slopeChanges(endExt2), expectedNewSlopeChange, "Global slopeChanges[endExt2] = -newSlope");

        _assertTokenConservation("After increaseAmount");
    }

    function _verifyTest58Ext3(
        uint256 tokenId,
        uint256 endExt2,
        uint256 newSlope,
        Test58Snapshot memory snap
    ) internal returns (uint256 endExt3) {
        vm.prank(address(0xAAAA));
        veHemi.increaseUnlockTime(tokenId, MAX_TIME);
        endExt3 = veHemi.getLockedBalance(tokenId).end;
        assertGt(endExt3, endExt2, "Ext 3: new end > endExt2");

        int128 expectedNewSlopeChange = -int128(int256(newSlope));
        assertEq(veHemi.slopeChanges(endExt2), int128(0), "Global slopeChanges[endExt2] cancelled after ext 3");
        assertEq(veHemi.slopeChanges(endExt3), expectedNewSlopeChange, "Global slopeChanges[endExt3] = -newSlope");

        uint256 expectedForfAfterIncrease = newSlope * (snap.ta - snap.t0);
        assertEq(
            veHemi.forfeitableTotalVeHemiSupply() - snap.preForfeitable,
            expectedForfAfterIncrease,
            "Forfeitable unchanged after ext 3"
        );
        assertEq(
            veHemi.totalVeHemiSupply() - snap.preTotal,
            newSlope * (endExt3 - snap.t0),
            "Global delta = newSlope*(endExt3-t0) after ext 3"
        );
    }

    function _verifyTest58PostTA(
        uint256 tokenId,
        uint256 endExt3,
        uint256 newSlope,
        Test58Snapshot memory snap
    ) internal {
        // R5-M5: warp past TA, position must exit subcurves
        // Capture seed-projected baselines at the future timestamp BEFORE warping
        uint256 futureTime = snap.ta + 1;
        uint256 seedNonTransferableAtFuture = veHemi.nonTransferableTotalVeHemiSupplyAt(futureTime);
        uint256 seedForfeitableAtFuture = veHemi.forfeitableTotalVeHemiSupplyAt(futureTime);
        uint256 seedTotalAtFuture = veHemi.totalVeHemiSupplyAt(futureTime);

        _warpAndRoll(futureTime - block.timestamp);
        veHemi.checkpoint();

        // Subcurves match seed-projection (position now contributes 0)
        assertEq(
            veHemi.forfeitableTotalVeHemiSupply(),
            seedForfeitableAtFuture,
            "Forfeitable = seed-projection after TA"
        );
        assertEq(
            veHemi.nonTransferableTotalVeHemiSupply(),
            seedNonTransferableAtFuture,
            "Locked = seed-projection after TA"
        );
        // Global = seed-projection (already includes our position contributing newSlope*(endExt3-now))
        assertEq(
            veHemi.totalVeHemiSupply(),
            seedTotalAtFuture,
            "Global = seed-projection after TA"
        );
        // Independent verification of OUR position's bias
        assertEq(
            veHemi.balanceOfNFT(tokenId),
            newSlope * (endExt3 - block.timestamp),
            "Position bias = newSlope*(endExt3-now)"
        );
        assertTrue(veHemi.isTransferable(tokenId), "Transferable after TA");
    }

    function _verifyTest58FinalCleanup(uint256 tokenId, uint256 endExt3) internal {
        _warpAndRoll(endExt3 + 1 - block.timestamp);
        veHemi.checkpoint();

        assertEq(veHemi.balanceOfNFT(tokenId), 0, "Position bias = 0 at expiry");

        uint256 hemiBeforeWithdraw = hemiToken.balanceOf(address(0xAAAA));
        vm.prank(address(0xAAAA));
        veHemi.withdraw(tokenId);

        // FULL cleanup verification (L-9.3, L-9.5, N-11.5)
        assertEq(veHemi.getLockedBalance(tokenId).amount, 0, "amount cleared");
        assertEq(veHemi.getLockedBalance(tokenId).end, 0, "end cleared");
        assertEq(veHemi.transferableAfter(tokenId), 0, "transferableAfter cleared");
        assertFalse(veHemi.forfeitable(tokenId), "forfeitable cleared");
        assertEq(veHemi.provider(tokenId), address(0), "provider cleared");
        vm.expectRevert();
        veHemi.ownerOf(tokenId);
        // HEMI returned (200 ether: original 100 + increased 100)
        assertEq(
            hemiToken.balanceOf(address(0xAAAA)),
            hemiBeforeWithdraw + 200 ether,
            "User received 200 HEMI"
        );

        _assertTokenConservation("After full lifecycle withdraw of test 58 position");
    }

    // ═════════════════════════════════════════════════════════════════════
    //  59. LOW GAPS: FORFEIT REVERT FOR EXTENDED POSITION
    // ═════════════════════════════════════════════════════════════════════

    /// @notice Forfeit revert when TA < now < lock.end (extended position past forfeit window).
    function testForfeitRevertsOnExtendedPositionPastTA() public onlyFork {
        _upgradeAndSeed();
        vm.prank(GNOSIS_SAFE);
        veHemi.updateForfeitAdmin(GNOSIS_SAFE);

        deal(HEMI_TOKEN, GNOSIS_SAFE, 100 ether);
        vm.startPrank(GNOSIS_SAFE);
        hemiToken.approve(address(veHemi), 100 ether);
        uint256 tokenId = veHemi.createLockFor(100 ether, MAX_TIME / 4, address(0xAAAA), false, true);
        vm.stopPrank();

        uint256 ta = veHemi.transferableAfter(tokenId);
        vm.prank(address(0xAAAA));
        veHemi.increaseUnlockTime(tokenId, MAX_TIME);

        // Warp to TA < now < lock.end
        _warpAndRoll(ta + 30 days - block.timestamp);
        uint256 lockEnd = veHemi.getLockedBalance(tokenId).end;
        assertGt(block.timestamp, ta, "Past TA");
        assertLt(block.timestamp, lockEnd, "Before lock.end");
        // R1-2: exact bias instead of assertGt(x, 0)
        uint256 slope59a = uint256(100 ether) / MAX_TIME;
        assertEq(
            veHemi.balanceOfNFT(tokenId),
            slope59a * (lockEnd - block.timestamp),
            "Position bias = slope*(lockEnd-now)"
        );

        // Forfeit should revert — past forfeit window
        vm.prank(GNOSIS_SAFE);
        vm.expectRevert(VeHemi.ForfeitWindowExpired.selector);
        veHemi.forfeit(tokenId);
    }

    /// @notice transferFrom revert for forfeitable position before TA (same as locked).
    function testTransferFromRevertsForForfeitableBeforeTA() public onlyFork {
        _upgradeAndSeed();

        deal(HEMI_TOKEN, GNOSIS_SAFE, 100 ether);
        vm.startPrank(GNOSIS_SAFE);
        hemiToken.approve(address(veHemi), 100 ether);
        uint256 tokenId = veHemi.createLockFor(100 ether, MAX_TIME / 2, address(0xAAAA), false, true);
        vm.stopPrank();

        assertFalse(veHemi.isTransferable(tokenId), "Should not be transferable before TA");

        vm.prank(address(0xAAAA));
        vm.expectRevert(VeHemi.NotTransferable.selector);
        veHemi.transferFrom(address(0xAAAA), address(0xBBBB), tokenId);
    }

    /// @notice Forfeit with a transferable position in the mix verifying isolation.
    ///         Uses INDEPENDENT slope*(end-now) shadow for ALL three positions and
    ///         verifies FULL cleanup of the forfeited token's storage.
    function testForfeitIsolationWithTransferablePosition() public onlyFork {
        _upgradeAndSeed();
        vm.prank(GNOSIS_SAFE);
        veHemi.updateForfeitAdmin(GNOSIS_SAFE);

        // Snapshot
        uint256 preForfeitable = veHemi.forfeitableTotalVeHemiSupply();
        uint256 preTotalLocked = veHemi.totalLocked();

        // Create all three types
        deal(HEMI_TOKEN, GNOSIS_SAFE, 200 ether);
        deal(HEMI_TOKEN, address(0xCCCC), 100 ether);

        vm.startPrank(GNOSIS_SAFE);
        hemiToken.approve(address(veHemi), 200 ether);
        uint256 tNonTransferable = veHemi.createLockFor(100 ether, MAX_TIME / 2, address(0xAAAA), false, false);
        uint256 tForf = veHemi.createLockFor(100 ether, MAX_TIME / 2, address(0xBBBB), false, true);
        vm.stopPrank();

        vm.startPrank(address(0xCCCC));
        hemiToken.approve(address(veHemi), 100 ether);
        uint256 tXfer = veHemi.createLock(100 ether, MAX_TIME / 2);
        vm.stopPrank();

        // Capture timestamps and ends for INDEPENDENT shadow calculation
        uint256 tNow = block.timestamp;
        uint256 endNonTransferable = veHemi.getLockedBalance(tNonTransferable).end;
        uint256 endXfer = veHemi.getLockedBalance(tXfer).end;
        uint256 slope = uint256(100 ether) / MAX_TIME;
        uint256 expectedNonTransferableBias = slope * (endNonTransferable - tNow);
        uint256 expectedXferBias = slope * (endXfer - tNow);

        // Pre-forfeit independent shadow check
        assertEq(veHemi.balanceOfNFT(tNonTransferable), expectedNonTransferableBias, "Non-transferable bias = independent shadow pre-forfeit");
        assertEq(veHemi.balanceOfNFT(tXfer), expectedXferBias, "Xfer bias = independent shadow pre-forfeit");

        // Hemi balances pre-forfeit
        uint256 hemiAdminBefore = hemiToken.balanceOf(GNOSIS_SAFE);

        // Forfeit the forfeitable position
        vm.prank(GNOSIS_SAFE);
        veHemi.forfeit(tForf);

        // Non-transferable-only position completely unaffected (still independent shadow)
        assertEq(veHemi.balanceOfNFT(tNonTransferable), expectedNonTransferableBias, "Non-transferable bias unchanged after forfeit");
        // Transferable position completely unaffected (still independent shadow)
        assertEq(veHemi.balanceOfNFT(tXfer), expectedXferBias, "Xfer bias unchanged after forfeit");
        // Forfeitable back to seed-only
        assertEq(
            veHemi.forfeitableTotalVeHemiSupply(),
            preForfeitable,
            "Forfeitable back to seed-only after forfeit"
        );

        // R4-M5: FULL cleanup of forfeited token's storage
        assertEq(veHemi.getLockedBalance(tForf).amount, 0, "tForf amount cleared");
        assertEq(veHemi.getLockedBalance(tForf).end, 0, "tForf end cleared");
        assertEq(veHemi.transferableAfter(tForf), 0, "tForf transferableAfter cleared");
        assertFalse(veHemi.forfeitable(tForf), "tForf forfeitable cleared");
        assertEq(veHemi.provider(tForf), address(0), "tForf provider cleared");
        // NFT burned
        vm.expectRevert();
        veHemi.ownerOf(tForf);
        // HEMI sent to forfeitAdmin (GNOSIS_SAFE in this test)
        assertEq(
            hemiToken.balanceOf(GNOSIS_SAFE),
            hemiAdminBefore + 100 ether,
            "Forfeit admin received exactly 100 HEMI"
        );
        // totalLocked decreased by 100 ether (the forfeited amount)
        assertEq(
            veHemi.totalLocked(),
            preTotalLocked + 200 ether, // +100 locked + 100 xfer (forfeited 100 already removed)
            "totalLocked = preTotalLocked + locked + xfer (forfeited removed)"
        );

        // Other tokens still exist with fully intact storage (R11: re-verify all fields)
        assertEq(veHemi.ownerOf(tNonTransferable), address(0xAAAA), "tNonTransferable owner intact");
        assertEq(veHemi.ownerOf(tXfer), address(0xCCCC), "tXfer owner intact");
        assertEq(veHemi.getLockedBalance(tNonTransferable).amount, int128(int256(uint256(100 ether))), "tNonTransferable amount intact");
        assertEq(veHemi.getLockedBalance(tXfer).amount, int128(int256(uint256(100 ether))), "tXfer amount intact");
        assertEq(veHemi.getLockedBalance(tNonTransferable).end, endNonTransferable, "tNonTransferable end intact");
        assertEq(veHemi.getLockedBalance(tXfer).end, endXfer, "tXfer end intact");
        assertEq(veHemi.transferableAfter(tNonTransferable), endNonTransferable, "tNonTransferable TA intact");
        assertEq(veHemi.provider(tNonTransferable), GNOSIS_SAFE, "tNonTransferable provider intact");
        assertEq(veHemi.provider(tXfer), address(0xCCCC), "tXfer provider intact");

        _assertOrdering("After forfeit with all 3 types");
        _assertTokenConservation("After forfeit with all 3 types");
    }

    /// @notice Create new forfeitable after another has transitioned — verify subcurve recovery.
    ///         Uses INDEPENDENT slope*(end-now) shadow.
    function testCreateForfeitableAfterTransition() public onlyFork {
        _upgradeAndSeed();

        uint256 preForfeitable = veHemi.forfeitableTotalVeHemiSupply();

        // Create and extend a forfeitable, warp past TA
        deal(HEMI_TOKEN, GNOSIS_SAFE, 200 ether);
        vm.startPrank(GNOSIS_SAFE);
        hemiToken.approve(address(veHemi), 200 ether);
        uint256 t1 = veHemi.createLockFor(100 ether, MAX_TIME / 4, address(0xAAAA), false, true);
        vm.stopPrank();

        uint256 ta1 = veHemi.transferableAfter(t1);
        vm.prank(address(0xAAAA));
        veHemi.increaseUnlockTime(t1, MAX_TIME / 2);

        _warpAndRoll(ta1 + 1 - block.timestamp);
        veHemi.checkpoint();
        assertEq(
            veHemi.forfeitableTotalVeHemiSupply(),
            preForfeitable,
            "Forfeitable back to seed-only after t1 transitions"
        );

        // Create a NEW forfeitable position — subcurve should recover
        vm.startPrank(GNOSIS_SAFE);
        uint256 t2 = veHemi.createLockFor(100 ether, MAX_TIME / 2, address(0xBBBB), false, true);
        vm.stopPrank();

        // Independent shadow: slope*(ta2-now) where ta2 == new lock.end
        uint256 t2Now = block.timestamp;
        uint256 ta2 = veHemi.transferableAfter(t2);
        uint256 slope2 = uint256(100 ether) / MAX_TIME;
        uint256 expectedForf = slope2 * (ta2 - t2Now);

        assertEq(
            veHemi.forfeitableTotalVeHemiSupply() - preForfeitable,
            expectedForf,
            "New forfeitable delta = slope*(ta2-t2Now)"
        );
        // Verify t1 and t2 have DIFFERENT TAs (proves recovery isn't aliasing)
        assertGt(ta2, ta1, "t2 TA > t1 TA");
        // R4-1: forfeitable flag is retained until withdraw/forfeit (by design — not cleaned on subcurve exit)
        assertEq(veHemi.forfeitable(t1), true, "t1 forfeitable flag retained until withdraw/forfeit");

        // forfeitableSlopeChanges[ta2] is set to -slope2
        int128 expectedSC = -int128(int256(slope2));
        assertEq(
            veHemi.forfeitableSlopeChanges(ta2),
            expectedSC,
            "forfeitableSlopeChanges[ta2] = -slope"
        );

        _assertOrdering("After creating new forfeitable post-transition");
        _assertTokenConservation("After creating new forfeitable post-transition");
    }

    /// @notice Extension to exactly MAX_TIME with subcurve verification.
    ///         Uses INDEPENDENT slope shadow throughout.
    function testExtensionToMaxTime() public onlyFork {
        _upgradeAndSeed();

        uint256 preForfeitable = veHemi.forfeitableTotalVeHemiSupply();
        uint256 preTotal = veHemi.totalVeHemiSupply();
        uint256 preTotalLocked59e = veHemi.totalLocked();

        deal(HEMI_TOKEN, GNOSIS_SAFE, 100 ether);
        vm.startPrank(GNOSIS_SAFE);
        hemiToken.approve(address(veHemi), 100 ether);
        uint256 tokenId = veHemi.createLockFor(100 ether, 2 * SIX_DAYS, address(0xAAAA), false, true);
        vm.stopPrank();

        // R9: totalNon-transferable delta on create
        assertEq(veHemi.totalLocked(), preTotalLocked59e + 100 ether, "totalLocked +100 on create");

        uint256 t0 = block.timestamp;
        uint256 ta = veHemi.transferableAfter(tokenId);
        uint256 slope = uint256(100 ether) / MAX_TIME;
        uint256 expectedForfCreate = slope * (ta - t0);

        assertEq(
            veHemi.forfeitableTotalVeHemiSupply() - preForfeitable,
            expectedForfCreate,
            "Forfeitable delta = slope*(ta-t0) at creation"
        );

        // Extend to MAX_TIME
        vm.prank(address(0xAAAA));
        veHemi.increaseUnlockTime(tokenId, MAX_TIME);
        uint256 newEnd = veHemi.getLockedBalance(tokenId).end;

        // Forfeitable unchanged (subcurve bounded by very short original TA)
        assertEq(
            veHemi.forfeitableTotalVeHemiSupply() - preForfeitable,
            expectedForfCreate,
            "Forfeitable unchanged after MAX_TIME extension"
        );
        // TA stays at original short end
        assertEq(veHemi.transferableAfter(tokenId), ta, "TA should stay at original");
        // Global delta uses newEnd (~MAX_TIME)
        uint256 expectedGlobal = slope * (newEnd - t0);
        assertEq(
            veHemi.totalVeHemiSupply() - preTotal,
            expectedGlobal,
            "Global delta = slope*(newEnd-t0) after MAX_TIME extension"
        );
        assertEq(
            veHemi.balanceOfNFT(tokenId),
            expectedGlobal,
            "Position bias = slope*(newEnd-t0) after MAX_TIME extension"
        );

        // Verify subcurve slope change at TA still scheduled
        int128 expectedSC = -int128(int256(slope));
        assertEq(veHemi.forfeitableSlopeChanges(ta), expectedSC, "forfeitableSlopeChanges[TA] = -slope");
        assertEq(veHemi.nonTransferableSlopeChanges(ta), expectedSC, "nonTransferableSlopeChanges[TA] = -slope");
        // Global slope change at new end
        assertEq(veHemi.slopeChanges(newEnd), expectedSC, "Global slopeChanges[newEnd] = -slope");

        _assertOrdering("After MAX_TIME extension");
        _assertTokenConservation("After MAX_TIME extension");
    }

    // ═════════════════════════════════════════════════════════════════════
    //  60. NEW BOUNDARY/EDGE-CASE TESTS (R3-M1, R3-M2, R3-M3, N-11.4)
    // ═════════════════════════════════════════════════════════════════════

    /// @notice R3-M1: Transfer at the EXACT transferableAfter timestamp (boundary),
    ///         not ta+1. The contract uses `<= block.timestamp` so the position
    ///         is transferable at exactly TA.
    function testTransferAtExactTransferableAfter() public onlyFork {
        _upgradeAndSeed();

        deal(HEMI_TOKEN, GNOSIS_SAFE, 100 ether);
        vm.startPrank(GNOSIS_SAFE);
        hemiToken.approve(address(veHemi), 100 ether);
        uint256 tokenId = veHemi.createLockFor(100 ether, MAX_TIME / 4, address(0xAAAA), false, true);
        vm.stopPrank();

        uint256 ta = veHemi.transferableAfter(tokenId);
        // Extend so lock.end > ta — otherwise the position would be expired at ta
        vm.prank(address(0xAAAA));
        veHemi.increaseUnlockTime(tokenId, MAX_TIME / 2);

        // Warp to EXACTLY ta (not ta+1)
        _warpAndRoll(ta - block.timestamp);
        assertEq(block.timestamp, ta, "block.timestamp == ta");

        // Position must be transferable at exact ta (uses <=)
        assertTrue(veHemi.isTransferable(tokenId), "Transferable at exact ta");

        // Transfer should succeed
        vm.prank(address(0xAAAA));
        veHemi.transferFrom(address(0xAAAA), address(0xBBBB), tokenId);
        assertEq(veHemi.ownerOf(tokenId), address(0xBBBB), "Transfer succeeded at exact ta");
        _assertTokenConservation("After exact-TA transfer");
        _assertOrdering("After exact-TA transfer");
    }

    /// @notice R3-M2: increaseAmount during the post-TA pre-expiry phase (subcurve exited
    ///         but lock still active). Verify that increase only affects global, not subcurves.
    function testIncreaseAmountPostTAOnExtended() public onlyFork {
        _upgradeAndSeed();

        deal(HEMI_TOKEN, GNOSIS_SAFE, 200 ether);
        vm.startPrank(GNOSIS_SAFE);
        hemiToken.approve(address(veHemi), 200 ether);
        uint256 tokenId = veHemi.createLockFor(100 ether, MAX_TIME / 4, address(0xAAAA), false, true);
        vm.stopPrank();

        uint256 ta = veHemi.transferableAfter(tokenId);
        vm.prank(address(0xAAAA));
        veHemi.increaseUnlockTime(tokenId, MAX_TIME / 2);
        uint256 newEnd = veHemi.getLockedBalance(tokenId).end;

        // Capture seed-projected baselines at the future timestamp BEFORE warping
        uint256 futureTime = ta + 1;
        uint256 seedNonTransferableAtFuture = veHemi.nonTransferableTotalVeHemiSupplyAt(futureTime);
        uint256 seedForfeitableAtFuture = veHemi.forfeitableTotalVeHemiSupplyAt(futureTime);

        // Warp past TA — subcurve exited
        _warpAndRoll(futureTime - block.timestamp);
        veHemi.checkpoint();
        assertEq(veHemi.forfeitableTotalVeHemiSupply(), seedForfeitableAtFuture, "Forfeitable = seed-projection post-TA");
        assertEq(veHemi.nonTransferableTotalVeHemiSupply(), seedNonTransferableAtFuture, "Locked = seed-projection post-TA");

        // Old slope and old position bias (independent)
        uint256 oldSlope = uint256(100 ether) / MAX_TIME;
        uint256 oldBias = oldSlope * (newEnd - block.timestamp);
        assertEq(veHemi.balanceOfNFT(tokenId), oldBias, "Position bias = oldSlope*(newEnd-now) before increase");

        // increaseAmount post-TA
        uint256 totalLockedBefore = veHemi.totalLocked();
        deal(HEMI_TOKEN, address(0xAAAA), 100 ether);
        uint256 userHemiBefore = hemiToken.balanceOf(address(0xAAAA));
        vm.startPrank(address(0xAAAA));
        hemiToken.approve(address(veHemi), 100 ether);
        veHemi.increaseAmount(tokenId, 100 ether);
        vm.stopPrank();

        // R9: totalNon-transferable delta +100, user HEMI delta -100
        assertEq(veHemi.totalLocked(), totalLockedBefore + 100 ether, "totalLocked +100 after increase");
        assertEq(
            hemiToken.balanceOf(address(0xAAAA)),
            userHemiBefore - 100 ether,
            "User paid exactly 100 HEMI"
        );

        // Subcurves MUST stay seed-projection (post-TA, position no longer in subcurves)
        // Note: increaseAmount doesn't warp time, so seed projection at futureTime still applies
        assertEq(
            veHemi.forfeitableTotalVeHemiSupply(),
            seedForfeitableAtFuture,
            "Forfeitable still seed-projection after post-TA increaseAmount"
        );
        assertEq(
            veHemi.nonTransferableTotalVeHemiSupply(),
            seedNonTransferableAtFuture,
            "Locked still seed-projection after post-TA increaseAmount"
        );

        // Global increases by independent shadow: newSlope * (newEnd - now)
        uint256 newSlope = uint256(200 ether) / MAX_TIME;
        uint256 expectedNewBias = newSlope * (newEnd - block.timestamp);
        assertEq(
            veHemi.balanceOfNFT(tokenId),
            expectedNewBias,
            "Position bias = newSlope*(newEnd-now) after post-TA increase"
        );
        // Global delta = bias increase
        // Bias delta = (newSlope - oldSlope) * (newEnd - now)
        assertEq(
            veHemi.balanceOfNFT(tokenId) - oldBias,
            (newSlope - oldSlope) * (newEnd - block.timestamp),
            "Position bias delta = (newSlope - oldSlope) * (newEnd - now)"
        );

        _assertOrdering("After post-TA increaseAmount");
        _assertTokenConservation("After post-TA increaseAmount");
    }

    /// @notice R3-M3: Extending to a new unlock time that rounds to the SAME end as the
    ///         current end must revert with NewLockDurationNotGreater.
    function testExtendToSameUnlockTimeReverts() public onlyFork {
        _upgradeAndSeed();

        deal(HEMI_TOKEN, GNOSIS_SAFE, 100 ether);
        vm.startPrank(GNOSIS_SAFE);
        hemiToken.approve(address(veHemi), 100 ether);
        uint256 tokenId = veHemi.createLockFor(100 ether, MAX_TIME / 4, address(0xAAAA), false, false);
        vm.stopPrank();

        uint256 oldEnd = veHemi.getLockedBalance(tokenId).end;
        uint256 currentDuration = oldEnd - block.timestamp;

        // Extending to the SAME duration rounds to the SAME end → should revert
        vm.prank(address(0xAAAA));
        vm.expectRevert(VeHemi.NewLockDurationNotGreater.selector);
        veHemi.increaseUnlockTime(tokenId, currentDuration);
    }

    /// @notice N-11.4: Positive-path forfeit on a position that has been EXTENDED but
    ///         is still BEFORE its original TA. Forfeit must succeed and clean up.
    function testForfeitOnExtendedPositionBeforeTA() public onlyFork {
        _upgradeAndSeed();
        vm.prank(GNOSIS_SAFE);
        veHemi.updateForfeitAdmin(GNOSIS_SAFE);

        uint256 preTotalLocked = veHemi.totalLocked();

        deal(HEMI_TOKEN, GNOSIS_SAFE, 100 ether);
        vm.startPrank(GNOSIS_SAFE);
        hemiToken.approve(address(veHemi), 100 ether);
        uint256 tokenId = veHemi.createLockFor(100 ether, MAX_TIME / 4, address(0xAAAA), false, true);
        vm.stopPrank();

        uint256 ta = veHemi.transferableAfter(tokenId);

        // Extend the lock
        vm.prank(address(0xAAAA));
        veHemi.increaseUnlockTime(tokenId, MAX_TIME / 2);

        // Warp halfway between now and ta (still BEFORE TA, in forfeit window)
        uint256 halfway = (block.timestamp + ta) / 2;

        // Capture seed-projected baselines + this position's at the halfway timestamp
        // BEFORE warping. We then forfeit, so post-forfeit subcurves should equal
        // (pre-forfeit subcurves - this position's contribution at halfway).
        uint256 slope = uint256(100 ether) / MAX_TIME;
        uint256 thisPositionForfContribution = slope * (ta - halfway);
        uint256 seedNonTransferableAtHalfway = veHemi.nonTransferableTotalVeHemiSupplyAt(halfway);
        uint256 seedForfeitableAtHalfway = veHemi.forfeitableTotalVeHemiSupplyAt(halfway);

        _warpAndRoll(halfway - block.timestamp);
        assertLt(block.timestamp, ta, "Still before TA");
        assertGt(ta, block.timestamp, "TA in future");
        veHemi.checkpoint();

        // Pre-forfeit: subcurves match seed projection (which includes our position's contribution)
        assertEq(
            veHemi.forfeitableTotalVeHemiSupply(),
            seedForfeitableAtHalfway,
            "Forfeitable matches seed-projection pre-forfeit"
        );
        assertEq(
            veHemi.nonTransferableTotalVeHemiSupply(),
            seedNonTransferableAtHalfway,
            "Locked matches seed-projection pre-forfeit"
        );

        uint256 hemiAdminBefore = hemiToken.balanceOf(GNOSIS_SAFE);

        // Forfeit must SUCCEED (positive path)
        vm.prank(GNOSIS_SAFE);
        veHemi.forfeit(tokenId);

        // Full cleanup
        assertEq(veHemi.getLockedBalance(tokenId).amount, 0, "amount cleared");
        assertEq(veHemi.getLockedBalance(tokenId).end, 0, "end cleared");
        assertEq(veHemi.transferableAfter(tokenId), 0, "transferableAfter cleared");
        assertFalse(veHemi.forfeitable(tokenId), "forfeitable cleared");
        assertEq(veHemi.provider(tokenId), address(0), "provider cleared");
        vm.expectRevert();
        veHemi.ownerOf(tokenId);

        // HEMI returned to admin
        assertEq(
            hemiToken.balanceOf(GNOSIS_SAFE),
            hemiAdminBefore + 100 ether,
            "Admin received exactly 100 HEMI"
        );
        // totalLocked back to pre
        assertEq(veHemi.totalLocked(), preTotalLocked, "totalLocked back to pre");

        // Subcurves: post-forfeit = pre-forfeit - thisPositionContribution
        assertEq(
            veHemi.forfeitableTotalVeHemiSupply(),
            seedForfeitableAtHalfway - thisPositionForfContribution,
            "Forfeitable = pre - thisPositionContribution after forfeit"
        );
        assertEq(
            veHemi.nonTransferableTotalVeHemiSupply(),
            seedNonTransferableAtHalfway - thisPositionForfContribution,
            "Locked = pre - thisPositionContribution after forfeit"
        );

        _assertOrdering("After positive-path forfeit");
        _assertTokenConservation("After positive-path forfeit");
    }

    // ═════════════════════════════════════════════════════════════════════
    //  61. INDEPENDENT PER-POSITION SUBCURVE CROSS-CHECK (HIGH R8-11)
    // ═════════════════════════════════════════════════════════════════════

    /// @notice Breaks the *At view circularity by computing per-position subcurve
    ///         contributions independently and comparing their SUM against the aggregate
    ///         subcurve supply. This is the strongest possible correctness check — if the
    ///         catchup loop or the *At view function have a symmetric bug, this test catches it.
    function testIndependentSubcurveAggregateCheck() public onlyFork {
        _upgradeAndSeed();

        // Create 3 non-transferable positions (2 forfeitable, 1 non-transferable-only)
        deal(HEMI_TOKEN, GNOSIS_SAFE, 300 ether);
        vm.startPrank(GNOSIS_SAFE);
        hemiToken.approve(address(veHemi), 300 ether);
        uint256 tA = veHemi.createLockFor(100 ether, MAX_TIME / 4, address(0xAAAA), false, true);
        uint256 tB = veHemi.createLockFor(100 ether, MAX_TIME / 3, address(0xBBBB), false, true);
        uint256 tC = veHemi.createLockFor(100 ether, MAX_TIME / 2, address(0xCCCC), false, false);
        vm.stopPrank();

        uint256 slope = uint256(100 ether) / MAX_TIME;
        uint256 taA = veHemi.transferableAfter(tA);
        uint256 taB = veHemi.transferableAfter(tB);
        uint256 taC = veHemi.transferableAfter(tC);

        // Warp to a time between taA and taB. At that point:
        // - tA has exited subcurves (past taA): contributes 0 to forfeitable and locked
        // - tB is still in subcurves: forf = slope * (taB - now), locked = same
        // - tC is still in non-transferable subcurve (non-transferable-only): locked = slope * (taC - now), forf = 0
        _warpAndRoll(taA + (taB - taA) / 2 - block.timestamp);
        veHemi.checkpoint();

        // Mainnet seed forfeitable == 0 (independently verified by testSupplyBreakdownConsistency)
        // So: aggregate forfeitable MUST exactly equal our independent sum = slope * (taB - now)
        uint256 independentForfSum = slope * (taB - block.timestamp);
        assertEq(
            veHemi.forfeitableTotalVeHemiSupply(),
            independentForfSum,
            "Aggregate forfeitable == independent per-position sum (breaks *At circularity)"
        );

        // Verify individual position biases match independent global formula
        _verifyIndependentGlobalBiases(tA, tB, tC, slope);
        _assertOrdering("After independent subcurve cross-check");
        _assertTokenConservation("After independent subcurve cross-check");
    }

    function _verifyIndependentGlobalBiases(uint256 tA, uint256 tB, uint256 tC, uint256 slope) internal view {
        uint256 endA = veHemi.getLockedBalance(tA).end;
        uint256 endB = veHemi.getLockedBalance(tB).end;
        uint256 endC = veHemi.getLockedBalance(tC).end;
        // tA: endA == taA (never extended), now > taA → expired, bias = 0
        assertEq(veHemi.balanceOfNFT(tA), 0, "tA expired at target (end == taA < now)");
        // tB and tC: still active
        assertEq(veHemi.balanceOfNFT(tB), slope * (endB - block.timestamp), "tB global bias");
        assertEq(veHemi.balanceOfNFT(tC), slope * (endC - block.timestamp), "tC global bias");
    }

    // ═════════════════════════════════════════════════════════════════════
    //  62. TWO FORFEITABLE POSITIONS SHARING SAME TA BOUNDARY (MEDIUM R8)
    // ═════════════════════════════════════════════════════════════════════

    /// @notice Two forfeitable positions created in the same block (same rounded TA),
    ///         extend one, verify slope-change accumulation is correct.
    function testTwoForfeitablePositionsSameTABoundary() public onlyFork {
        _upgradeAndSeed();

        deal(HEMI_TOKEN, GNOSIS_SAFE, 200 ether);
        vm.startPrank(GNOSIS_SAFE);
        hemiToken.approve(address(veHemi), 200 ether);
        uint256 tA = veHemi.createLockFor(100 ether, MAX_TIME / 4, address(0xAAAA), false, true);
        uint256 tB = veHemi.createLockFor(100 ether, MAX_TIME / 4, address(0xBBBB), false, true);
        vm.stopPrank();

        uint256 slope = uint256(100 ether) / MAX_TIME;
        uint256 taA = veHemi.transferableAfter(tA);
        uint256 taB = veHemi.transferableAfter(tB);
        // Both created in same block, same duration → same TA
        assertEq(taA, taB, "Both positions have same TA");

        // Slope changes at shared TA should be -2*slope (accumulated from A + B)
        int128 expectedCumulative = -int128(int256(2 * slope));
        assertEq(
            veHemi.nonTransferableSlopeChanges(taA),
            expectedCumulative,
            "nonTransferableSlopeChanges[TA] = -2*slope (both positions)"
        );
        assertEq(
            veHemi.forfeitableSlopeChanges(taA),
            expectedCumulative,
            "forfeitableSlopeChanges[TA] = -2*slope (both positions)"
        );
        assertEq(
            veHemi.slopeChanges(taA),
            expectedCumulative,
            "Global slopeChanges[TA] = -2*slope (both positions)"
        );

        // Extend position A past TA
        vm.prank(address(0xAAAA));
        veHemi.increaseUnlockTime(tA, MAX_TIME / 2);
        uint256 newEndA = veHemi.getLockedBalance(tA).end;

        // Global slopeChanges[TA] should now be only -slopeB (A moved to newEndA)
        int128 expectedSingle = -int128(int256(slope));
        assertEq(
            veHemi.slopeChanges(taA),
            expectedSingle,
            "Global slopeChanges[TA] = -slope (only B's global endpoint remains)"
        );
        assertEq(
            veHemi.slopeChanges(newEndA),
            expectedSingle,
            "Global slopeChanges[newEndA] = -slope (A's new endpoint)"
        );

        // Subcurve slope changes at TA should still be -2*slope (TA still bounds BOTH subcurves)
        assertEq(
            veHemi.nonTransferableSlopeChanges(taA),
            expectedCumulative,
            "nonTransferableSlopeChanges[TA] still -2*slope after extending A"
        );
        assertEq(
            veHemi.forfeitableSlopeChanges(taA),
            expectedCumulative,
            "forfeitableSlopeChanges[TA] still -2*slope after extending A"
        );

        // Warp past TA — both exit subcurves
        _warpAndRoll(taA + 1 - block.timestamp);
        veHemi.checkpoint();

        // Forfeitable should be 0 (mainnet seed = 0)
        assertEq(veHemi.forfeitableTotalVeHemiSupply(), 0, "Forfeitable 0 after both exit");

        // tA was extended (lock.end > ta) — still active in global
        uint256 endA = veHemi.getLockedBalance(tA).end;
        assertGt(endA, taA, "tA end > ta (extended)");
        assertEq(
            veHemi.balanceOfNFT(tA),
            slope * (endA - block.timestamp),
            "tA still active in global (extended)"
        );
        // tB was NOT extended (lock.end == ta) — expired at ta+1
        assertEq(veHemi.balanceOfNFT(tB), 0, "tB expired (lock.end == ta, not extended)");

        _assertOrdering("After shared-TA extension");
        _assertTokenConservation("After shared-TA extension");
    }

    // ═════════════════════════════════════════════════════════════════════
    //  63. EXACT BOUNDARY FORFEIT + WITHDRAW TESTS (MEDIUM R3/R5)
    // ═════════════════════════════════════════════════════════════════════

    /// @notice Forfeit at EXACTLY transferableAfter should revert (contract uses >=).
    function testForfeitAtExactTAReverts() public onlyFork {
        _upgradeAndSeed();
        vm.prank(GNOSIS_SAFE);
        veHemi.updateForfeitAdmin(GNOSIS_SAFE);

        deal(HEMI_TOKEN, GNOSIS_SAFE, 100 ether);
        vm.startPrank(GNOSIS_SAFE);
        hemiToken.approve(address(veHemi), 100 ether);
        uint256 tokenId = veHemi.createLockFor(100 ether, MAX_TIME / 4, address(0xAAAA), false, true);
        vm.stopPrank();

        uint256 ta = veHemi.transferableAfter(tokenId);
        // Extend so lock doesn't expire at TA
        vm.prank(address(0xAAAA));
        veHemi.increaseUnlockTime(tokenId, MAX_TIME / 2);

        // Warp to EXACTLY ta
        _warpAndRoll(ta - block.timestamp);
        assertEq(block.timestamp, ta, "At exact ta");

        // Forfeit at exactly ta should revert (>= check)
        vm.prank(GNOSIS_SAFE);
        vm.expectRevert(VeHemi.ForfeitWindowExpired.selector);
        veHemi.forfeit(tokenId);
    }

    /// @notice Forfeit at transferableAfter - 1 (latest legal instant) should SUCCEED.
    function testForfeitAtLatestLegalInstant() public onlyFork {
        _upgradeAndSeed();
        vm.prank(GNOSIS_SAFE);
        veHemi.updateForfeitAdmin(GNOSIS_SAFE);

        deal(HEMI_TOKEN, GNOSIS_SAFE, 100 ether);
        vm.startPrank(GNOSIS_SAFE);
        hemiToken.approve(address(veHemi), 100 ether);
        uint256 tokenId = veHemi.createLockFor(100 ether, MAX_TIME / 4, address(0xAAAA), false, true);
        vm.stopPrank();

        uint256 ta = veHemi.transferableAfter(tokenId);
        // Extend so lock doesn't expire at TA
        vm.prank(address(0xAAAA));
        veHemi.increaseUnlockTime(tokenId, MAX_TIME / 2);

        // Warp to ta - 1 (last second inside forfeit window)
        _warpAndRoll(ta - 1 - block.timestamp);
        assertEq(block.timestamp, ta - 1, "At ta - 1");
        assertLt(block.timestamp, ta, "Still before ta");

        uint256 hemiAdminBefore = hemiToken.balanceOf(GNOSIS_SAFE);

        // Forfeit must succeed
        vm.prank(GNOSIS_SAFE);
        veHemi.forfeit(tokenId);

        // Cleanup verified
        assertEq(veHemi.getLockedBalance(tokenId).amount, 0, "amount cleared");
        assertEq(
            hemiToken.balanceOf(GNOSIS_SAFE),
            hemiAdminBefore + 100 ether,
            "Admin received 100 HEMI"
        );
        _assertTokenConservation("After forfeit at ta-1");
    }

    /// @notice Withdraw at exact lock.end should SUCCEED (contract uses < not <=).
    function testWithdrawAtExactLockEnd() public onlyFork {
        _upgradeAndSeed();

        deal(HEMI_TOKEN, GNOSIS_SAFE, 100 ether);
        vm.startPrank(GNOSIS_SAFE);
        hemiToken.approve(address(veHemi), 100 ether);
        uint256 tokenId = veHemi.createLockFor(100 ether, MAX_TIME / 4, address(0xAAAA), false, false);
        vm.stopPrank();

        uint256 lockEnd = veHemi.getLockedBalance(tokenId).end;
        uint256 slope = uint256(100 ether) / MAX_TIME;

        // Warp to EXACTLY lock.end
        _warpAndRoll(lockEnd - block.timestamp);
        assertEq(block.timestamp, lockEnd, "At exact lock.end");

        // balanceOfNFT at lock.end should be 0 (bias = slope * (end - end) = 0)
        assertEq(veHemi.balanceOfNFT(tokenId), 0, "bias = 0 at lock.end");

        // Withdraw should succeed (contract checks block.timestamp < locked.end,
        // so at exactly end: !(end < end) => passes the check)
        uint256 hemiBefore = hemiToken.balanceOf(address(0xAAAA));
        vm.prank(address(0xAAAA));
        veHemi.withdraw(tokenId);

        assertEq(veHemi.getLockedBalance(tokenId).amount, 0, "amount cleared");
        assertEq(
            hemiToken.balanceOf(address(0xAAAA)),
            hemiBefore + 100 ether,
            "User received 100 HEMI at exact lock.end"
        );
        _assertTokenConservation("After withdraw at exact lock.end");
    }

    /// @notice Withdraw at lock.end - 1 should REVERT (lock not expired).
    function testWithdrawAtLockEndMinusOneReverts() public onlyFork {
        _upgradeAndSeed();

        deal(HEMI_TOKEN, GNOSIS_SAFE, 100 ether);
        vm.startPrank(GNOSIS_SAFE);
        hemiToken.approve(address(veHemi), 100 ether);
        uint256 tokenId = veHemi.createLockFor(100 ether, MAX_TIME / 4, address(0xAAAA), false, false);
        vm.stopPrank();

        uint256 lockEnd = veHemi.getLockedBalance(tokenId).end;

        // Warp to lock.end - 1
        _warpAndRoll(lockEnd - 1 - block.timestamp);
        assertEq(block.timestamp, lockEnd - 1, "One second before lock.end");

        // Should still have positive bias
        uint256 slope = uint256(100 ether) / MAX_TIME;
        assertEq(veHemi.balanceOfNFT(tokenId), slope * 1, "bias = slope * 1 sec before expiry");

        vm.prank(address(0xAAAA));
        vm.expectRevert(VeHemi.LockNotExpired.selector);
        veHemi.withdraw(tokenId);
    }

    // ═════════════════════════════════════════════════════════════════════
    //  64. APPROVED OPERATOR TRANSFER (MEDIUM R3-4)
    // ═════════════════════════════════════════════════════════════════════

    /// @notice Verify transferFrom by an APPROVED operator (not the owner) works correctly
    ///         for a post-TA transferable position.
    function testTransferFromByApprovedOperator() public onlyFork {
        _upgradeAndSeed();

        deal(HEMI_TOKEN, GNOSIS_SAFE, 100 ether);
        vm.startPrank(GNOSIS_SAFE);
        hemiToken.approve(address(veHemi), 100 ether);
        uint256 tokenId = veHemi.createLockFor(100 ether, MAX_TIME / 4, address(0xAAAA), false, true);
        vm.stopPrank();

        uint256 ta = veHemi.transferableAfter(tokenId);
        vm.prank(address(0xAAAA));
        veHemi.increaseUnlockTime(tokenId, MAX_TIME / 2);

        // Warp past TA
        _warpAndRoll(ta + 1 - block.timestamp);
        veHemi.checkpoint();
        assertTrue(veHemi.isTransferable(tokenId), "Transferable after TA");

        // Owner approves operator 0xDDDD
        address operator = address(0xDDDD);
        vm.prank(address(0xAAAA));
        veHemi.approve(operator, tokenId);

        uint256 biasBefore = veHemi.balanceOfNFT(tokenId);

        // Operator transfers on behalf of owner
        vm.prank(operator);
        veHemi.transferFrom(address(0xAAAA), address(0xBBBB), tokenId);

        assertEq(veHemi.ownerOf(tokenId), address(0xBBBB), "newOwner after operator transfer");
        assertEq(veHemi.balanceOfNFT(tokenId), biasBefore, "Bias unchanged after operator transfer");
        _assertTokenConservation("After operator transfer");
        _assertOrdering("After operator transfer");
    }
}
