// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {VeHemiStorageV1} from "./VeHemiStorageV1.sol";

/**
 * @title VeHemiStorageV2
 * @notice Storage extension for VeHemi V2 (non-transferrable position weight tracking via
 *         parallel non-transferable and forfeitable subcurves alongside the global curve).
 *
 * @dev TERMINOLOGY — IMPORTANT, READ FIRST
 * ---------------------------------------------------------------------------
 * The `nonTransferable*` identifiers in this file track the subset of
 * positions where `transferableAfter != 0` — i.e. positions the owner
 * cannot transfer until `transferableAfter` is reached. Do NOT confuse
 * with the general vote-escrow notion of "locked HEMI": every veHEMI
 * position has HEMI time-locked in this contract regardless of
 * transferability (that's the point of vote-escrow).
 *
 * Historical note: earlier drafts called this subcurve the "locked" curve.
 * Variables and function names were renamed to `nonTransferable*` to match
 * the view-surface naming and the defining predicate. The compact point
 * type is still called `SupplyPoint` because it is a generic 2-slot Point
 * shape reused by BOTH subcurves (non-transferable AND forfeitable); its
 * name describes the struct layout, not the data it holds.
 *
 * Public view surface:
 *   - `nonTransferableTotalVeHemiSupply()` / `...At(t)`
 *   - `forfeitableTotalVeHemiSupply()` / `...At(t)`
 *   - `supplyBreakdown()` returns `(total, locked_, forfeitable_, transferable)`
 *     where `locked_` is the aggregate of `nonTransferableGlobalPointHistory`
 *     (the `locked_` return-parameter name is kept for backwards
 *     compatibility with off-chain consumers).
 *
 * Membership predicate (checked in `VeHemi._checkpoint`):
 *   - Non-transferable curve : `transferableAfter[tokenId] != 0`
 *   - Forfeitable curve      : above AND `forfeitable[tokenId] == true`
 *   - Transferable           : NOT in non-transferable curve;
 *                              derived as `total − nonTransferable`
 *
 * Set relationship (always holds):
 *   forfeitable ⊆ nonTransferable ⊆ global
 *
 * Subcurve "effective end" is `min(lock.end, transferableAfter)`, so a
 * non-transferable position that gets `increaseUnlockTime`'d past its
 * original transferability date exits the non-transferable/forfeitable
 * subcurves at the ORIGINAL `transferableAfter` while retaining its
 * global voting power until the new `lock.end`.
 * ---------------------------------------------------------------------------
 *
 * @dev Inherits VeHemiStorageV1 to enforce the V1-before-V2 slot ordering at the
 *      inheritance level. VeHemi inherits only VeHemiStorageV2, which transitively
 *      includes V1. This is the standard upgradeable-storage chain pattern used by
 *      OpenZeppelin, Aave, Synthetix, Pendle, and Compound — it removes the risk of
 *      a future edit to VeHemi's base list accidentally reordering V1 and V2.
 *
 *      Design decisions:
 *        - `nonTransferableGlobalPointHistory` tracks aggregate (bias, slope) for
 *          non-transferrable positions only, using a minimal 2-slot `SupplyPoint`
 *          struct (vs 3-slot `Point`). Saves ~20,000 gas per SSTORE.
 *        - `nonTransferableSlopeChanges` mirrors `slopeChanges` for the non-transferable subset.
 *        - `nonTransferableSeedingFinalized` gates all subcurve logic in `_checkpoint`.
 *          Before finalization, `_checkpoint` skips subcurve tracking entirely.
 *        - Slots 0-1 (V2-relative) are reserved for future use (preserves storage
 *          layout for any field that should logically sit between the V1 boundary
 *          and the subcurve state — e.g., a future V3 extension).
 *        - A storage gap is reserved for future extensions.
 */
abstract contract VeHemiStorageV2 is VeHemiStorageV1 {
    /// @dev Reserved slot for future extensions (preserves storage layout).
    uint256 private __reservedSlot0;

    /// @dev Reserved slot for future extensions (preserves storage layout).
    uint256 private __reservedSlot1;

    /// @notice Reduced-size point used by both subcurves (non-transferable and forfeitable).
    /// @dev 2 storage slots: {bias, slope} in slot N, {timestamp, blockNumber} in slot N+1.
    ///      The name describes the compact layout, not a specific curve — both the
    ///      non-transferable and the forfeitable subcurve histories use this type.
    struct SupplyPoint {
        int128 bias;
        int128 slope;
        uint64 timestamp;
        uint64 blockNumber;
    }

    /// @notice Slope changes for non-transferrable positions only.
    ///         time -> signed slope delta (mirrors slopeChanges).
    mapping(uint256 => int128) public nonTransferableSlopeChanges;

    /// @notice Global point history for non-transferrable positions only.
    ///         epoch -> SupplyPoint (shares epoch counter with globalPointHistory).
    mapping(uint256 => SupplyPoint) internal nonTransferableGlobalPointHistory;

    /// @notice Whether non-transferable position seeding is complete.
    /// @dev When false, _checkpoint skips non-transferable and forfeitable tracking.
    bool public nonTransferableSeedingFinalized;

    /// @notice Slope changes for forfeitable (non-transferrable) positions only.
    ///         time -> signed slope delta (mirrors nonTransferableSlopeChanges for the forfeitable subset).
    mapping(uint256 => int128) public forfeitableSlopeChanges;

    /// @notice Global point history for forfeitable (non-transferrable) positions only.
    ///         epoch -> SupplyPoint (shares epoch counter with globalPointHistory).
    mapping(uint256 => SupplyPoint) internal forfeitableGlobalPointHistory;

    /// @dev Reserved storage slots for future upgrades.
    ///      Storage layout (relative to V2 start):
    ///        Slot 0: __reservedSlot0
    ///        Slot 1: __reservedSlot1
    ///        Slot 2: nonTransferableSlopeChanges (mapping base)
    ///        Slot 3: nonTransferableGlobalPointHistory (mapping base)
    ///        Slot 4: nonTransferableSeedingFinalized (bool)
    ///        Slot 5: forfeitableSlopeChanges (mapping base)
    ///        Slot 6: forfeitableGlobalPointHistory (mapping base)
    ///      Total named slots: 7. Gap: 50 - 7 = 43.
    uint256[43] private __gapV2;
}
