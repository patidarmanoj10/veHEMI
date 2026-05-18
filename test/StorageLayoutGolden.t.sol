// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import "forge-std/Test.sol";

/// @title StorageLayoutGoldenTest
/// @notice Loads the committed golden fixture JSON files and asserts the
///         critical storage-layout invariants directly in the Foundry test
///         suite. Without this test the golden fixtures would be consulted
///         only by the external CI shell script; this keeps developers honest
///         via a normal `forge test` run.
///
///         Covers:
///           - Every VeHemi slot label lives at the expected absolute slot.
///           - `__gapV2` is `uint256[36]` starting at slot 28.
///           - `userPointHistory` inner array length is EXACTLY 1,000,000,000
///             (catches a regex that accidentally strips array lengths).
///           - `VeHemiAragonAdapter` has ZERO storage fields (stateless).
///           - `VeHemiVoteDelegation`'s V1 fields begin at slot 0.
contract StorageLayoutGoldenTest is Test {
    string veHemiJson;
    string delegationJson;
    string adapterJson;

    function setUp() public {
        veHemiJson = vm.readFile("test/fixtures/storage-layouts/VeHemi.json");
        delegationJson = vm.readFile("test/fixtures/storage-layouts/VeHemiVoteDelegation.json");
        adapterJson = vm.readFile("test/fixtures/storage-layouts/VeHemiAragonAdapter.json");
    }

    // ─── VeHemi slot pinning ───────────────────────────────────────────────

    struct Expected {
        uint256 index;
        string slot;
        string label;
    }

    /// @dev Assert that the VeHemi storage entry at array index `i` has the
    ///      expected absolute slot and label. Uses `vm.parseJsonString` with a
    ///      JSONPath-like accessor — no FFI required.
    function _assertVeHemiEntry(uint256 i, string memory expectedSlot, string memory expectedLabel) internal view {
        string memory slotKey = string.concat(".storage[", vm.toString(i), "].slot");
        string memory labelKey = string.concat(".storage[", vm.toString(i), "].label");
        string memory gotSlot = vm.parseJsonString(veHemiJson, slotKey);
        string memory gotLabel = vm.parseJsonString(veHemiJson, labelKey);
        assertEq(gotSlot, expectedSlot, string.concat("slot mismatch at entry ", vm.toString(i)));
        assertEq(gotLabel, expectedLabel, string.concat("label mismatch at entry ", vm.toString(i)));
    }

    function test_VeHemi_V1SlotsAtExpectedPositions() public view {
        _assertVeHemiEntry(0, "0", "totalLocked");
        _assertVeHemiEntry(1, "1", "epoch");
        _assertVeHemiEntry(2, "2", "nextTokenId");
        _assertVeHemiEntry(3, "3", "voteDelegation");
        _assertVeHemiEntry(4, "4", "rewardDistributor");
        _assertVeHemiEntry(5, "5", "forfeitAdmin");
        _assertVeHemiEntry(6, "6", "globalPointHistory");
        _assertVeHemiEntry(7, "7", "userPointHistory");
        _assertVeHemiEntry(8, "8", "userPointEpoch");
        _assertVeHemiEntry(9, "9", "slopeChanges");
        _assertVeHemiEntry(10, "10", "locked");
        _assertVeHemiEntry(11, "11", "provider");
        _assertVeHemiEntry(12, "12", "transferableAfter");
        _assertVeHemiEntry(13, "13", "forfeitable");
    }

    function test_VeHemi_V2SlotsAtExpectedPositions() public view {
        _assertVeHemiEntry(14, "14", "__reservedSlot0");
        _assertVeHemiEntry(15, "15", "__reservedSlot1");
        _assertVeHemiEntry(16, "16", "lockedSlopeChanges");
        _assertVeHemiEntry(17, "17", "lockedGlobalPointHistory");
        _assertVeHemiEntry(18, "18", "lockedSeedingFinalized");
        _assertVeHemiEntry(19, "19", "forfeitableSlopeChanges");
        _assertVeHemiEntry(20, "20", "forfeitableGlobalPointHistory");
        // Storage slot 21 (json entry 21): seedingStarted (bool, 1B) packed
        // with seedingStartedAt (uint64, 8B) — together 9 bytes, both in
        // slot 21 at offsets 0 and 1 respectively.
        _assertVeHemiEntry(21, "21", "seedingStarted");
        _assertVeHemiEntry(22, "21", "seedingStartedAt");
        // Storage slot 22 (json entry 23): seedingTargetId (uint256).
        _assertVeHemiEntry(23, "22", "seedingTargetId");
        // Storage slots 23-27 (json entry 24): _seedingProgress struct
        // (5 slots — lastProcessedId, {totalSlope|totalBias} packed,
        // {totalForfeitableSlope|totalForfeitableBias} packed, count, minSubEnd).
        _assertVeHemiEntry(24, "23", "_seedingProgress");
        // Storage slot 28 (json entry 25): the __gapV2 array, shrunk to
        // 36 slots to make room for the 7 new V2 slots above (21-27;
        // seedingStarted + seedingStartedAt share slot 21; minSubEnd at slot 27).
        _assertVeHemiEntry(25, "28", "__gapV2");
    }

    /// @dev Pin the byte-offset and type of the two fields that share slot 21
    ///      (`seedingStarted` + `seedingStartedAt`). The base
    ///      `_assertVeHemiEntry` helper inspects only `.slot` and `.label` —
    ///      a hostile/regressing edit that flipped the declaration order
    ///      (uint64 first → offset 0, bool second → offset 8) would preserve
    ///      both slot and label but break the storage layout in a way that
    ///      changes the runtime semantics of every read/write. Catch that
    ///      class of regression here.
    function test_VeHemi_Slot21PackingOffsetsAndTypes() public view {
        // seedingStarted: bool at slot 21, offset 0.
        assertEq(
            vm.parseJsonString(veHemiJson, ".storage[21].offset"),
            "0",
            "seedingStarted must be at offset 0 of slot 21"
        );
        assertEq(
            vm.parseJsonString(veHemiJson, ".storage[21].type"),
            "t_bool",
            "seedingStarted must remain t_bool"
        );

        // seedingStartedAt: uint64 at slot 21, offset 1 (immediately after
        // the bool's single byte). Narrowing to a smaller type would NOT shift
        // this offset (it'd stay at 1), but widening to uint128 or moving to
        // its own slot would. Pin the type explicitly.
        assertEq(
            vm.parseJsonString(veHemiJson, ".storage[22].offset"),
            "1",
            "seedingStartedAt must be at offset 1 of slot 21"
        );
        assertEq(
            vm.parseJsonString(veHemiJson, ".storage[22].type"),
            "t_uint64",
            "seedingStartedAt must remain t_uint64"
        );
    }

    /// @dev Reserved slots 14 and 15 MUST stay as full-width uint256. If
    ///      someone narrows them (e.g., to uint128), Solidity would happily
    ///      pack a new field into the high 128 bits of the slot without
    ///      shifting absolute positions — the sentinel tests would miss it
    ///      because they write/read the full word. Pin the type string here.
    function test_VeHemi_ReservedSlotsAreFullUint256() public view {
        string memory type14 = vm.parseJsonString(veHemiJson, ".storage[14].type");
        string memory type15 = vm.parseJsonString(veHemiJson, ".storage[15].type");
        assertEq(type14, "t_uint256", "__reservedSlot0 must remain uint256");
        assertEq(type15, "t_uint256", "__reservedSlot1 must remain uint256");
    }

    /// @dev Pin the element type of __gapV2. Shrinking `uint256[36]` to
    ///      `uint128[36]` would halve the gap footprint while the existing
    ///      `numberOfBytes` check on the gap type remains misleading-adjacent.
    ///      Catch this by asserting the base element type is uint256 explicitly.
    function test_VeHemi_GapElementIsUint256() public view {
        string memory base = vm.parseJsonString(
            veHemiJson,
            ".types.[\"t_array(t_uint256)36_storage\"].base"
        );
        assertEq(base, "t_uint256", "__gapV2 element type must be uint256");
    }

    function test_VeHemi_GapIsExactly36Slots() public view {
        // Fetch the `type` field for the __gapV2 entry (JSON index 25, which
        // corresponds to storage slot 28), then resolve it in the `types`
        // dictionary and assert its label is `uint256[36]`. This is the
        // CRITICAL check: if someone shrinks __gapV2 from 36 to 35 (for
        // example, while inserting a new field before the gap without
        // adjusting the gap size), this test fires. Asserts the actual
        // bytecode layout, not just a source-level arithmetic sum.
        //
        // V2 storage now uses 7 NAMED slots beyond the original 5 V2 fields:
        // slot 21 (seedingStarted+seedingStartedAt packed), slot 22
        // (seedingTargetId), slots 23-27 (_seedingProgress, 5 slots including
        // minSubEnd).
        // 43 (original gap) - 7 (new slots) = 36 (current gap).
        string memory gapType = vm.parseJsonString(veHemiJson, ".storage[25].type");
        assertEq(gapType, "t_array(t_uint256)36_storage", "__gapV2 must be uint256[36]");

        string memory gapLabel = vm.parseJsonString(
            veHemiJson,
            ".types.[\"t_array(t_uint256)36_storage\"].label"
        );
        assertEq(gapLabel, "uint256[36]", "__gapV2 type label");

        string memory gapBytes = vm.parseJsonString(
            veHemiJson,
            ".types.[\"t_array(t_uint256)36_storage\"].numberOfBytes"
        );
        assertEq(gapBytes, "1152", "__gapV2 numberOfBytes (36 * 32 = 1152)");
    }

    function test_VeHemi_UserPointHistoryArrayLengthIs1e9() public view {
        // This asserts the full type identifier of the userPointHistory inner
        // array. The committed fixture is normalized (AST IDs stripped) but
        // the normalizer specifically PRESERVES array lengths like
        // `...)1000000000_storage`. If the jq normalization regex ever
        // regresses back to stripping all digits after `)`, this length
        // would disappear from the fixture and this assertion would fail.
        // Also catches an accidental shrink from 1e9 to 1e8 in the source.
        string memory uphType = vm.parseJsonString(veHemiJson, ".storage[7].type");
        assertEq(
            uphType,
            "t_mapping(t_uint256,t_array(t_struct(UserPoint)_storage)1000000000_storage)",
            "userPointHistory type string"
        );

        string memory innerLabel = vm.parseJsonString(
            veHemiJson,
            ".types.[\"t_array(t_struct(UserPoint)_storage)1000000000_storage\"].label"
        );
        assertEq(innerLabel, "struct IVeHemi.UserPoint[1000000000]", "UserPoint array length");
    }

    function test_VeHemi_TotalSlotsExactly26() public {
        // VeHemi.json should contain exactly 26 storage entries:
        //   V1: 0-13 (14 entries)
        //   V2: 14-24 plus __gapV2 at 25 (12 entries — seedingStarted and
        //       seedingStartedAt are distinct JSON entries that share slot
        //       21 via packing at offsets 0 and 1).
        // The `.storage` array enumerates ONLY the directly-declared
        // sequential fields; OZ parent slots are ERC-7201 namespaced and do
        // not appear. The 4-slot `_seedingProgress` struct contributes one
        // entry (the struct base), not four.
        //
        // Count entries by probing sequentially until parse fails.
        uint256 count = _countStorageEntries(veHemiJson, 64);
        assertEq(count, 26, "VeHemi.json must have exactly 26 storage entries");
    }

    /// @dev External wrapper so we can try/catch the parseJson call.
    function probeStorageEntry(string calldata json, uint256 i) external view returns (string memory) {
        return vm.parseJsonString(json, string.concat(".storage[", vm.toString(i), "].slot"));
    }

    /// @dev Count `.storage` entries by probing consecutive indices. Version-
    ///      independent of `parseJsonStringArray` wildcard support. `maxProbe`
    ///      caps the scan for safety — must exceed the expected count by at
    ///      least one to distinguish "exactly N" from "at least N".
    function _countStorageEntries(string memory json, uint256 maxProbe) internal returns (uint256) {
        for (uint256 i; i < maxProbe; ++i) {
            try this.probeStorageEntry(json, i) {
                // entry i exists, continue
            } catch {
                return i;
            }
        }
        revert("storage entries exceed maxProbe - increase cap or regression detected");
    }

    // ─── VeHemiAragonAdapter: must be stateless ─────────────────────────────

    function test_AragonAdapter_IsStateless() public {
        // The adapter holds an `immutable` VeHemi reference in bytecode, no
        // storage. A regression that added a state variable would break the
        // "not a proxy" assumption in the deploy scripts.
        uint256 count = _countStorageEntries(adapterJson, 8);
        assertEq(count, 0, "VeHemiAragonAdapter must have zero storage entries");
    }

    // ─── VeHemi struct numberOfBytes pinning ────────────────────────────────

    /// @dev Pin the total byte footprint of every struct used in VeHemi storage.
    ///      A solc repack (e.g., `uint64 timestamp` → `uint32 timestamp` collapsing
    ///      Point from 3 slots to 2) would shift every keccak-derived mapping
    ///      element — this test catches it at `forge test` time, not just in the
    ///      CI shell diff.
    ///
    ///      Type keys are AST-ID-stripped (the committed fixture is normalized
    ///      by update-storage-layouts.sh), so unrelated source edits don't
    ///      invalidate this test.
    function test_VeHemi_StructByteFootprints() public view {
        assertEq(
            vm.parseJsonString(veHemiJson, ".types.[\"t_struct(Point)_storage\"].numberOfBytes"),
            "96",
            "Point must be 3 slots (96 bytes)"
        );
        assertEq(
            vm.parseJsonString(veHemiJson, ".types.[\"t_struct(UserPoint)_storage\"].numberOfBytes"),
            "128",
            "UserPoint must be 4 slots (128 bytes)"
        );
        assertEq(
            vm.parseJsonString(veHemiJson, ".types.[\"t_struct(LockedBalance)_storage\"].numberOfBytes"),
            "32",
            "LockedBalance must be 1 slot (32 bytes)"
        );
        assertEq(
            vm.parseJsonString(veHemiJson, ".types.[\"t_struct(LockedPoint)_storage\"].numberOfBytes"),
            "64",
            "LockedPoint must be 2 slots (64 bytes)"
        );
    }

    /// @dev Pin the member layout of SeedingProgress — slots 23-27 hold the
    ///      in-progress seeding accumulator. The struct contains two packed
    ///      int128 pairs (totalSlope|totalBias and
    ///      totalForfeitableSlope|totalForfeitableBias) and a uint64
    ///      minSubEnd, with no public getter. A bias↔slope swap inside
    ///      either pair would silently miscompute
    ///      `_lockedBias = totalBias - totalSlope * t` in `finalizeSeeding`
    ///      — corrupting the materialized LockedPoint without any test
    ///      failure surface. A change to `minSubEnd`'s position or type
    ///      would break the phantom-carry walk-back. This pins the offsets
    ///      and types explicitly so a future reorder of declarations
    ///      inside `struct SeedingProgress` fails this assertion at CI time
    ///      rather than producing a silent accounting bug post-seed.
    ///      Parallel defense to `test_VeHemi_LockedPointMemberLayout` below.
    function test_VeHemi_SeedingProgressMemberLayout() public view {
        string memory base = ".types.[\"t_struct(SeedingProgress)_storage\"].members";
        // Member 0: uint256 lastProcessedId at slot 0 offset 0.
        assertEq(vm.parseJsonString(veHemiJson, string.concat(base, "[0].label")), "lastProcessedId");
        assertEq(vm.parseJsonString(veHemiJson, string.concat(base, "[0].slot")), "0");
        assertEq(vm.parseJsonString(veHemiJson, string.concat(base, "[0].offset")), "0");
        assertEq(vm.parseJsonString(veHemiJson, string.concat(base, "[0].type")), "t_uint256");
        // Member 1: int128 totalSlope at slot 1 offset 0.
        assertEq(vm.parseJsonString(veHemiJson, string.concat(base, "[1].label")), "totalSlope");
        assertEq(vm.parseJsonString(veHemiJson, string.concat(base, "[1].slot")), "1");
        assertEq(vm.parseJsonString(veHemiJson, string.concat(base, "[1].offset")), "0");
        assertEq(vm.parseJsonString(veHemiJson, string.concat(base, "[1].type")), "t_int128");
        // Member 2: int128 totalBias at slot 1 offset 16.
        assertEq(vm.parseJsonString(veHemiJson, string.concat(base, "[2].label")), "totalBias");
        assertEq(vm.parseJsonString(veHemiJson, string.concat(base, "[2].slot")), "1");
        assertEq(vm.parseJsonString(veHemiJson, string.concat(base, "[2].offset")), "16");
        assertEq(vm.parseJsonString(veHemiJson, string.concat(base, "[2].type")), "t_int128");
        // Member 3: int128 totalForfeitableSlope at slot 2 offset 0.
        assertEq(vm.parseJsonString(veHemiJson, string.concat(base, "[3].label")), "totalForfeitableSlope");
        assertEq(vm.parseJsonString(veHemiJson, string.concat(base, "[3].slot")), "2");
        assertEq(vm.parseJsonString(veHemiJson, string.concat(base, "[3].offset")), "0");
        assertEq(vm.parseJsonString(veHemiJson, string.concat(base, "[3].type")), "t_int128");
        // Member 4: int128 totalForfeitableBias at slot 2 offset 16.
        assertEq(vm.parseJsonString(veHemiJson, string.concat(base, "[4].label")), "totalForfeitableBias");
        assertEq(vm.parseJsonString(veHemiJson, string.concat(base, "[4].slot")), "2");
        assertEq(vm.parseJsonString(veHemiJson, string.concat(base, "[4].offset")), "16");
        assertEq(vm.parseJsonString(veHemiJson, string.concat(base, "[4].type")), "t_int128");
        // Member 5: uint256 count at slot 3 offset 0.
        assertEq(vm.parseJsonString(veHemiJson, string.concat(base, "[5].label")), "count");
        assertEq(vm.parseJsonString(veHemiJson, string.concat(base, "[5].slot")), "3");
        assertEq(vm.parseJsonString(veHemiJson, string.concat(base, "[5].offset")), "0");
        assertEq(vm.parseJsonString(veHemiJson, string.concat(base, "[5].type")), "t_uint256");
        // Member 6: uint64 minSubEnd at slot 4 offset 0.
        assertEq(vm.parseJsonString(veHemiJson, string.concat(base, "[6].label")), "minSubEnd");
        assertEq(vm.parseJsonString(veHemiJson, string.concat(base, "[6].slot")), "4");
        assertEq(vm.parseJsonString(veHemiJson, string.concat(base, "[6].offset")), "0");
        assertEq(vm.parseJsonString(veHemiJson, string.concat(base, "[6].type")), "t_uint64");
    }

    /// @dev Pin the member layout of LockedPoint — slots 17 and 20 hold
    ///      LockedPoint structs but have no public getter, so a bias↔slope or
    ///      timestamp↔blockNumber swap inside this struct would NOT be caught
    ///      by the sentinel tests in VeHemiStorageLayout.t.sol. This test is
    ///      the only forge-test-time defense against that regression.
    function test_VeHemi_LockedPointMemberLayout() public view {
        string memory base = ".types.[\"t_struct(LockedPoint)_storage\"].members";
        // Member 0: int128 bias at slot 0 offset 0.
        assertEq(vm.parseJsonString(veHemiJson, string.concat(base, "[0].label")), "bias");
        assertEq(vm.parseJsonString(veHemiJson, string.concat(base, "[0].slot")), "0");
        assertEq(vm.parseJsonString(veHemiJson, string.concat(base, "[0].offset")), "0");
        assertEq(vm.parseJsonString(veHemiJson, string.concat(base, "[0].type")), "t_int128");
        // Member 1: int128 slope at slot 0 offset 16.
        assertEq(vm.parseJsonString(veHemiJson, string.concat(base, "[1].label")), "slope");
        assertEq(vm.parseJsonString(veHemiJson, string.concat(base, "[1].slot")), "0");
        assertEq(vm.parseJsonString(veHemiJson, string.concat(base, "[1].offset")), "16");
        assertEq(vm.parseJsonString(veHemiJson, string.concat(base, "[1].type")), "t_int128");
        // Member 2: uint64 timestamp at slot 1 offset 0.
        assertEq(vm.parseJsonString(veHemiJson, string.concat(base, "[2].label")), "timestamp");
        assertEq(vm.parseJsonString(veHemiJson, string.concat(base, "[2].slot")), "1");
        assertEq(vm.parseJsonString(veHemiJson, string.concat(base, "[2].offset")), "0");
        assertEq(vm.parseJsonString(veHemiJson, string.concat(base, "[2].type")), "t_uint64");
        // Member 3: uint64 blockNumber at slot 1 offset 8.
        assertEq(vm.parseJsonString(veHemiJson, string.concat(base, "[3].label")), "blockNumber");
        assertEq(vm.parseJsonString(veHemiJson, string.concat(base, "[3].slot")), "1");
        assertEq(vm.parseJsonString(veHemiJson, string.concat(base, "[3].offset")), "8");
        assertEq(vm.parseJsonString(veHemiJson, string.concat(base, "[3].type")), "t_uint64");
    }

    /// @dev Pin the member layout of Point (the V1 globalPointHistory value type).
    ///      Point has a public getter (getGlobalPoint) so sentinel tests already
    ///      catch field swaps — this is defense in depth.
    function test_VeHemi_PointMemberLayout() public view {
        string memory base = ".types.[\"t_struct(Point)_storage\"].members";
        string[6] memory labels = ["bias", "slope", "timestamp", "blockNumber", "amount", "fixedBias"];
        string[6] memory types_ = ["t_int128", "t_int128", "t_uint64", "t_uint64", "t_uint128", "t_uint256"];
        string[6] memory slots = ["0", "0", "1", "1", "1", "2"];
        string[6] memory offsets = ["0", "16", "0", "8", "16", "0"];
        for (uint256 i; i < 6; ++i) {
            string memory idx = string.concat(base, "[", vm.toString(i), "]");
            assertEq(vm.parseJsonString(veHemiJson, string.concat(idx, ".label")), labels[i]);
            assertEq(vm.parseJsonString(veHemiJson, string.concat(idx, ".slot")), slots[i]);
            assertEq(vm.parseJsonString(veHemiJson, string.concat(idx, ".offset")), offsets[i]);
            assertEq(vm.parseJsonString(veHemiJson, string.concat(idx, ".type")), types_[i]);
        }
    }

    /// @dev Pin the member layout of UserPoint. UserPoint has two members:
    ///      `point` (Point struct at slot 0) and `owner` (address at slot 3).
    ///      Total 4 slots. Defense in depth with test_slot7_userPointHistory's
    ///      sentinel round-trip.
    function test_VeHemi_UserPointMemberLayout() public view {
        string memory base = ".types.[\"t_struct(UserPoint)_storage\"].members";
        assertEq(vm.parseJsonString(veHemiJson, string.concat(base, "[0].label")), "point");
        assertEq(vm.parseJsonString(veHemiJson, string.concat(base, "[0].slot")), "0");
        assertEq(vm.parseJsonString(veHemiJson, string.concat(base, "[0].offset")), "0");
        assertEq(vm.parseJsonString(veHemiJson, string.concat(base, "[0].type")), "t_struct(Point)_storage");
        assertEq(vm.parseJsonString(veHemiJson, string.concat(base, "[1].label")), "owner");
        assertEq(vm.parseJsonString(veHemiJson, string.concat(base, "[1].slot")), "3");
        assertEq(vm.parseJsonString(veHemiJson, string.concat(base, "[1].offset")), "0");
        assertEq(vm.parseJsonString(veHemiJson, string.concat(base, "[1].type")), "t_address");
    }

    /// @dev Pin the member layout of LockedBalance.
    function test_VeHemi_LockedBalanceMemberLayout() public view {
        string memory base = ".types.[\"t_struct(LockedBalance)_storage\"].members";
        assertEq(vm.parseJsonString(veHemiJson, string.concat(base, "[0].label")), "amount");
        assertEq(vm.parseJsonString(veHemiJson, string.concat(base, "[0].slot")), "0");
        assertEq(vm.parseJsonString(veHemiJson, string.concat(base, "[0].offset")), "0");
        assertEq(vm.parseJsonString(veHemiJson, string.concat(base, "[0].type")), "t_int128");
        assertEq(vm.parseJsonString(veHemiJson, string.concat(base, "[1].label")), "end");
        assertEq(vm.parseJsonString(veHemiJson, string.concat(base, "[1].slot")), "0");
        assertEq(vm.parseJsonString(veHemiJson, string.concat(base, "[1].offset")), "16");
        assertEq(vm.parseJsonString(veHemiJson, string.concat(base, "[1].type")), "t_uint64");
    }

    // ─── VeHemiVoteDelegation slots ─────────────────────────────────────────

    function test_VeHemiVoteDelegation_AllSlotsAtExpectedPositions() public view {
        _assertDelegationEntry(0, "0", "delegations");
        _assertDelegationEntry(1, "1", "delegateCheckpoints");
        _assertDelegationEntry(2, "2", "expiredDelegations");
        _assertDelegationEntry(3, "3", "nonces");
        _assertDelegationEntry(4, "4", "autoDelegate");
        _assertDelegationEntry(5, "5", "trustedAdapter");
        _assertDelegationEntry(6, "6", "__gapV2");
        _assertDelegationEntry(7, "50", "migrationFinalized");
        _assertDelegationEntry(8, "51", "__gapV3");
    }

    /// @dev Pin the critical types for the Aragon-added slots. A narrowing of
    ///      `trustedAdapter` from address to a smaller width, or a key-type
    ///      change on `autoDelegate`, would shift mapping bases or allow packing.
    function test_VeHemiVoteDelegation_AragonSlotTypes() public view {
        assertEq(
            vm.parseJsonString(delegationJson, ".storage[4].type"),
            "t_mapping(t_address,t_address)",
            "autoDelegate must be mapping(address => address)"
        );
        assertEq(
            vm.parseJsonString(delegationJson, ".storage[5].type"),
            "t_address",
            "trustedAdapter must be address"
        );
    }

    /// @dev Pin VeHemiVoteDelegation's __gapV2 size to uint256[44]. A shrink
    ///      here during a future V3 delegation upgrade would silently lose
    ///      gap slots. The gap lives in VeHemiDelegationStorageV2 following
    ///      the V1/V2 chain-inheritance pattern.
    function test_VeHemiVoteDelegation_GapIsExactly44Slots() public view {
        assertEq(
            vm.parseJsonString(delegationJson, ".storage[6].type"),
            "t_array(t_uint256)44_storage",
            "__gapV2 must be uint256[44]"
        );
        assertEq(
            vm.parseJsonString(delegationJson, ".types.[\"t_array(t_uint256)44_storage\"].label"),
            "uint256[44]",
            "__gapV2 type label"
        );
        assertEq(
            vm.parseJsonString(delegationJson, ".types.[\"t_array(t_uint256)44_storage\"].numberOfBytes"),
            "1408",
            "__gapV2 numberOfBytes (44 * 32)"
        );
        assertEq(
            vm.parseJsonString(delegationJson, ".types.[\"t_array(t_uint256)44_storage\"].base"),
            "t_uint256",
            "__gapV2 element type"
        );
    }

    /// @dev Pin the member layout of VeHemiVoteDelegation's 3 internal structs
    ///      (Delegation, DelegateCheckpoint, Expiration). These structs pack
    ///      narrow integers but have NO public getters that would surface a
    ///      field swap via ABI decoding — the golden fixture is the only
    ///      forge-test-time defense against intra-slot field reorder.

    function test_VeHemiVoteDelegation_DelegationMemberLayout() public view {
        string memory base = ".types.[\"t_struct(Delegation)_storage\"].members";
        // slot 0: address delegatee (offset 0, 20B) + uint48 end (offset 20, 6B) — packed.
        _assertMember(delegationJson, base, 0, "delegatee", "0", "0", "t_address");
        _assertMember(delegationJson, base, 1, "end", "0", "20", "t_uint48");
        // slot 1: uint96 bias (offset 0) + uint96 amount (offset 12) + uint64 slope (offset 24).
        _assertMember(delegationJson, base, 2, "bias", "1", "0", "t_uint96");
        _assertMember(delegationJson, base, 3, "amount", "1", "12", "t_uint96");
        _assertMember(delegationJson, base, 4, "slope", "1", "24", "t_uint64");
        assertEq(
            vm.parseJsonString(delegationJson, ".types.[\"t_struct(Delegation)_storage\"].numberOfBytes"),
            "64",
            "Delegation must be 2 slots"
        );
    }

    function test_VeHemiVoteDelegation_DelegateCheckpointMemberLayout() public view {
        string memory base = ".types.[\"t_struct(DelegateCheckpoint)_storage\"].members";
        // slot 0: uint128 normalizedBias (offset 0) + uint128 fixedBias (offset 16).
        _assertMember(delegationJson, base, 0, "normalizedBias", "0", "0", "t_uint128");
        _assertMember(delegationJson, base, 1, "fixedBias", "0", "16", "t_uint128");
        // slot 1: uint128 totalAmount (offset 0) + uint64 normalizedSlope (offset 16) + uint64 timestamp (offset 24).
        _assertMember(delegationJson, base, 2, "totalAmount", "1", "0", "t_uint128");
        _assertMember(delegationJson, base, 3, "normalizedSlope", "1", "16", "t_uint64");
        _assertMember(delegationJson, base, 4, "timestamp", "1", "24", "t_uint64");
        assertEq(
            vm.parseJsonString(delegationJson, ".types.[\"t_struct(DelegateCheckpoint)_storage\"].numberOfBytes"),
            "64",
            "DelegateCheckpoint must be 2 slots"
        );
    }

    function test_VeHemiVoteDelegation_ExpirationMemberLayout() public view {
        string memory base = ".types.[\"t_struct(Expiration)_storage\"].members";
        // slot 0: uint96 bias (offset 0) + uint96 amount (offset 12) + uint64 slope (offset 24).
        _assertMember(delegationJson, base, 0, "bias", "0", "0", "t_uint96");
        _assertMember(delegationJson, base, 1, "amount", "0", "12", "t_uint96");
        _assertMember(delegationJson, base, 2, "slope", "0", "24", "t_uint64");
        assertEq(
            vm.parseJsonString(delegationJson, ".types.[\"t_struct(Expiration)_storage\"].numberOfBytes"),
            "32",
            "Expiration must be 1 slot"
        );
    }

    function _assertMember(
        string memory json,
        string memory base,
        uint256 i,
        string memory label,
        string memory slot,
        string memory offset,
        string memory typeStr
    ) internal view {
        string memory idx = string.concat(base, "[", vm.toString(i), "]");
        assertEq(vm.parseJsonString(json, string.concat(idx, ".label")), label, label);
        assertEq(vm.parseJsonString(json, string.concat(idx, ".slot")), slot, string.concat(label, ".slot"));
        assertEq(vm.parseJsonString(json, string.concat(idx, ".offset")), offset, string.concat(label, ".offset"));
        assertEq(vm.parseJsonString(json, string.concat(idx, ".type")), typeStr, string.concat(label, ".type"));
    }

    /// @dev VeHemiVoteDelegation has exactly 9 storage entries (6 V1+V2 named +
    ///      V2 gap + V3 named `migrationFinalized` + V3 gap).
    function test_VeHemiVoteDelegation_TotalSlotsExactly9() public {
        uint256 count = _countStorageEntries(delegationJson, 16);
        assertEq(count, 9, "VeHemiVoteDelegation must have exactly 9 storage entries");
        _assertDelegationEntry(6, "6", "__gapV2");
        _assertDelegationEntry(7, "50", "migrationFinalized");
        _assertDelegationEntry(8, "51", "__gapV3");
    }

    function _assertDelegationEntry(
        uint256 i,
        string memory expectedSlot,
        string memory expectedLabel
    ) internal view {
        string memory slotKey = string.concat(".storage[", vm.toString(i), "].slot");
        string memory labelKey = string.concat(".storage[", vm.toString(i), "].label");
        string memory gotSlot = vm.parseJsonString(delegationJson, slotKey);
        string memory gotLabel = vm.parseJsonString(delegationJson, labelKey);
        assertEq(gotSlot, expectedSlot, string.concat("delegation slot mismatch at ", vm.toString(i)));
        assertEq(gotLabel, expectedLabel, string.concat("delegation label mismatch at ", vm.toString(i)));
    }

    // ─── Forge-layer type pinning (NA-3) ────────────────────────────────────
    //
    // The shell gate in scripts/check-storage-layouts.sh already catches any
    // change to the `.type` field (it diffs the full normalized JSON). These
    // tests are a belt-and-suspenders second layer that runs in `forge test`
    // alone, so a CI environment that accidentally dropped the shell step
    // still catches mapping-key or value-type swaps at `forge test` time.

    /// @dev Pin the exact type string for every mapping in VeHemi storage.
    ///      A key-type swap (e.g., `mapping(uint256 => …)` → `mapping(address => …)`
    ///      at the same slot) preserves slot/label/offset but shifts every
    ///      keccak-derived child address — silently corrupting the proxy. The
    ///      encoded type string is the only layout-level signal of this change.
    function test_VeHemi_MappingKeyValueTypesArePinned() public view {
        _assertVeHemiType(6,  "t_mapping(t_uint256,t_struct(Point)_storage)");
        _assertVeHemiType(7,  "t_mapping(t_uint256,t_array(t_struct(UserPoint)_storage)1000000000_storage)");
        _assertVeHemiType(8,  "t_mapping(t_uint256,t_uint256)");
        _assertVeHemiType(9,  "t_mapping(t_uint256,t_int128)");
        _assertVeHemiType(10, "t_mapping(t_uint256,t_struct(LockedBalance)_storage)");
        _assertVeHemiType(11, "t_mapping(t_uint256,t_address)");
        _assertVeHemiType(12, "t_mapping(t_uint256,t_uint256)");
        _assertVeHemiType(13, "t_mapping(t_uint256,t_bool)");
        // V2 mappings (slots 14-15 are __reservedSlotN of type t_uint256, already pinned above).
        _assertVeHemiType(16, "t_mapping(t_uint256,t_int128)");
        _assertVeHemiType(17, "t_mapping(t_uint256,t_struct(LockedPoint)_storage)");
        _assertVeHemiType(18, "t_bool"); // lockedSeedingFinalized — not a mapping, but pin the type.
        _assertVeHemiType(19, "t_mapping(t_uint256,t_int128)");
        _assertVeHemiType(20, "t_mapping(t_uint256,t_struct(LockedPoint)_storage)");
    }

    /// @dev Pin the exact type string for every delegation mapping + trustedAdapter.
    function test_VeHemiVoteDelegation_MappingKeyValueTypesArePinned() public view {
        _assertDelegationType(0, "t_mapping(t_uint256,t_struct(Delegation)_storage)");
        _assertDelegationType(1, "t_mapping(t_address,t_array(t_struct(DelegateCheckpoint)_storage)dyn_storage)");
        _assertDelegationType(2, "t_mapping(t_address,t_mapping(t_uint256,t_struct(Expiration)_storage))");
        _assertDelegationType(3, "t_mapping(t_address,t_uint256)");
        _assertDelegationType(4, "t_mapping(t_address,t_address)");
        _assertDelegationType(5, "t_address");
    }

    /// @dev Pin the `.encoding` field (one of `inplace`, `mapping`, `dynamic_array`,
    ///      `bytes`) for the key types in both layouts. A solc bump that silently
    ///      changed mapping encoding would break every proxy read; this pin guards
    ///      against that at forge-test time.
    function test_VeHemi_StorageEncodings() public view {
        _assertTypeEncoding(veHemiJson, "t_uint256", "inplace");
        _assertTypeEncoding(veHemiJson, "t_address", "inplace");
        _assertTypeEncoding(veHemiJson, "t_bool", "inplace");
        _assertTypeEncoding(veHemiJson, "t_int128", "inplace");
        _assertTypeEncoding(veHemiJson, "t_mapping(t_uint256,t_uint256)", "mapping");
        _assertTypeEncoding(veHemiJson, "t_mapping(t_uint256,t_int128)", "mapping");
        _assertTypeEncoding(veHemiJson, "t_mapping(t_uint256,t_address)", "mapping");
        _assertTypeEncoding(veHemiJson, "t_mapping(t_uint256,t_bool)", "mapping");
        _assertTypeEncoding(veHemiJson, "t_array(t_uint256)36_storage", "inplace");
        _assertTypeEncoding(veHemiJson, "t_struct(Point)_storage", "inplace");
        _assertTypeEncoding(veHemiJson, "t_struct(LockedPoint)_storage", "inplace");
        _assertTypeEncoding(veHemiJson, "t_struct(SeedingProgress)_storage", "inplace");

        _assertTypeEncoding(delegationJson, "t_address", "inplace");
        _assertTypeEncoding(delegationJson, "t_mapping(t_address,t_address)", "mapping");
        _assertTypeEncoding(delegationJson, "t_mapping(t_address,t_uint256)", "mapping");
        _assertTypeEncoding(delegationJson, "t_mapping(t_uint256,t_struct(Delegation)_storage)", "mapping");
        _assertTypeEncoding(delegationJson, "t_array(t_uint256)44_storage", "inplace");
    }

    function _assertVeHemiType(uint256 i, string memory expectedType) internal view {
        string memory got = vm.parseJsonString(veHemiJson, string.concat(".storage[", vm.toString(i), "].type"));
        assertEq(got, expectedType, string.concat("VeHemi type mismatch at entry ", vm.toString(i)));
    }

    function _assertDelegationType(uint256 i, string memory expectedType) internal view {
        string memory got = vm.parseJsonString(delegationJson, string.concat(".storage[", vm.toString(i), "].type"));
        assertEq(got, expectedType, string.concat("delegation type mismatch at entry ", vm.toString(i)));
    }

    function _assertTypeEncoding(string memory json, string memory typeKey, string memory expectedEncoding)
        internal
        view
    {
        string memory got = vm.parseJsonString(json, string.concat(".types.[\"", typeKey, "\"].encoding"));
        assertEq(got, expectedEncoding, string.concat("encoding mismatch for type ", typeKey));
    }
}
