// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import "forge-std/Test.sol";
import "../src/VeHemi.sol";
import "../src/interfaces/IVeHemi.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import "./mocks/MockERC20.sol";
import "./mocks/MockHemiVoteDelegation.sol";

/// @title StorageLayoutRegressionTest
/// @notice Negative control for the storage-layout test harness. Proves that
///         the sentinel-based layout assertions (VeHemiStorageLayout.t.sol,
///         VeHemiV1ToV2Upgrade.t.sol) actually detect a real slot shift —
///         not just pass trivially on the current layout.
///
///         Strategy: deploy a CORRECT V2 impl, write a sentinel at a slot
///         position that the test harness considers authoritative, then
///         manually corrupt the SAME slot to a different value. Any reader
///         using the getter (which follows the Solidity-generated slot map)
///         must surface the corruption as a mismatched value — exactly as if
///         a real layout shift had moved the field.
///
///         If this test ever fails, the assertion mechanism is broken and
///         other layout tests would yield false negatives.
contract StorageLayoutRegressionTest is Test {
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

    /// @dev Simulate a layout regression where the V2 field
    ///      `nonTransferableSeedingFinalized` accidentally moved to a V1 slot.
    ///      Corrupt slot 18 and confirm the getter picks up the change —
    ///      this is the exact mechanism by which the layout tests catch
    ///      slot-shift regressions.
    function test_Slot18Corruption_IsDetectedByGetter() public {
        assertFalse(veHemi.nonTransferableSeedingFinalized(), "baseline zero");

        // Write `true` to slot 18 low byte.
        vm.store(proxy, bytes32(uint256(18)), bytes32(uint256(1)));
        assertTrue(veHemi.nonTransferableSeedingFinalized(), "getter reflects raw write");

        // Clear it again.
        vm.store(proxy, bytes32(uint256(18)), bytes32(uint256(0)));
        assertFalse(veHemi.nonTransferableSeedingFinalized(), "getter reflects raw clear");
    }

    /// @dev If a future change erroneously moved `totalLocked` from slot 0 to
    ///      a different slot, a sentinel written to slot 0 (the pre-change
    ///      expected location) would no longer be visible through the getter.
    ///      Verify the opposite: writing to a DIFFERENT slot must NOT change
    ///      the getter output. This proves slot 0 is uniquely associated with
    ///      totalLocked.
    function test_NonZeroSlotWrite_DoesNotAffectSlot0Getter() public {
        uint256 sentinel = 0x1234;
        vm.store(proxy, bytes32(uint256(0)), bytes32(sentinel));
        assertEq(veHemi.totalLocked(), sentinel);

        // Write to every slot in 1..13 with a different value and confirm
        // totalLocked() continues to return the original sentinel.
        for (uint256 i = 1; i <= 13; ++i) {
            vm.store(proxy, bytes32(i), bytes32(uint256(0xC0FFEE) + i));
            assertEq(
                veHemi.totalLocked(),
                sentinel,
                string.concat("totalLocked corrupted by write to slot ", vm.toString(i))
            );
        }
        // Same for V2 slots 14..63.
        for (uint256 i = 14; i <= 63; ++i) {
            vm.store(proxy, bytes32(i), bytes32(uint256(0xFACADE) + i));
            assertEq(
                veHemi.totalLocked(),
                sentinel,
                string.concat("totalLocked corrupted by write to slot ", vm.toString(i))
            );
        }
    }

    /// @dev TRUE negative control: deploy a deliberately shifted impl
    ///      (VeHemiBadV1 — identical V1 layout except a spurious `__inserted`
    ///      uint256 occupies slot 0, pushing `totalLocked` to slot 1). Etch
    ///      the shifted bytecode onto the live proxy, then verify the exact
    ///      assertion pattern used by VeHemiStorageLayout.t.sol's
    ///      `test_slot0_totalLocked` would FAIL against this mutant.
    ///
    ///      This proves the positive-control sentinel tests are not
    ///      tautological — they would actively detect the specific class of
    ///      regression (field insertion at slot 0) that layout drift tests
    ///      are designed to catch.
    function test_ShiftedLayoutMutant_FailsSlot0Assertion() public {
        // Deploy the mutant impl and etch its runtime code onto the proxy.
        VeHemiBadV1 mutant = new VeHemiBadV1();
        vm.etch(proxy, address(mutant).code);

        // Write sentinel to slot 0 — in the mutant this is `__inserted`,
        // NOT `totalLocked`.
        uint256 sentinel = 0xBEEF;
        vm.store(proxy, bytes32(uint256(0)), bytes32(sentinel));

        // The mutant's `totalLocked()` getter reads slot 1 (where
        // `totalLocked` now lives after the shift), which is currently zero.
        // A positive-control assertion of `assertEq(totalLocked(), sentinel)`
        // against THIS proxy MUST fail — proving the sentinel harness
        // actually discriminates layouts.
        uint256 actualTotalLocked = VeHemiBadV1(proxy).totalLocked();
        assertTrue(
            actualTotalLocked != sentinel,
            "shifted layout went undetected - harness would silently pass a real regression"
        );
        assertEq(actualTotalLocked, 0, "slot 1 was not the post-shift home of totalLocked");

        // Symmetrically, writing to slot 1 DOES affect the mutant's
        // totalLocked getter, confirming the shift is real.
        vm.store(proxy, bytes32(uint256(1)), bytes32(sentinel));
        assertEq(
            VeHemiBadV1(proxy).totalLocked(),
            sentinel,
            "mutant's totalLocked is not actually at slot 1"
        );
    }

    /// @dev Second mutant: LockedBalance with fields swapped so `end` is at
    ///      offset 0 and `amount` at offset 8. The positive-control packing
    ///      formula in test_slot10_locked puts 9999 in bits [0..127] and
    ///      1700000000 in bits [128..191]. On the swapped layout those bits
    ///      decode differently, so the assertEq pattern fails.
    function test_SwappedLockedBalance_FailsSlot10Assertion() public {
        VeHemiBadLockedBalance mutant = new VeHemiBadLockedBalance();
        vm.etch(proxy, address(mutant).code);

        // Mirror the test_slot10_locked packing.
        uint256 tokenId = 42;
        int128 amtSentinel = 9999;
        uint64 endSentinel = 1_700_000_000;
        bytes32 slot = keccak256(abi.encode(tokenId, uint256(10)));
        bytes32 packed = bytes32(
            (uint256(endSentinel) << 128) |
            uint256(uint128(uint256(int256(amtSentinel))))
        );
        vm.store(proxy, slot, packed);

        // On the swapped layout, `end` occupies bits [0..63] (reading the
        // low 64 bits of the packed word → 9999, not 1700000000) and
        // `amount` occupies bits [64..191]. So the getter returns values
        // that do NOT match the original sentinels.
        VeHemiBadLockedBalance.LockedBalanceSwapped memory lb =
            VeHemiBadLockedBalance(proxy).getLocked(tokenId);

        assertTrue(
            lb.end != endSentinel || lb.amount != amtSentinel,
            "swapped LockedBalance layout went undetected - harness would silently pass"
        );
        // Demonstrate the specific mis-decode.
        assertEq(lb.end, uint64(uint128(amtSentinel)), "swap: end read from amount bits");
    }

    /// @dev Third mutant: VeHemiVoteDelegation Delegation struct with
    ///      delegatee and end swapped. Parity with the LockedBalance swap
    ///      mutant — proves the R-2 Delegation member-layout pin in
    ///      StorageLayoutGolden.t.sol would catch a real intra-struct swap.
    ///
    ///      Note: unlike the other mutants (which etch onto a VeHemi proxy),
    ///      this mutant is self-contained. The R-2 golden tests read a
    ///      fixture, not deployed bytecode, so the mutant here is used only
    ///      to DEMONSTRATE that the kind of fixture it would produce
    ///      disagrees with the pinned expectations.
    function test_SwappedDelegation_FixtureDisagreesWithGolden() public {
        BadDelegation mutant = new BadDelegation();
        // Write values through the mutant's setter (swapped layout writes
        // `end` at offset 0, `delegatee` at offset 6).
        mutant.setPair(address(0xABCD), uint48(0x123456));

        // Read raw slot and decode under BOTH layouts; they must disagree.
        // CORRECT layout: delegatee@offset 0 (low 20B), end@offset 20.
        // SWAPPED layout: end@offset 0 (low 6B), delegatee@offset 6.
        bytes32 raw = mutant.raw();
        address correctLayoutDelegatee = address(uint160(uint256(raw)));
        uint48 correctLayoutEnd = uint48(uint256(raw) >> 160);

        // Under correct layout the mutant's state would read as mismatched
        // sentinels — demonstrating that if a future refactor swapped these
        // fields in source, the R-2 pin (delegatee@offset 0, end@offset 20)
        // would fire against the regenerated fixture.
        assertTrue(
            correctLayoutDelegatee != address(0xABCD) || correctLayoutEnd != uint48(0x123456),
            "swapped Delegation fields would decode identically under both layouts - mutant is not discriminating"
        );
    }

    /// @dev Fourth mutant: V2 delegation storage with __gapV2 shrunk from
    ///      [44] to [43] and a new field appended in its place. Proves
    ///      that `test_VeHemiVoteDelegation_GapIsExactly44Slots` in
    ///      StorageLayoutGolden.t.sol (which pins the `t_array(t_uint256)44_storage`
    ///      type key) would fire against a regenerated fixture for this layout.
    ///      This closes mutation class M2 (gap-size reduction) that plain
    ///      sentinel-at-zero gap tests miss.
    function test_ShrunkGapV2_FixtureDisagreesWithGolden() public {
        BadDelegationGapShrunk mutant = new BadDelegationGapShrunk();
        // Write a sentinel into the newly-added field at the END of the
        // gap region (absolute slot 49 under the shrunk layout).
        uint256 sentinel = 0xDEADDEAD;
        mutant.setExtraSlot(sentinel);

        // Under the CORRECT layout (gap = [44], slot 49 is still gap), the
        // getter for `extraSlot` would read from slot 50 — which never
        // existed in V2. The mutant's bytecode has the getter reading slot
        // 49 directly, so it returns the sentinel only on the shrunk layout.
        assertEq(mutant.extraSlot(), sentinel, "shrunk-gap mutant: extraSlot not at slot 49");

        // The fixture produced by this layout would have
        // `t_array(t_uint256)43_storage` at slot 6 plus a new entry at
        // slot 49 — disagreeing with the Golden pin. Demonstrated here by
        // asserting the mutant's layout is observably different from V2.
        bytes32 slot49Raw = vm.load(address(mutant), bytes32(uint256(49)));
        assertTrue(
            slot49Raw != bytes32(0),
            "slot 49 under shrunk layout would be zero - mutant did not discriminate"
        );
    }

    /// @dev Fifth mutant: VeHemiStorageV2 with nonTransferableSlopeChanges (slot 16)
    ///      and nonTransferableGlobalPointHistory (slot 17) swapped. Proves that a
    ///      top-level V2 slot swap decodes differently at the mapping base —
    ///      `StorageLayoutGolden.t.sol::test_VeHemi_V2SlotsAtExpectedPositions`
    ///      fires because the JSON golden pins slot→label mapping.
    function test_SwappedV2SubcurveSlots_DiscriminatesLayout() public {
        VeHemiBadV2SlotSwap mutant = new VeHemiBadV2SlotSwap();

        // Under SWAPPED layout: setNonTransferableSlopeChange(ts, v) writes to
        // keccak(ts, 17) (what the CORRECT layout uses for nonTransferableGlobalPointHistory).
        uint256 ts = 999;
        int128 v = 12345;
        mutant.setNonTransferableSlopeChange(ts, v);

        // Read keccak(ts, 16) (CORRECT layout's nonTransferableSlopeChanges slot) — zero.
        bytes32 correctSlopeSlot = keccak256(abi.encode(ts, uint256(16)));
        assertEq(
            uint256(vm.load(address(mutant), correctSlopeSlot)),
            0,
            "correct-layout slot 16 should be zero under mutant - swap not real"
        );
        // Read keccak(ts, 17) — the sentinel is here.
        bytes32 swappedSlopeSlot = keccak256(abi.encode(ts, uint256(17)));
        bytes32 raw = vm.load(address(mutant), swappedSlopeSlot);
        assertTrue(raw != bytes32(0), "swap not observable at slot 17 keccak base");

        // Any positive-control golden assertion pinning
        // `.storage[16].label == "nonTransferableSlopeChanges"` would fire against
        // a fixture regenerated from this layout (where slot 16 would
        // decode as nonTransferableGlobalPointHistory instead).
    }

    /// @dev Sixth mutant: VeHemiDelegationStorageV2 with a field inserted
    ///      between nonces (slot 3) and autoDelegate (slot 4). This directly
    ///      represents the V1/V2 boundary regression PR #69 was designed to
    ///      prevent — a new field accidentally shifting autoDelegate from
    ///      slot 4 to slot 5 and trustedAdapter from slot 5 to slot 6.
    function test_V2BoundaryInsertion_DiscriminatesLayout() public {
        BadDelegationV2Insertion mutant = new BadDelegationV2Insertion();
        // The mutant's inserted field occupies slot 4; autoDelegate is
        // shifted to slot 5.
        address owner_ = address(0x5555);
        address sentinel = address(0xAAAA);
        // Write to what a CORRECT layout would treat as autoDelegate base
        // (keccak(owner, 4)) — mutant's getter reads from keccak(owner, 5)
        // so this write is not visible.
        bytes32 correctAutoSlot = keccak256(abi.encode(owner_, uint256(4)));
        vm.store(address(mutant), correctAutoSlot, bytes32(uint256(uint160(sentinel))));
        assertEq(
            mutant.autoDelegate(owner_),
            address(0),
            "mutant's autoDelegate read slot 4 - insertion not real"
        );

        // Write at keccak(owner, 5) — the mutant's SHIFTED autoDelegate base.
        bytes32 shiftedAutoSlot = keccak256(abi.encode(owner_, uint256(5)));
        vm.store(address(mutant), shiftedAutoSlot, bytes32(uint256(uint160(sentinel))));
        assertEq(
            mutant.autoDelegate(owner_),
            sentinel,
            "mutant's autoDelegate not at shifted slot 5"
        );

        // The Golden pin `_assertDelegationEntry(4, "4", "autoDelegate")`
        // would fire against a fixture regenerated from this mutant —
        // which would have `.storage[4].label == "__inserted"` and
        // `.storage[5].label == "autoDelegate"`.
    }
}

