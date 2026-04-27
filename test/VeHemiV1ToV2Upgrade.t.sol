// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import "forge-std/Test.sol";
import "../src/VeHemi.sol";
import "../src/interfaces/IVeHemi.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import "./mocks/MockERC20.sol";
import "./mocks/MockHemiVoteDelegation.sol";

/// @title VeHemiV1ToV2UpgradeTest
/// @notice Sentinel-based V1→V2 upgrade regression test.
///
///         Strategy: deploy the current V2 implementation behind a proxy,
///         populate every V1 storage slot (0–13) and V2 slot (14–20) with
///         distinct sentinel values via `vm.store`, then upgrade the proxy
///         to a FRESH V2 implementation and verify every sentinel is still
///         readable at the same slot through the same public getter.
///
///         This catches ANY storage-layout regression — most importantly the
///         class of bug introduced by reordering the inheritance base list
///         (which was the motivation for switching from sibling to chain
///         inheritance per Manoj's review comment).
///
///         This is complementary to VeHemiStorageLayout.t.sol (which tests
///         slot positions against fresh-deploy state) and ForkUpgradeNonTransferableCurve.t.sol
///         (which tests against live mainnet state). This test is CI-safe,
///         hermetic, and runs in milliseconds.
contract VeHemiV1ToV2UpgradeTest is Test {
    MockERC20 hemi;
    MockHemiVoteDelegation mockDelegation;
    VeHemi v2Impl1;
    VeHemi v2Impl2;
    address proxy;
    VeHemi veHemi;

    // Sentinel values for each V1 slot. Distinct sequential constants so any
    // accidental aliasing surfaces cleanly.
    uint256 constant TOTAL_LOCKED_SENTINEL = 0xA1;
    uint256 constant EPOCH_SENTINEL = 0xA2;
    uint256 constant NEXT_TOKEN_ID_SENTINEL = 0xA3;
    address constant VOTE_DELEGATION_SENTINEL = address(0xA4);
    address constant REWARD_DISTRIBUTOR_SENTINEL = address(0xA5);
    address constant FORFEIT_ADMIN_SENTINEL = address(0xA6);

    // Mapping sentinel keys/values.
    uint256 constant TEST_TOKEN_ID = 12345;
    uint256 constant TEST_TIMESTAMP = 67890;

    function setUp() public {
        hemi = new MockERC20("HEMI", "HEMI", 18);
        mockDelegation = new MockHemiVoteDelegation();

        v2Impl1 = new VeHemi(address(hemi));
        v2Impl2 = new VeHemi(address(hemi));

        ERC1967Proxy p = new ERC1967Proxy(
            address(v2Impl1),
            abi.encodeWithSelector(VeHemi.initialize.selector, address(this))
        );
        proxy = address(p);
        veHemi = VeHemi(proxy);
        veHemi.updateVoteDelegation(IVeHemiVoteDelegation(address(mockDelegation)));
    }

    // =========================================================================
    // Core round-trip test: write sentinels → upgrade → verify sentinels.
    // =========================================================================

    function test_V1SlotsSurviveUpgradeBetweenV2Implementations() public {
        _writeV1Sentinels();
        _upgradeTo(address(v2Impl2));
        _assertV1Sentinels();
    }

    function test_V2SlotsSurviveUpgradeBetweenV2Implementations() public {
        _writeV2Sentinels();
        _upgradeTo(address(v2Impl2));
        _assertV2Sentinels();
    }

    function test_AllSlotsSurviveUpgrade() public {
        _writeV1Sentinels();
        _writeV2Sentinels();
        _upgradeTo(address(v2Impl2));
        _assertV1Sentinels();
        _assertV2Sentinels();
    }

    function test_GapSlotsRemainZeroAfterUpgrade() public {
        // V2's __gapV2 occupies slots 21–63. Before upgrade, they're zero.
        // After upgrade, they should still be zero (upgrade doesn't touch
        // storage except via the new implementation's code paths).
        _writeV1Sentinels();
        _writeV2Sentinels();
        _upgradeTo(address(v2Impl2));
        for (uint256 i = 21; i <= 63; ++i) {
            assertEq(
                vm.load(proxy, bytes32(i)),
                bytes32(0),
                string.concat("gap slot ", vm.toString(i), " corrupted by upgrade")
            );
        }
    }

    function test_UpgradeDoesNotResetInitializedFlag() public {
        // The proxy was initialized with the first implementation. Upgrading
        // to the same contract version must NOT allow re-initialization.
        _upgradeTo(address(v2Impl2));
        vm.expectRevert(
            abi.encodeWithSignature("InvalidInitialization()")
        );
        veHemi.initialize(address(this));
    }

    /// @dev Front-run defense: between upgrade (Safe tx 2) and seed (Safe tx 3),
    ///      attackers must not be able to race in an `initialize(attacker)` call.
    ///      OZ v5's `initializer` modifier consumed the slot in setUp, so every
    ///      such attempt must revert with InvalidInitialization regardless of caller.
    function test_UpgradeThenInitializeFrontRun_Reverts() public {
        address preUpgradeOwner = veHemi.owner();
        _upgradeTo(address(v2Impl2));

        address[] memory attackers = new address[](4);
        attackers[0] = makeAddr("attacker1");
        attackers[1] = makeAddr("attacker2");
        attackers[2] = address(this);
        attackers[3] = address(0xdead);

        for (uint256 i; i < attackers.length; ++i) {
            vm.prank(attackers[i]);
            vm.expectRevert(
                abi.encodeWithSignature("InvalidInitialization()")
            );
            veHemi.initialize(attackers[i]);
        }

        // Ownership must be intact after all attack attempts — proves the
        // reverts weren't masking a partial state write.
        assertEq(veHemi.owner(), preUpgradeOwner, "ownership hijacked by front-run");
    }

    function test_UpgradeThenSetV1FieldsThenUpgradeAgain() public {
        // Variant: upgrade first, then set V1 state, then upgrade again —
        // ensures upgrade is re-entrant safe with respect to V1 state.
        _writeV1Sentinels();
        _writeV2Sentinels();
        _upgradeTo(address(v2Impl2));
        _assertV1Sentinels();
        _assertV2Sentinels();

        // Upgrade back to v2Impl1 — full V1 + V2 slot matrix must survive.
        _upgradeTo(address(v2Impl1));
        _assertV1Sentinels();
        _assertV2Sentinels();

        // Gap region must still be zero after the round-trip upgrades.
        for (uint256 i = 21; i <= 63; ++i) {
            assertEq(
                vm.load(proxy, bytes32(i)),
                bytes32(0),
                string.concat("gap slot ", vm.toString(i), " corrupted after round-trip")
            );
        }
    }

    // =========================================================================
    // Helpers
    // =========================================================================

    function _writeV1Sentinels() internal {
        // Slot 0–5: value types
        vm.store(proxy, bytes32(uint256(0)), bytes32(TOTAL_LOCKED_SENTINEL));
        vm.store(proxy, bytes32(uint256(1)), bytes32(EPOCH_SENTINEL));
        vm.store(proxy, bytes32(uint256(2)), bytes32(NEXT_TOKEN_ID_SENTINEL));
        vm.store(proxy, bytes32(uint256(3)), bytes32(uint256(uint160(VOTE_DELEGATION_SENTINEL))));
        vm.store(proxy, bytes32(uint256(4)), bytes32(uint256(uint160(REWARD_DISTRIBUTOR_SENTINEL))));
        vm.store(proxy, bytes32(uint256(5)), bytes32(uint256(uint160(FORFEIT_ADMIN_SENTINEL))));

        // Slot 6 (globalPointHistory mapping): Point occupies 3 slots.
        //   slot+0: {int128 bias [0..15], int128 slope [16..31]}
        //   slot+1: {uint64 ts [0..7], uint64 bn [8..15], uint128 amount [16..31]}
        //   slot+2: {uint256 fixedBias}
        // Write DISTINCT sentinels into every field of the struct so a
        // reorder or width change anywhere in Point is caught on upgrade.
        bytes32 gph = keccak256(abi.encode(uint256(7), uint256(6)));
        vm.store(
            proxy,
            gph,
            bytes32(
                (uint256(uint128(uint256(int256(int128(22222))))) << 128) |
                uint256(uint128(uint256(int256(int128(11111)))))
            )
        );
        vm.store(
            proxy,
            bytes32(uint256(gph) + 1),
            bytes32(
                (uint256(uint128(0x33)) << 128) |
                (uint256(uint64(0x22)) << 64) |
                uint256(uint64(0x11))
            )
        );
        vm.store(proxy, bytes32(uint256(gph) + 2), bytes32(uint256(0xFB)));

        // Slot 7 (userPointHistory): UserPoint = Point (3 slots) + owner (1 slot).
        // Exercise EVERY slot of element [0]: bias/slope at +0, ts/bn/amount at +1,
        // fixedBias at +2, owner at +3. Otherwise a field swap within Point
        // inside UserPoint would be invisible.
        bytes32 uphBase = keccak256(abi.encode(TEST_TOKEN_ID, uint256(7)));
        vm.store(
            proxy,
            uphBase,
            bytes32(
                (uint256(uint128(uint256(int256(int128(-555))))) << 128) |
                uint256(uint128(uint256(int256(int128(333)))))
            )
        );
        vm.store(
            proxy,
            bytes32(uint256(uphBase) + 1),
            bytes32(
                (uint256(uint128(0x66)) << 128) |
                (uint256(uint64(0x55)) << 64) |
                uint256(uint64(0x44))
            )
        );
        vm.store(proxy, bytes32(uint256(uphBase) + 2), bytes32(uint256(0x77)));
        vm.store(proxy, bytes32(uint256(uphBase) + 3), bytes32(uint256(uint160(address(0xBEEF)))));

        // Slot 8 (userPointEpoch): simple uint256 mapping.
        bytes32 upe = keccak256(abi.encode(TEST_TOKEN_ID, uint256(8)));
        vm.store(proxy, upe, bytes32(uint256(0x88)));

        // Slot 9 (slopeChanges): int128 mapping.
        bytes32 sc = keccak256(abi.encode(TEST_TIMESTAMP, uint256(9)));
        vm.store(proxy, sc, bytes32(uint256(uint128(uint256(int256(int128(9999)))))));

        // Slot 10 (locked): LockedBalance { int128 amount, uint64 end } packed.
        bytes32 nonTransferableSlot = keccak256(abi.encode(TEST_TOKEN_ID, uint256(10)));
        bytes32 packed = bytes32(
            (uint256(uint64(0xEE)) << 128) |
            uint256(uint128(uint256(int256(int128(0xAA)))))
        );
        vm.store(proxy, nonTransferableSlot, packed);

        // Slot 11 (provider): address mapping.
        bytes32 provSlot = keccak256(abi.encode(TEST_TOKEN_ID, uint256(11)));
        vm.store(proxy, provSlot, bytes32(uint256(uint160(address(0xCAFE)))));

        // Slot 12 (transferableAfter): uint256 mapping.
        bytes32 taSlot = keccak256(abi.encode(TEST_TOKEN_ID, uint256(12)));
        vm.store(proxy, taSlot, bytes32(uint256(0xC12C)));

        // Slot 13 (forfeitable): bool mapping.
        bytes32 fSlot = keccak256(abi.encode(TEST_TOKEN_ID, uint256(13)));
        vm.store(proxy, fSlot, bytes32(uint256(1)));
    }

    function _assertV1Sentinels() internal view {
        assertEq(veHemi.totalLocked(), TOTAL_LOCKED_SENTINEL, "totalLocked (slot 0) changed");
        assertEq(veHemi.epoch(), EPOCH_SENTINEL, "epoch (slot 1) changed");
        assertEq(veHemi.nextTokenId(), NEXT_TOKEN_ID_SENTINEL, "nextTokenId (slot 2) changed");
        assertEq(address(veHemi.voteDelegation()), VOTE_DELEGATION_SENTINEL, "voteDelegation (slot 3) changed");
        assertEq(
            address(veHemi.rewardDistributor()),
            REWARD_DISTRIBUTOR_SENTINEL,
            "rewardDistributor (slot 4) changed"
        );
        assertEq(veHemi.forfeitAdmin(), FORFEIT_ADMIN_SENTINEL, "forfeitAdmin (slot 5) changed");

        IVeHemi.Point memory p = veHemi.getGlobalPoint(7);
        assertEq(p.bias, int128(11111), "globalPointHistory bias");
        assertEq(p.slope, int128(22222), "globalPointHistory slope");
        assertEq(p.timestamp, uint64(0x11), "globalPointHistory timestamp");
        assertEq(p.blockNumber, uint64(0x22), "globalPointHistory blockNumber");
        assertEq(p.amount, uint128(0x33), "globalPointHistory amount");
        assertEq(p.fixedBias, uint256(0xFB), "globalPointHistory fixedBias");

        IVeHemi.UserPoint memory up = veHemi.getUserPoint(TEST_TOKEN_ID, 0);
        assertEq(up.owner, address(0xBEEF), "userPointHistory owner");
        assertEq(up.point.bias, int128(333), "userPointHistory bias");
        assertEq(up.point.slope, int128(-555), "userPointHistory slope");
        assertEq(up.point.timestamp, uint64(0x44), "userPointHistory timestamp");
        assertEq(up.point.blockNumber, uint64(0x55), "userPointHistory blockNumber");
        assertEq(up.point.amount, uint128(0x66), "userPointHistory amount");
        assertEq(up.point.fixedBias, uint256(0x77), "userPointHistory fixedBias");

        assertEq(veHemi.userPointEpoch(TEST_TOKEN_ID), 0x88, "userPointEpoch (slot 8) changed");
        assertEq(veHemi.slopeChanges(TEST_TIMESTAMP), int128(9999), "slopeChanges (slot 9) changed");

        IVeHemi.LockedBalance memory lb = veHemi.getLockedBalance(TEST_TOKEN_ID);
        assertEq(lb.amount, int128(0xAA), "locked.amount (slot 10) changed");
        assertEq(lb.end, uint64(0xEE), "locked.end (slot 10) changed");

        assertEq(veHemi.provider(TEST_TOKEN_ID), address(0xCAFE), "provider (slot 11) changed");
        assertEq(veHemi.transferableAfter(TEST_TOKEN_ID), 0xC12C, "transferableAfter (slot 12) changed");
        assertTrue(veHemi.forfeitable(TEST_TOKEN_ID), "forfeitable (slot 13) changed");
    }

    function _writeV2Sentinels() internal {
        // Slot 14, 15: reserved (private, only vm.load to verify).
        vm.store(proxy, bytes32(uint256(14)), bytes32(uint256(0x1414)));
        vm.store(proxy, bytes32(uint256(15)), bytes32(uint256(0x1515)));

        // Slot 16 (nonTransferableSlopeChanges): int128 mapping.
        bytes32 lsc = keccak256(abi.encode(TEST_TIMESTAMP, uint256(16)));
        vm.store(proxy, lsc, bytes32(uint256(uint128(uint256(int256(int128(1616)))))));

        // Slot 17 (nonTransferableGlobalPointHistory): SupplyPoint occupies 2 slots.
        //   slot+0: {int128 bias [0..15], int128 slope [16..31]}
        //   slot+1: {uint64 ts [0..7], uint64 bn [8..15]}
        // Exercise BOTH slots with distinct sentinels.
        bytes32 lgph = keccak256(abi.encode(uint256(7), uint256(17)));
        vm.store(
            proxy,
            lgph,
            bytes32(
                (uint256(uint128(uint256(int256(int128(0x1702))))) << 128) |
                uint256(uint128(uint256(int256(int128(0x1701)))))
            )
        );
        vm.store(
            proxy,
            bytes32(uint256(lgph) + 1),
            bytes32((uint256(uint64(0x1704)) << 64) | uint256(uint64(0x1703)))
        );

        // Slot 18 (nonTransferableSeedingFinalized): bool.
        vm.store(proxy, bytes32(uint256(18)), bytes32(uint256(1)));

        // Slot 19 (forfeitableSlopeChanges): int128 mapping.
        bytes32 fsc = keccak256(abi.encode(TEST_TIMESTAMP, uint256(19)));
        vm.store(proxy, fsc, bytes32(uint256(uint128(uint256(int256(int128(1919)))))));

        // Slot 20 (forfeitableGlobalPointHistory): SupplyPoint, 2 slots.
        bytes32 fgph = keccak256(abi.encode(uint256(7), uint256(20)));
        vm.store(
            proxy,
            fgph,
            bytes32(
                (uint256(uint128(uint256(int256(int128(0x2002))))) << 128) |
                uint256(uint128(uint256(int256(int128(0x2001)))))
            )
        );
        vm.store(
            proxy,
            bytes32(uint256(fgph) + 1),
            bytes32((uint256(uint64(0x2004)) << 64) | uint256(uint64(0x2003)))
        );
    }

    function _assertV2Sentinels() internal view {
        assertEq(vm.load(proxy, bytes32(uint256(14))), bytes32(uint256(0x1414)), "slot 14 changed");
        assertEq(vm.load(proxy, bytes32(uint256(15))), bytes32(uint256(0x1515)), "slot 15 changed");
        assertEq(
            veHemi.nonTransferableSlopeChanges(TEST_TIMESTAMP),
            int128(1616),
            "nonTransferableSlopeChanges (slot 16) changed"
        );
        bytes32 lgph17 = keccak256(abi.encode(uint256(7), uint256(17)));
        assertEq(
            vm.load(proxy, lgph17),
            bytes32(
                (uint256(uint128(uint256(int256(int128(0x1702))))) << 128) |
                uint256(uint128(uint256(int256(int128(0x1701)))))
            ),
            "nonTransferableGlobalPointHistory slot+0 (slot 17 base)"
        );
        assertEq(
            vm.load(proxy, bytes32(uint256(lgph17) + 1)),
            bytes32((uint256(uint64(0x1704)) << 64) | uint256(uint64(0x1703))),
            "nonTransferableGlobalPointHistory slot+1 (slot 17 base+1)"
        );
        assertTrue(veHemi.nonTransferableSeedingFinalized(), "nonTransferableSeedingFinalized (slot 18) changed");
        assertEq(
            veHemi.forfeitableSlopeChanges(TEST_TIMESTAMP),
            int128(1919),
            "forfeitableSlopeChanges (slot 19) changed"
        );
        bytes32 fgph20 = keccak256(abi.encode(uint256(7), uint256(20)));
        assertEq(
            vm.load(proxy, fgph20),
            bytes32(
                (uint256(uint128(uint256(int256(int128(0x2002))))) << 128) |
                uint256(uint128(uint256(int256(int128(0x2001)))))
            ),
            "forfeitableGlobalPointHistory slot+0 (slot 20 base)"
        );
        assertEq(
            vm.load(proxy, bytes32(uint256(fgph20) + 1)),
            bytes32((uint256(uint64(0x2004)) << 64) | uint256(uint64(0x2003))),
            "forfeitableGlobalPointHistory slot+1 (slot 20 base+1)"
        );
    }

    /// @dev Performs the ERC1967 proxy upgrade by writing the new implementation
    ///      address directly to the ERC1967 implementation slot. This simulates
    ///      `ProxyAdmin.upgrade()` at the storage level without needing the full
    ///      TransparentUpgradeableProxy harness. The layout check is the same:
    ///      we verify that storage slots outside the OZ-namespaced implementation
    ///      slot are preserved.
    function _upgradeTo(address newImpl) internal {
        bytes32 IMPL_SLOT = bytes32(uint256(keccak256("eip1967.proxy.implementation")) - 1);
        vm.store(proxy, IMPL_SLOT, bytes32(uint256(uint160(newImpl))));
    }
}
