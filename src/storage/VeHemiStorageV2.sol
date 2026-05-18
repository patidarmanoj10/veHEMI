// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {VeHemiStorageV1} from "./VeHemiStorageV1.sol";

/**
 * @title VeHemiStorageV2
 * @notice Storage extension for VeHemi V2 (non-transferrable position weight tracking via locked
 *         and forfeitable subcurves).
 *
 * @dev Inherits VeHemiStorageV1 to enforce the V1-before-V2 slot ordering at the
 *      inheritance level. VeHemi inherits only VeHemiStorageV2, which transitively
 *      includes V1. This is the standard upgradeable-storage chain pattern used by
 *      OpenZeppelin, Aave, Synthetix, Pendle, and Compound — it removes the risk of
 *      a future edit to VeHemi's base list accidentally reordering V1 and V2.
 *
 *      Design decisions:
 *        - `lockedGlobalPointHistory` tracks aggregate (bias, slope) for
 *          non-transferrable positions only, using a minimal 2-slot `LockedPoint`
 *          struct (vs 3-slot `Point`). Saves ~20,000 gas per SSTORE.
 *        - `lockedSlopeChanges` mirrors `slopeChanges` for the locked-only subset.
 *        - `lockedSeedingFinalized` gates all locked-curve logic in `_checkpoint`.
 *          Before finalization, `_checkpoint` skips locked tracking entirely.
 *        - Slots 0-1 (V2-relative) are intra-V2 emergency reserves
 *          (`__reservedSlot0/1`). NOTE: the v75 delegation plan chose Path B
 *          for V3 storage — V3 fields (`restakeManager`, `pendingRestakeManager`,
 *          `pendingForfeitAdmin`, etc.) will land at absolute slot 64+ via a
 *          new `abstract contract VeHemiStorageV3` extending this contract,
 *          NOT by repurposing slots 14/15. These reserved slots remain as
 *          defensive zero-padding for any unforeseen mid-V2 extension that
 *          must precede the subcurve mappings. Do not allocate them lightly.
 *        - A storage gap (`__gapV2`) is reserved for V3-style append-only
 *          extensions that consume the gap rather than the reserved slots.
 */