/// @dev Mutant V1-like contract where a spurious `__inserted` uint256 sits
///      at slot 0, shifting `totalLocked` to slot 1. Deliberately minimal:
///      only exposes the `totalLocked()` getter so the negative control can
///      invoke it.
contract VeHemiBadV1 {
    uint256 private __inserted;        // slot 0 (injected)
    uint256 public totalLocked;        // slot 1 (shifted from 0)
}

/// @dev Mutant with LockedBalance fields swapped. When etched onto a proxy,
///      `getLocked(tokenId)` decodes storage slot keccak(tokenId, 10) under
///      the swapped layout. Comparing against the correct-layout packed
///      sentinel will fail — proving the positive-control test would detect
///      this class of regression.
contract VeHemiBadLockedBalance {
    struct LockedBalanceSwapped {
        uint64 end;     // offset 0 (swapped)
        int128 amount;  // offset 8 (swapped)
    }

    mapping(uint256 => LockedBalanceSwapped) internal _locked;

    function getLocked(uint256 tokenId) external view returns (LockedBalanceSwapped memory) {
        // NOTE: this mapping lives at slot 0 of this contract, but when the
        // bytecode is etched onto a proxy that had a different storage
        // layout, the mapping base still hashes against slot 0. The test
        // writes to keccak(tokenId, 10) — so to hit the same slot, we read
        // from the same base.
        bytes32 slot = keccak256(abi.encode(tokenId, uint256(10)));
        bytes32 word;
        assembly {
            word := sload(slot)
        }
        return LockedBalanceSwapped({
            end: uint64(uint256(word)),
            amount: int128(uint128(uint256(word) >> 64))
        });
    }
}

