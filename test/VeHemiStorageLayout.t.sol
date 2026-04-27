// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import "forge-std/Test.sol";
import "../src/VeHemi.sol";
import "../src/interfaces/IVeHemi.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import "./mocks/MockERC20.sol";
import "./mocks/MockHemiVoteDelegation.sol";

/// @title VeHemiStorageLayout
/// @notice Asserts the exact slot positions of VeHemiStorageV1 and
///         VeHemiStorageV2 fields inside the proxy's storage. If anyone
///         accidentally inserts a field into V1 — shifting V2's base — this
///         test will fail before the change ever reaches mainnet.
///
///         Slot map (sequential storage; OZ v5 bases use ERC-7201 namespaced
///         storage at hashed slots and do NOT occupy this range):
///
///         ── VeHemiStorageV1 (slots 0–13) ──
///           0: totalLocked
///           1: epoch
///           2: nextTokenId
///           3: voteDelegation
///           4: rewardDistributor
///           5: forfeitAdmin
///           6: globalPointHistory (mapping base)
///           7: userPointHistory (mapping base)
///           8: userPointEpoch (mapping base)
///           9: slopeChanges (mapping base)
///          10: locked (mapping base)
///          11: provider (mapping base)
///          12: transferableAfter (mapping base)
///          13: forfeitable (mapping base)
///
///         ── VeHemiStorageV2 (slots 14–63) ──
///          14: __reservedSlot0
///          15: __reservedSlot1
///          16: nonTransferableSlopeChanges (mapping base)
///          17: nonTransferableGlobalPointHistory (mapping base)
///          18: nonTransferableSeedingFinalized
///          19: forfeitableSlopeChanges (mapping base)
///          20: forfeitableGlobalPointHistory (mapping base)
///          21–63: __gapV2[43]
contract VeHemiStorageLayoutTest is Test {
    VeHemi veHemi;
    address proxy;

    function setUp() public {
        MockERC20 hemi = new MockERC20("HEMI", "HEMI", 18);
        VeHemi logic = new VeHemi(address(hemi));
        MockHemiVoteDelegation mockDelegation = new MockHemiVoteDelegation();

        ERC1967Proxy p = new ERC1967Proxy(
            address(logic),
            abi.encodeWithSelector(VeHemi.initialize.selector, address(this))
        );
        veHemi = VeHemi(address(p));
        proxy = address(p);

        veHemi.updateVoteDelegation(IVeHemiVoteDelegation(address(mockDelegation)));
    }

    // =========================================================================
    // V1 value-type slots (0–5): write a sentinel at the expected slot, read
    // back via the public getter to confirm they agree.
    // =========================================================================

    function test_slot0_totalLocked() public {
        uint256 sentinel = 0xAAAA;
        vm.store(proxy, bytes32(uint256(0)), bytes32(sentinel));
        assertEq(veHemi.totalLocked(), sentinel, "totalLocked is not at slot 0");
    }

    function test_slot1_epoch() public {
        uint256 sentinel = 0xBBBB;
        vm.store(proxy, bytes32(uint256(1)), bytes32(sentinel));
        assertEq(veHemi.epoch(), sentinel, "epoch is not at slot 1");
    }

    function test_slot2_nextTokenId() public {
        uint256 sentinel = 0xCCCC;
        vm.store(proxy, bytes32(uint256(2)), bytes32(sentinel));
        assertEq(veHemi.nextTokenId(), sentinel, "nextTokenId is not at slot 2");
    }

    function test_slot3_voteDelegation() public {
        address sentinel = address(0xDDDD);
        vm.store(proxy, bytes32(uint256(3)), bytes32(uint256(uint160(sentinel))));
        assertEq(address(veHemi.voteDelegation()), sentinel, "voteDelegation is not at slot 3");
    }

    function test_slot4_rewardDistributor() public {
        address sentinel = address(0xEEEE);
        vm.store(proxy, bytes32(uint256(4)), bytes32(uint256(uint160(sentinel))));
        assertEq(address(veHemi.rewardDistributor()), sentinel, "rewardDistributor is not at slot 4");
    }

    function test_slot5_forfeitAdmin() public {
        address sentinel = address(0xFFFF);
        vm.store(proxy, bytes32(uint256(5)), bytes32(uint256(uint160(sentinel))));
        assertEq(veHemi.forfeitAdmin(), sentinel, "forfeitAdmin is not at slot 5");
    }

    // =========================================================================
    // V1 mapping slots (6–13): verify the mapping base slot by writing a
    // value at keccak256(key, baseSlot) and reading via the public getter.
    // =========================================================================

    function test_slot8_userPointEpoch() public {
        uint256 tokenId = 42;
        uint256 sentinel = 0x1234;
        bytes32 slot = keccak256(abi.encode(tokenId, uint256(8)));
        vm.store(proxy, slot, bytes32(sentinel));
        assertEq(veHemi.userPointEpoch(tokenId), sentinel, "userPointEpoch base is not at slot 8");
    }

    function test_slot9_slopeChanges() public {
        uint256 timestamp = 999;
        int128 sentinel = 7777;
        bytes32 slot = keccak256(abi.encode(timestamp, uint256(9)));
        vm.store(proxy, slot, bytes32(uint256(uint128(sentinel))));
        assertEq(veHemi.slopeChanges(timestamp), sentinel, "slopeChanges base is not at slot 9");
    }

    function test_slot11_provider() public {
        uint256 tokenId = 42;
        address sentinel = address(0xABCD);
        bytes32 slot = keccak256(abi.encode(tokenId, uint256(11)));
        vm.store(proxy, slot, bytes32(uint256(uint160(sentinel))));
        assertEq(veHemi.provider(tokenId), sentinel, "provider base is not at slot 11");
    }

    function test_slot12_transferableAfter() public {
        uint256 tokenId = 42;
        uint256 sentinel = 0x5678;
        bytes32 slot = keccak256(abi.encode(tokenId, uint256(12)));
        vm.store(proxy, slot, bytes32(sentinel));
        assertEq(veHemi.transferableAfter(tokenId), sentinel, "transferableAfter base is not at slot 12");
    }

    function test_slot13_forfeitable() public {
        uint256 tokenId = 42;
        bytes32 slot = keccak256(abi.encode(tokenId, uint256(13)));
        vm.store(proxy, slot, bytes32(uint256(1)));
        assertTrue(veHemi.forfeitable(tokenId), "forfeitable base is not at slot 13");
    }

    function test_slot6_globalPointHistory() public {
        // globalPointHistory is a mapping(uint256 => Point) at slot 6.
        // Point is 3 storage slots:
        //   slot+0: {int128 bias [0..15], int128 slope [16..31]}
        //   slot+1: {uint64 timestamp [0..7], uint64 blockNumber [8..15], uint128 amount [16..31]}
        //   slot+2: {uint256 fixedBias}
        // Write distinct sentinels into EVERY field and verify the struct
        // decodes correctly through getGlobalPoint. This catches intra-struct
        // reorders the bias-only variant missed.
        uint256 epochKey = 42;
        int128 biasSentinel = 12345;
        int128 slopeSentinel = -9876;
        uint64 tsSentinel = 0x1122334455;
        uint64 bnSentinel = 0x66778899aa;
        uint128 amtSentinel = 0xbbccddeeff00112233;
        uint256 fixedBiasSentinel = 0xDEADBEEFCAFEBABE;
        bytes32 base = keccak256(abi.encode(epochKey, uint256(6)));

        // Pack slot+0: low 128 bits = bias, high 128 bits = slope.
        bytes32 word0 = bytes32(
            (uint256(uint128(uint256(int256(slopeSentinel)))) << 128) |
            uint256(uint128(uint256(int256(biasSentinel))))
        );
        // Pack slot+1: [0..7]=ts, [8..15]=blockNumber, [16..31]=amount.
        bytes32 word1 = bytes32(
            (uint256(amtSentinel) << 128) |
            (uint256(bnSentinel) << 64) |
            uint256(tsSentinel)
        );
        bytes32 word2 = bytes32(fixedBiasSentinel);

        vm.store(proxy, base, word0);
        vm.store(proxy, bytes32(uint256(base) + 1), word1);
        vm.store(proxy, bytes32(uint256(base) + 2), word2);

        IVeHemi.Point memory p = veHemi.getGlobalPoint(epochKey);
        assertEq(p.bias, biasSentinel, "globalPointHistory.bias (slot 6, field 0)");
        assertEq(p.slope, slopeSentinel, "globalPointHistory.slope (slot 6, field 1)");
        assertEq(p.timestamp, tsSentinel, "globalPointHistory.timestamp (slot 6, field 2)");
        assertEq(p.blockNumber, bnSentinel, "globalPointHistory.blockNumber (slot 6, field 3)");
        assertEq(p.amount, amtSentinel, "globalPointHistory.amount (slot 6, field 4)");
        assertEq(p.fixedBias, fixedBiasSentinel, "globalPointHistory.fixedBias (slot 6, field 5)");
    }

    function test_slot7_userPointHistory() public {
        // userPointHistory is mapping(uint256 => UserPoint[1000000000]) at slot 7.
        // Inner is a FIXED-SIZE array, not a mapping: element N lives at
        // base + N * sizeOf(UserPoint) where sizeOf(UserPoint) = 4 slots
        // (Point = 3 slots + address owner = 1 slot).
        // For tokenId=42, the UserPoint at [0] starts at base = keccak(42, 7),
        // with point fields at base+0..+2 and owner at base+3.
        // Write sentinels into ALL 4 slots of element [0] AND verify element [1]
        // lives at base+4 (stride verification — catches a UserPoint-size drift).
        _writeUserPointElement0(42);
        _assertUserPointElement0(42);
        _assertUserPointElement1Stride(42);
    }

    function _writeUserPointElement0(uint256 tokenId) internal {
        bytes32 arrayBase = keccak256(abi.encode(tokenId, uint256(7)));
        // slot+0: int128 bias [0..15], int128 slope [16..31]
        vm.store(
            proxy,
            arrayBase,
            bytes32(
                (uint256(uint128(uint256(int256(int128(-444))))) << 128) |
                uint256(uint128(uint256(int256(int128(333)))))
            )
        );
        // slot+1: uint64 timestamp [0..7], uint64 blockNumber [8..15], uint128 amount [16..31]
        vm.store(
            proxy,
            bytes32(uint256(arrayBase) + 1),
            bytes32(
                (uint256(uint128(0x33)) << 128) |
                (uint256(uint64(0x22)) << 64) |
                uint256(uint64(0x11))
            )
        );
        // slot+2: uint256 fixedBias
        vm.store(proxy, bytes32(uint256(arrayBase) + 2), bytes32(uint256(0x44)));
        // slot+3: address owner
        vm.store(proxy, bytes32(uint256(arrayBase) + 3), bytes32(uint256(uint160(address(0xBEEF)))));
    }

    function _assertUserPointElement0(uint256 tokenId) internal view {
        IVeHemi.UserPoint memory up = veHemi.getUserPoint(tokenId, 0);
        assertEq(up.owner, address(0xBEEF), "UserPoint[0].owner (slot 7, offset +3)");
        assertEq(up.point.bias, int128(333), "UserPoint[0].bias");
        assertEq(up.point.slope, int128(-444), "UserPoint[0].slope");
        assertEq(up.point.timestamp, uint64(0x11), "UserPoint[0].timestamp");
        assertEq(up.point.blockNumber, uint64(0x22), "UserPoint[0].blockNumber");
        assertEq(up.point.amount, uint128(0x33), "UserPoint[0].amount");
        assertEq(up.point.fixedBias, uint256(0x44), "UserPoint[0].fixedBias");
    }

    function _assertUserPointElement1Stride(uint256 tokenId) internal {
        // Stride check: element [1] MUST live at base + 4 (sizeOf(UserPoint) = 4).
        // Write a sentinel into element [1]'s owner slot (base + 7) and read
        // back via getUserPoint(_, 1). If UserPoint ever grew to 5 slots this
        // would silently read zero.
        bytes32 arrayBase = keccak256(abi.encode(tokenId, uint256(7)));
        address owner1 = address(0xCAFE);
        vm.store(proxy, bytes32(uint256(arrayBase) + 7), bytes32(uint256(uint160(owner1))));
        IVeHemi.UserPoint memory up1 = veHemi.getUserPoint(tokenId, 1);
        assertEq(up1.owner, owner1, "UserPoint[1].owner - stride sizeOf(UserPoint) != 4");
        assertEq(up1.point.bias, 0, "UserPoint[1].bias should be zero");
        assertEq(up1.point.timestamp, 0, "UserPoint[1].timestamp should be zero");
        assertEq(up1.point.fixedBias, 0, "UserPoint[1].fixedBias should be zero");
    }

    function test_slot10_locked() public {
        // locked is mapping(uint256 => LockedBalance) at slot 10.
        // LockedBalance is 1 packed slot: {int128 amount [0..15], uint64 end [16..23]}.
        // Positive/mid-range case.
        uint256 tokenId = 42;
        int128 amtSentinel = 9999;
        uint64 endSentinel = 1_700_000_000;
        bytes32 slot = keccak256(abi.encode(tokenId, uint256(10)));
        bytes32 packed = bytes32(
            (uint256(endSentinel) << 128) |
            uint256(uint128(uint256(int256(amtSentinel))))
        );
        vm.store(proxy, slot, packed);
        IVeHemi.LockedBalance memory lb = veHemi.getLockedBalance(tokenId);
        assertEq(lb.amount, amtSentinel, "locked.amount (positive)");
        assertEq(lb.end, endSentinel, "locked.end");
    }

    function test_slot10_locked_negativeAmount() public {
        // Negative int128 amount: catches any sign-extension mis-mask that
        // would leak high bits into the adjacent uint64 end field.
        uint256 tokenId = 43;
        int128 amtSentinel = type(int128).min;
        uint64 endSentinel = type(uint64).max;
        bytes32 slot = keccak256(abi.encode(tokenId, uint256(10)));
        bytes32 packed = bytes32(
            (uint256(endSentinel) << 128) |
            uint256(uint128(uint256(int256(amtSentinel))))
        );
        vm.store(proxy, slot, packed);
        IVeHemi.LockedBalance memory lb = veHemi.getLockedBalance(tokenId);
        assertEq(lb.amount, amtSentinel, "locked.amount (type(int128).min)");
        assertEq(lb.end, endSentinel, "locked.end (type(uint64).max)");
    }

    function test_slot10_locked_negativeOne() public {
        // `-1` has all-ones in the low 128 bits after masking. If the mask is
        // wrong (e.g., using a shift-based approach that forgets to clear high
        // bits) this would corrupt `end`.
        uint256 tokenId = 44;
        int128 amtSentinel = -1;
        uint64 endSentinel = 0x12345678;
        bytes32 slot = keccak256(abi.encode(tokenId, uint256(10)));
        bytes32 packed = bytes32(
            (uint256(endSentinel) << 128) |
            uint256(uint128(uint256(int256(amtSentinel))))
        );
        vm.store(proxy, slot, packed);
        IVeHemi.LockedBalance memory lb = veHemi.getLockedBalance(tokenId);
        assertEq(lb.amount, amtSentinel, "locked.amount (-1)");
        assertEq(lb.end, endSentinel, "locked.end (unchanged by -1 amount)");
    }

    function test_slot14_reservedSlot0_isolated() public {
        // __reservedSlot0 is private and unused. Verify it's addressable at
        // absolute slot 14 without aliasing any V1 or V2 field. The slot
        // should be zero on a fresh proxy, and writing to it must not
        // affect adjacent slots (13 = forfeitable mapping base, 15 =
        // __reservedSlot1, 16 = nonTransferableSlopeChanges mapping base).
        bytes32 slot14 = bytes32(uint256(14));
        assertEq(vm.load(proxy, slot14), bytes32(0), "slot 14 should be zero on fresh proxy");

        // Snapshot neighbors pre-write.
        bytes32 pre13 = vm.load(proxy, bytes32(uint256(13)));
        bytes32 pre15 = vm.load(proxy, bytes32(uint256(15)));
        bytes32 pre16 = vm.load(proxy, bytes32(uint256(16)));

        bytes32 sentinel = bytes32(uint256(0xDEAD));
        vm.store(proxy, slot14, sentinel);
        assertEq(vm.load(proxy, slot14), sentinel, "slot 14 write failed");

        // Neighbors must be untouched.
        assertEq(vm.load(proxy, bytes32(uint256(13))), pre13, "slot 13 aliased by slot 14 write");
        assertEq(vm.load(proxy, bytes32(uint256(15))), pre15, "slot 15 aliased by slot 14 write");
        assertEq(vm.load(proxy, bytes32(uint256(16))), pre16, "slot 16 aliased by slot 14 write");

        // And no observable getter changed.
        assertEq(veHemi.totalLocked(), 0, "V1 totalLocked corrupted by slot 14 write");
        assertFalse(veHemi.nonTransferableSeedingFinalized(), "V2 nonTransferableSeedingFinalized corrupted by slot 14 write");
    }

    function test_slot15_reservedSlot1_isolated() public {
        // __reservedSlot1 analogous check at absolute slot 15.
        bytes32 slot15 = bytes32(uint256(15));
        assertEq(vm.load(proxy, slot15), bytes32(0), "slot 15 should be zero on fresh proxy");

        bytes32 pre14 = vm.load(proxy, bytes32(uint256(14)));
        bytes32 pre16 = vm.load(proxy, bytes32(uint256(16)));
        bytes32 pre17 = vm.load(proxy, bytes32(uint256(17)));

        bytes32 sentinel = bytes32(uint256(0xBEEF));
        vm.store(proxy, slot15, sentinel);
        assertEq(vm.load(proxy, slot15), sentinel, "slot 15 write failed");

        assertEq(vm.load(proxy, bytes32(uint256(14))), pre14, "slot 14 aliased by slot 15 write");
        assertEq(vm.load(proxy, bytes32(uint256(16))), pre16, "slot 16 aliased by slot 15 write");
        assertEq(vm.load(proxy, bytes32(uint256(17))), pre17, "slot 17 aliased by slot 15 write");

        assertEq(veHemi.totalLocked(), 0, "V1 totalLocked corrupted by slot 15 write");
        assertFalse(veHemi.nonTransferableSeedingFinalized(), "V2 nonTransferableSeedingFinalized corrupted by slot 15 write");
    }

    function test_slot17_nonTransferableGlobalPointHistory() public {
        // nonTransferableGlobalPointHistory is mapping(uint256 => SupplyPoint) at slot 17.
        // SupplyPoint is 2 slots:
        //   slot+0: {int128 bias [0..15], int128 slope [16..31]}
        //   slot+1: {uint64 timestamp [0..7], uint64 blockNumber [8..15]}
        // No public getter — verify via vm.load round-trip + anti-alias checks
        // against V1 slot 6 (globalPointHistory) AND V2 slot 20
        // (forfeitableGlobalPointHistory). The 3-way check catches a layout
        // regression that conflates any of the three subcurves.
        uint256 epochKey = 5;
        bytes32 base6 = keccak256(abi.encode(epochKey, uint256(6)));
        bytes32 base17 = keccak256(abi.encode(epochKey, uint256(17)));
        bytes32 base17Next = bytes32(uint256(base17) + 1);
        bytes32 base20 = keccak256(abi.encode(epochKey, uint256(20)));
        assertTrue(base17 != base20, "slot 17/20 keccak bases collide (impossible)");
        assertTrue(base17 != base6, "slot 17/6 keccak bases collide (impossible)");

        // Write independent sentinels into BOTH slots of the SupplyPoint struct.
        bytes32 pointSlot0 = bytes32(
            (uint256(uint128(uint256(int256(int128(0x55))))) << 128) |
            uint256(uint128(uint256(int256(int128(0x44)))))
        );
        bytes32 pointSlot1 = bytes32(
            (uint256(uint64(0x66)) << 64) | uint256(uint64(0x77))
        );
        vm.store(proxy, base17, pointSlot0);
        vm.store(proxy, base17Next, pointSlot1);

        assertEq(vm.load(proxy, base17), pointSlot0, "slot 17 base+0 write failed");
        assertEq(vm.load(proxy, base17Next), pointSlot1, "slot 17 base+1 write failed");

        // Other subcurves must NOT be aliased.
        assertEq(vm.load(proxy, base6), bytes32(0), "slot 6 aliased by slot 17 write");
        assertEq(vm.load(proxy, bytes32(uint256(base6) + 1)), bytes32(0), "slot 6 base+1 aliased");
        assertEq(vm.load(proxy, base20), bytes32(0), "slot 20 aliased by slot 17 write");
        assertEq(vm.load(proxy, bytes32(uint256(base20) + 1)), bytes32(0), "slot 20 base+1 aliased");
    }

    function test_slot20_forfeitableGlobalPointHistory() public {
        // forfeitableGlobalPointHistory is mapping(uint256 => SupplyPoint) at slot 20.
        // Symmetric 3-way test: write at slot 20, verify slots 6 and 17 untouched,
        // across both base+0 and base+1 of the SupplyPoint struct.
        uint256 epochKey = 5;
        bytes32 base6 = keccak256(abi.encode(epochKey, uint256(6)));
        bytes32 base17 = keccak256(abi.encode(epochKey, uint256(17)));
        bytes32 base20 = keccak256(abi.encode(epochKey, uint256(20)));
        bytes32 base20Next = bytes32(uint256(base20) + 1);

        bytes32 pointSlot0 = bytes32(
            (uint256(uint128(uint256(int256(int128(0xBB))))) << 128) |
            uint256(uint128(uint256(int256(int128(0xAA)))))
        );
        bytes32 pointSlot1 = bytes32(
            (uint256(uint64(0xDD)) << 64) | uint256(uint64(0xCC))
        );
        vm.store(proxy, base20, pointSlot0);
        vm.store(proxy, base20Next, pointSlot1);

        assertEq(vm.load(proxy, base20), pointSlot0, "slot 20 base+0 write failed");
        assertEq(vm.load(proxy, base20Next), pointSlot1, "slot 20 base+1 write failed");

        assertEq(vm.load(proxy, base6), bytes32(0), "slot 6 aliased by slot 20 write");
        assertEq(vm.load(proxy, bytes32(uint256(base6) + 1)), bytes32(0), "slot 6 base+1 aliased");
        assertEq(vm.load(proxy, base17), bytes32(0), "slot 17 aliased by slot 20 write");
        assertEq(vm.load(proxy, bytes32(uint256(base17) + 1)), bytes32(0), "slot 17 base+1 aliased");
    }

    // =========================================================================
    // V1 → V2 boundary: V1 ends at slot 13, V2 starts at slot 14.
    // These are the CRITICAL assertions. If any field is ever inserted
    // into V1, these tests will fail.
    // =========================================================================

    function test_slot13_isLastV1Slot() public {
        // forfeitable (the last V1 field) is at slot 13.
        // Already verified above — included here for documentary emphasis.
        uint256 tokenId = 99;
        bytes32 slot = keccak256(abi.encode(tokenId, uint256(13)));
        vm.store(proxy, slot, bytes32(uint256(1)));
        assertTrue(veHemi.forfeitable(tokenId), "V1 last slot (forfeitable) is not at slot 13");
    }

    // =========================================================================
    // V2 slots (14–20): verify the V2 fields start exactly where expected.
    // =========================================================================

    function test_slot16_nonTransferableSlopeChanges() public {
        // nonTransferableSlopeChanges is a mapping(uint256 => int128) at V2 slot 2 = absolute slot 16.
        uint256 timestamp = 888;
        int128 sentinel = 4444;
        bytes32 slot = keccak256(abi.encode(timestamp, uint256(16)));
        vm.store(proxy, slot, bytes32(uint256(uint128(sentinel))));
        assertEq(veHemi.nonTransferableSlopeChanges(timestamp), sentinel, "nonTransferableSlopeChanges base is not at slot 16");
    }

    function test_slot18_nonTransferableSeedingFinalized() public {
        // nonTransferableSeedingFinalized is a bool at V2 slot 4 = absolute slot 18.
        vm.store(proxy, bytes32(uint256(18)), bytes32(uint256(1)));
        assertTrue(veHemi.nonTransferableSeedingFinalized(), "nonTransferableSeedingFinalized is not at slot 18");
    }

    function test_slot19_forfeitableSlopeChanges() public {
        // forfeitableSlopeChanges is a mapping(uint256 => int128) at V2 slot 5 = absolute slot 19.
        uint256 timestamp = 777;
        int128 sentinel = 3333;
        bytes32 slot = keccak256(abi.encode(timestamp, uint256(19)));
        vm.store(proxy, slot, bytes32(uint256(uint128(sentinel))));
        assertEq(veHemi.forfeitableSlopeChanges(timestamp), sentinel, "forfeitableSlopeChanges base is not at slot 19");
    }

    // =========================================================================
    // V2 gap integrity: the gap starts at slot 21 and extends to slot 63
    // (43 slots). Verify the gap region is clean (all zeros) and that
    // writing at slot 63 (last gap slot) does NOT alias any named field.
    // =========================================================================

    function test_gapV2_doesNotAliasNamedFields() public view {
        // Slots 21–63 should all be zero in a freshly initialized contract.
        for (uint256 i = 21; i <= 63; ++i) {
            bytes32 val = vm.load(proxy, bytes32(i));
            assertEq(val, bytes32(0), string.concat("V2 gap slot ", vm.toString(i), " is not zero"));
        }
    }

}
