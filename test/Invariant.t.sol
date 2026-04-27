// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import "forge-std/Test.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {VeHemi} from "src/VeHemi.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {VeHemiVoteDelegation} from "src/VeHemiVoteDelegation.sol";
import {InvariantHandler} from "./InvariantHandler.sol";

contract InvariantTest is Test {
    using SafeCast for int128;

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
        assertEq(locked_, veHemi.nonTransferableTotalVeHemiSupply(), "breakdown non-transferable != nonTransferableTotalVeHemiSupply");
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
        // Slot 18: nonTransferableSeedingFinalized (bool at offset 0, low byte only).
        // Masking to the low byte makes this assertion robust to a future
        // pack that adds another small field into the same slot.
        bool rawSeedFlag = (uint256(vm.load(address(veHemi), bytes32(uint256(18)))) & 0xff) != 0;
        assertEq(rawSeedFlag, veHemi.nonTransferableSeedingFinalized(), "slot 18 (nonTransferableSeedingFinalized) decoupled");
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

    /// @dev Storage-gap integrity: V2's `__gapV2[43]` occupies slots 21–63. They must remain
    ///      zero under all handler operations. Any non-zero slot in this range indicates a
    ///      write ran off the end of a named field (would happen if a struct size calculation
    ///      were wrong or storage was written beyond a mapping's expected layout).
    function invariant_gapSlotsZero() public view {
        for (uint256 i = 21; i <= 63; ++i) {
            assertEq(
                vm.load(address(veHemi), bytes32(i)),
                bytes32(0),
                string.concat("V2 gap slot ", vm.toString(i), " corrupted")
            );
        }
    }
}