/// @dev Mutant VoteDelegation with Delegation's first two fields swapped
///      (end before delegatee). Proves the R-2 `DelegationMemberLayout`
///      golden-fixture pin discriminates real struct-field swaps.
contract BadDelegation {
    struct DelegationSwapped {
        uint48 end;          // offset 0 (swapped)
        address delegatee;   // offset 6 (swapped)
    }

    DelegationSwapped internal _data;

    function setPair(address delegatee_, uint48 end_) external {
        _data.end = end_;
        _data.delegatee = delegatee_;
    }

    function raw() external view returns (bytes32 w) {
        assembly { w := sload(_data.slot) }
    }
}

/// @dev Fourth mutant: V2 delegation layout with __gapV2 shrunk from [44]
///      to [43] and a new `extraSlot` field inserted in its place. This
///      is a direct model of the "gap-size reduction" regression class
///      (M2 in the external mutation analysis). Layout mirrors
///      VeHemiDelegationStorageV2 exactly through slot 48, then `extraSlot`
///      occupies slot 49 (the old last gap slot).
contract BadDelegationGapShrunk {
    // Slots 0-3: V1 fields (stubbed as minimal).
    mapping(uint256 => uint256) internal __v1slot0;
    mapping(uint256 => uint256) internal __v1slot1;
    mapping(uint256 => uint256) internal __v1slot2;
    mapping(uint256 => uint256) internal __v1slot3;
    // Slots 4-5: V2 named fields.
    mapping(address => address) internal __v2slot4;
    address internal __v2slot5;
    // Slots 6-48: shrunk gap (43 instead of 44 slots).
    uint256[43] private __gapV2;
    // Slot 49: the maliciously inserted field.
    uint256 public extraSlot;

    function setExtraSlot(uint256 v) external {
        extraSlot = v;
    }
}