abstract contract VeHemiStorageV2 is VeHemiStorageV1 {
    /// @dev Reserved slot for future extensions (preserves storage layout).
    uint256 private __reservedSlot0;

    /// @dev Reserved slot for future extensions (preserves storage layout).
    uint256 private __reservedSlot1;

    /// @notice Reduced-size point for locked-only global curve.
    /// @dev 2 storage slots: {bias, slope} in slot N, {timestamp, blockNumber} in slot N+1.
    struct LockedPoint {
        int128 bias;
        int128 slope;
        uint64 timestamp;
        uint64 blockNumber;
    }

    /// @notice Slope changes for non-transferrable positions only.
    ///         time -> signed slope delta (mirrors slopeChanges).
    mapping(uint256 => int128) public lockedSlopeChanges;

    /// @notice Global point history for non-transferrable positions only.
    ///         epoch -> LockedPoint (shares epoch counter with globalPointHistory).
    mapping(uint256 => LockedPoint) internal lockedGlobalPointHistory;

    /// @notice Whether locked position seeding is complete.
    /// @dev When false, _checkpoint skips locked-only and forfeitable tracking.
    bool public lockedSeedingFinalized;

    /// @notice Slope changes for forfeitable (non-transferrable) positions only.
    ///         time -> signed slope delta (mirrors lockedSlopeChanges for the forfeitable subset).
    mapping(uint256 => int128) public forfeitableSlopeChanges;

    /// @notice Global point history for forfeitable (non-transferrable) positions only.
    ///         epoch -> LockedPoint (shares epoch counter with globalPointHistory).
    mapping(uint256 => LockedPoint) internal forfeitableGlobalPointHistory;

    /// @notice True after `markSeedingStarted()` runs and `seedingTargetId` is
    ///         frozen. While this is `true` and `lockedSeedingFinalized` is
    ///         `false`, `_createLock` blocks new non-transferable positions —
    ///         this prevents an adversary from extending the seeding range
    ///         with a self-funded non-transferable mint that would then be
    ///         missed by the seeding scan.
    /// @dev Packs with `seedingStartedAt` in the same storage slot.
    bool public seedingStarted;

    /// @notice `block.timestamp` at the moment `markSeedingStarted()` ran.
    ///         Informational only — exposes the window-open time to
    ///         off-chain monitors. Operators MUST drive `seedBatch` →
    ///         `finalizeSeeding` to completion within hours of this
    ///         timestamp to keep finalize ahead of any seeded position's
    ///         `subEnd`. `_createLock` enforces a `2 * SIX_DAYS` minimum
    ///         at mint; after the SIX_DAYS rounding in `unlockTime`, the
    ///         worst-case floor is ~6 days (one bucket) for newly-minted
    ///         positions and ~12 days typical. See
    ///         `VeHemi.finalizeSeeding` NatSpec for the precise
    ///         constraint.
    uint64 public seedingStartedAt;

    /// @notice Exclusive upper bound on token IDs that `seedBatch` iterates.
    ///         Snapshotted from `nextTokenId` at `markSeedingStarted` time so
    ///         the seeding range is fixed at start and cannot drift mid-flow.
    uint256 public seedingTargetId;

    /// @notice Accumulator carried across multiple `seedBatch` calls. The
    ///         struct packs `lastProcessedId` (1 slot) + two int128 pairs
    ///         (2 slots) + `count` (1 slot) + `minSubEnd` (1 slot) = 5 slots
    ///         total. Cleared (`delete`) during `finalizeSeeding` after the
    ///         aggregate `SupplyPoint`s are written.
    ///
    /// @dev `minSubEnd` is the earliest `subEnd` across all positions
    ///      INCLUDED by `seedBatch` (i.e., positions that passed the
    ///      burned/transferable/expired/empty skip predicates). It is used
    ///      by `finalizeSeeding` to detect "phantom carry": if `minSubEnd <
    ///      block.timestamp` at finalize time, at least one seeded
    ///      position's `subEnd` has lapsed during the seeding window. The
    ///      slope-change at that `subEnd` was eagerly written by
    ///      `seedBatch` but lives in a past bucket — the post-finalize
    ///      forward walk would never revisit it. Finalize instead walks
    ///      from `minSubEnd` to `block.timestamp` consuming the stranded
    ///      slope-changes before writing the LockedPoint, producing a
    ///      correct seeded subcurve regardless of `subEnd` distribution.
    ///      Sentinel value `0` = "no positions seeded yet" (no live
    ///      non-transferable position can have `subEnd == 0`).
    struct SeedingProgress {
        uint256 lastProcessedId;
        int128 totalSlope;
        int128 totalBias;
        int128 totalForfeitableSlope;
        int128 totalForfeitableBias;
        uint256 count;
        uint64 minSubEnd;
    }

    /// @notice In-progress seeding accumulator. See `SeedingProgress`.
    SeedingProgress internal _seedingProgress;

    /// @dev Reserved storage slots for future upgrades.
    ///      Storage layout (relative to V2 start):
    ///        Slot 0:    __reservedSlot0
    ///        Slot 1:    __reservedSlot1
    ///        Slot 2:    lockedSlopeChanges (mapping base)
    ///        Slot 3:    lockedGlobalPointHistory (mapping base)
    ///        Slot 4:    lockedSeedingFinalized (bool)
    ///        Slot 5:    forfeitableSlopeChanges (mapping base)
    ///        Slot 6:    forfeitableGlobalPointHistory (mapping base)
    ///        Slot 7:    seedingStarted (bool, 1B) + seedingStartedAt (uint64, 8B) packed
    ///        Slot 8:    seedingTargetId (uint256)
    ///        Slots 9-13: _seedingProgress (5 slots)
    ///      Total named slots: 14. Gap: 50 - 14 = 36.
    uint256[36] private __gapV2;
}