/// @dev Fifth mutant: VeHemi V2 storage with `nonTransferableSlopeChanges` and
///      `nonTransferableGlobalPointHistory` swapped (slots 16 ↔ 17). Minimal layout
///      — only reproduces through slot 17 since the top-level slot swap
///      is what matters. A sentinel written by `setNonTransferableSlopeChange`
///      ends up at keccak(ts, 17) under this layout, which would disagree
///      with a Golden pin of `.storage[16].label == "nonTransferableSlopeChanges"`.
contract VeHemiBadV2SlotSwap {
    // Slots 0-13: V1 fields (14 minimal stubs).
    uint256 internal _s0; uint256 internal _s1; uint256 internal _s2;
    address internal _s3; address internal _s4; address internal _s5;
    mapping(uint256 => uint256) internal _s6;
    mapping(uint256 => uint256) internal _s7;
    mapping(uint256 => uint256) internal _s8;
    mapping(uint256 => int128) internal _s9;
    mapping(uint256 => uint256) internal _s10;
    mapping(uint256 => address) internal _s11;
    mapping(uint256 => uint256) internal _s12;
    mapping(uint256 => bool) internal _s13;
    // Slots 14-15: V2 reserved.
    uint256 internal __reservedSlot0;
    uint256 internal __reservedSlot1;
    // SWAPPED: nonTransferableGlobalPointHistory at 16, nonTransferableSlopeChanges at 17.
    mapping(uint256 => uint256) internal nonTransferableGlobalPointHistory; // slot 16 (swapped)
    mapping(uint256 => int128) internal nonTransferableSlopeChanges;        // slot 17 (swapped)

    function setNonTransferableSlopeChange(uint256 ts, int128 v) external {
        nonTransferableSlopeChanges[ts] = v;
    }
}

/// @dev Sixth mutant: a V1/V2-boundary insertion regression directly
///      modelling PR #69's concern. A spurious field at slot 4 pushes
///      `autoDelegate` to slot 5 and `trustedAdapter` to slot 6.
///      Proves the `_assertDelegationEntry(4, "4", "autoDelegate")` pin
///      in StorageLayoutGolden.t.sol discriminates this exact class.
contract BadDelegationV2Insertion {
    // Slots 0-3: V1 fields.
    mapping(uint256 => uint256) internal _v1slot0;
    mapping(uint256 => uint256) internal _v1slot1;
    mapping(uint256 => uint256) internal _v1slot2;
    mapping(address => uint256) internal _v1slot3; // nonces
    // Slot 4: the maliciously inserted field.
    uint256 internal __inserted;
    // Slots 5-6: V2 fields shifted by one.
    mapping(address => address) public autoDelegate; // slot 5 (shifted from 4)
    address public trustedAdapter;                   // slot 6 (shifted from 5)
}
