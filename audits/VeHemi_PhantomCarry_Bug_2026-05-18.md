# VeHemi V2 — Phantom Carry Bug in Subcurve Seeding

**Date:** 2026-05-18
**Branch:** `max/aragon_and_position_curves` (not yet on `main`, not deployed)
**Severity:** Low (data accuracy in view-only functions; no fund safety, no governance hijack)
**Status:** Open

---

## TL;DR

`seedBatch` writes a slope-reduction entry at each seeded position's `subEnd`. If `subEnd` falls **before** `finalizeSeeding`'s timestamp (`tsFinal`), that slope-reduction entry is stranded in a past bucket — the post-finalize supply walk only steps forward from `tsFinal` and never revisits past buckets. The locked/forfeitable subcurves then carry the stranded slope forward forever, causing `nonTransferableTotalVeHemiSupply()`, `forfeitableTotalVeHemiSupply()`, and `supplyBreakdown()` to **under-count** locked supply (and **over-count** transferable supply) until the bias clamps to zero — possibly years earlier than reality.

The fix is to make `finalizeSeeding` walk from the earliest seeded `subEnd` forward to `tsFinal`, consuming each stranded slope-change along the way, before writing the LockedPoint.

---

## Part 1 — The math you need to understand

This bug is about **slope-change bookkeeping in a linear-decay voting escrow**. Skip to Part 4 if you're already comfortable with veCRV-style curve math.

### 1.1 A single lock's voting weight

When a user locks `amount` HEMI until `end`, their voting weight (bias) decays linearly to zero:

```
slope    = amount / MAX_TIME        // wei per second
bias(t)  = slope * (end - t)        // for t < end
bias(t)  = 0                        // for t >= end
```

ASCII visualization for one position with `amount=100`, `end=1000`, `MAX_TIME=100` (so `slope=1`):

```
bias
  │
1000┤●
  │ ╲
800 ┤  ╲
  │    ╲
600 ┤      ╲
  │        ╲
400 ┤          ╲
  │            ╲
200 ┤              ╲
  │                ╲
  0 ┤────────────────●─────  bias clamped to 0 after end
  │
  └──┬─────┬─────┬─────┬──── time
     0    250   500   750  1000=end
```

The slope is constant (`= 1`) from `t=0` to `t=end=1000`. Then the position "drops out" — its slope contribution must stop.

### 1.2 The aggregate curve with many positions

The system stores a single `(globalBias, globalSlope)` representing the SUM of all positions' biases and slopes. Decay between two times `(t1, t2)` is:

```
globalBias(t2) = globalBias(t1) - globalSlope * (t2 - t1)
```

This works only if `globalSlope` is constant between `t1` and `t2`. When a position expires, its slope must be **subtracted** from `globalSlope` at that moment, otherwise the global bias would keep decaying as if the expired position were still alive.

### 1.3 The `slope_changes` mapping — the load-bearing mechanism

To track when slopes change, the contract stores:

```solidity
mapping(uint256 => int128) slopeChanges;  // bucket-time → signed slope delta
```

When a position with `slope=S` and `end=E` is created, the contract writes:

```
slopeChanges[E] -= S       // "at time E, the global slope drops by S"
```

The supply walk reads this mapping when crossing each `SIX_DAYS` boundary:

```
for each bucket t_i from last_checkpoint to now:
    globalBias  -= globalSlope * (t_i - last_t)
    globalSlope += slopeChanges[t_i]    // <-- consume the slope change
    last_t = t_i
```

This is **the algorithm**. veCRV invented it, veAERO inherited it, veHEMI uses it. Every veCRV-derived bug in history involves either the slope_changes mapping being written wrong, read wrong, or revisited wrong.

### 1.4 Worked example: two positions, aggregate decay

Two positions:
- **L** (long): `slope=1`, `end=1000`. Contributes `1*(1000-t)` to bias.
- **S** (short): `slope=1`, `end=100`. Contributes `1*(100-t)` to bias for `t<100`, else 0.

```
slopeChanges:
  [100]  = -1   (from S)
  [1000] = -1   (from L)

Aggregate at t=0:
  globalBias  = (1*1000) + (1*100) = 1100
  globalSlope = 1 + 1 = 2

Decay from t=0 to t=100:
  bias = 1100 - 2*100 = 900
  apply slopeChanges[100]: slope = 2 + (-1) = 1
  (now S has dropped out; only L's slope remains)

Decay from t=100 to t=1000:
  bias = 900 - 1*900 = 0
  apply slopeChanges[1000]: slope = 1 + (-1) = 0
  (now L has dropped out)
```

Visualization:

```
bias
  │
1100┤●
  │ ╲
900 ┤  ●─── slope changes from 2 → 1 at t=100 (S drops out)
  │   ╲
  │    ╲
  │     ╲
500 ┤      ╲
  │        ╲
  │          ╲
  │            ╲
  0 ┤──────────────●──  slope changes from 1 → 0 at t=1000 (L drops out)
  │
  └──┬───┬─────┬─────┬───── time
     0 100    500   1000

slope:  ─2─┤ ──────1──────┤ ─0─
```

The kink at `t=100` is the slope change from S expiring. Without `slopeChanges[100]`, the line would keep falling at slope 2 and hit zero at `t=550` — half the true lifespan.

**This is exactly what the phantom carry bug does to the subcurve.** Keep this kink in mind.

---

## Part 2 — The three curves in veHEMI V2

veHEMI tracks three parallel `(bias, slope)` curves:

| Curve | Tracks | Effective end per position |
|---|---|---|
| **Global** (V1, always live) | All positions | `lock.end` |
| **Locked subcurve** (V2) | Non-transferable positions only | `subEnd = min(lock.end, transferableAfter)` |
| **Forfeitable subcurve** (V2) | Forfeitable subset of locked | `subEnd` |

A "non-transferable" position has `transferableAfter > 0` and cannot be transferred via `transferFrom` until `block.timestamp >= transferableAfter`. After that point it's tradable on the open market — so even though its voting weight continues until `lock.end`, the user's "locked stake" promise ends at `transferableAfter`. The locked subcurve tracks the latter.

This means **the same position contributes to two curves with two different end times**:
- Global curve: contributes until `lock.end`.
- Locked subcurve: contributes only until `subEnd = transferableAfter` (typically earlier).

Each curve has its own `slopeChanges` mapping:
- `slopeChanges[lock.end] -= slope` (global)
- `lockedSlopeChanges[subEnd] -= slope` (locked subcurve)
- `forfeitableSlopeChanges[subEnd] -= slope` (forfeitable subcurve, if applicable)

---

## Part 3 — The seeding flow

V2 was deployed as an upgrade over V1. At upgrade time, the contract already had thousands of live non-transferable positions, but the locked/forfeitable subcurves were empty (V1 didn't track them). The **seeding** flow scans every existing position and builds the initial `(bias, slope)` state for the two subcurves.

The three-phase flow:

```
markSeedingStarted()         seedBatch(N) × many                finalizeSeeding()
   |                            |                                  |
   t0                           t1, t2, t3, ...                    tsFinal
   │                                                                │
   │← non-transferable mints/mutations blocked the entire window ──→│
```

What each phase does:

### Phase 1: `markSeedingStarted` (owner)

- Freeze the seed range: `seedingTargetId = nextTokenId`.
- Block non-transferable mints/mutations.
- Initialize the in-progress accumulator (`_seedingProgress`).

### Phase 2: `seedBatch(maxIterations)` (permissionless, repeatable)

For each `id` in `[cursor+1, cursor+maxIterations)`:
- Skip if burned, transferable, or already expired.
- Compute `slope = lock.amount / MAX_TIME` and `subEnd = min(lock.end, transferableAfter)`.
- Accumulate into the time-independent totals:
  ```
  progress.totalSlope += slope
  progress.totalBias  += slope * subEnd      // ← note: absolute subEnd, not (subEnd - now)
  ```
- **Write the slope change at `subEnd`:**
  ```
  lockedSlopeChanges[subEnd] -= slope
  (and forfeitableSlopeChanges[subEnd] -= slope if forfeitable)
  ```

### Phase 3: `finalizeSeeding` (permissionless, one-shot)

- Materialize the LockedPoint at `tsFinal = block.timestamp`:
  ```
  lockedBias = totalBias - totalSlope * tsFinal
             = Σ slope_i * subEnd_i  -  tsFinal * Σ slope_i
             = Σ slope_i * (subEnd_i - tsFinal)
  ```
  (This is the aggregate bias at `tsFinal`, computed from the time-independent totals.)
- Write `lockedGlobalPointHistory[epoch] = LockedPoint(bias, slope=totalSlope, timestamp=tsFinal)`.
- Flip the latch: `lockedSeedingFinalized = true`.

### Why the math works in steady state

The materialized LockedPoint **is correct at `tsFinal`** as long as every seeded position is still in its non-transferable window at that moment (i.e., `subEnd > tsFinal` for all seeded positions). After finalize, future supply queries walk forward from `tsFinal`, consuming `lockedSlopeChanges` at each `SIX_DAYS` boundary — including the entries written by `seedBatch`. Each position drops out of the subcurve at its `subEnd`, exactly as if the curve had been live throughout V1.

---

## Part 4 — The phantom carry bug

### 4.1 The trigger

The math above assumes `subEnd > tsFinal` for every seeded position. If even one position has `subEnd ≤ tsFinal`:

- That position's `slope * (subEnd - tsFinal)` contribution is **negative** (correctly netting it out of the aggregate `lockedBias`).
- But the slope change `lockedSlopeChanges[subEnd] -= slope` is in a **past bucket** relative to `tsFinal`.
- Post-finalize supply queries walk forward from `tsFinal` in `SIX_DAYS` steps. **They never visit past buckets.** So the slope reduction is never applied.
- The phantom slope keeps subtracting bias from the curve indefinitely.

### 4.2 When this triggers in practice

The `subEnd` of a position can fall before `tsFinal` if:

1. The position's `subEnd` was already in the past at `markSeedingStarted` time → `seedBatch` skips it (filter at `src/VeHemi.sol:1285`). **Not a trigger.**
2. The position's `subEnd` is in the future at `seedBatch` time but in the past at `finalizeSeeding` time. **This is the trigger.** Requires `subEnd ∈ (markSeedingStarted, finalizeSeeding)`.

In production, this requires a position with `subEnd` falling inside the seeding window. The window is meant to be hours-long; `MIN_LOCK_DURATION = 2 * SIX_DAYS ≈ 12 days` floors `subEnd` distance from the start of any short fresh lock. But:

- Existing positions can be near their `subEnd` at window-open time.
- An operator could open the window without checking off-chain that all `subEnds` are comfortably in the future.

### 4.3 Two distinct symptoms

The bug manifests through two paths:

**Path A: `withdraw` of an expired non-transferable position during the window.**
The position's `lock.end` has passed (so `withdraw` is callable), which means `subEnd ≤ lock.end ≤ now < tsFinal`. The position is burned. The accumulator already includes its (slope, subEnd) and the slope-change at `subEnd` was already written. Both are now stranded.

**Path B: a non-transferable position becomes transferable during the window.**
The position's `transferableAfter` crosses `now`. The position is still alive but should logically exit the subcurve. `subEnd = transferableAfter` is now in the past. Same stranded-slope-change problem. (Doesn't require any user action — purely time-driven.)

Both reduce to the same root cause: **a seeded position's `subEnd` is in the past when `finalizeSeeding` runs**.

---

## Part 5 — Worked numerical example

Setup (toy numbers for clarity):

```
MAX_TIME = 100
SIX_DAYS = 10

Position L (long):
  amount = 100,  lock.end = 1000,  transferableAfter = 1000
  slope = 100/100 = 1
  subEnd = 1000

Position S (short):
  amount = 100,  lock.end = 100,  transferableAfter = 100
  slope = 100/100 = 1
  subEnd = 100

Timeline:
  t = 50   markSeedingStarted
  t = 60   seedBatch processes both
  t = 150  finalizeSeeding
            ^^^^ subEnd_S = 100 is INSIDE the (50, 150) window
```

### 5.1 What `seedBatch` writes (at t=60)

```
progress.totalSlope = slope_L + slope_S = 2
progress.totalBias  = slope_L * subEnd_L + slope_S * subEnd_S
                    = 1*1000 + 1*100
                    = 1100

lockedSlopeChanges[1000] = -1     // from L
lockedSlopeChanges[100]  = -1     // from S
```

### 5.2 What happens between t=60 and t=150

- At `t=100`, S's lock expires. Bob can call `withdraw(S)`. Whether he does or doesn't, **the math is the same** — Path B (just time crossing `subEnd`) is enough to trigger.
- The seeding window stays open. `_checkpoint` does not touch subcurve state (gated on `lockedSeedingFinalized=false`).
- `lockedSlopeChanges[100] = -1` sits there, unconsumed.

### 5.3 What `finalizeSeeding` writes (at t=150)

```
lockedBias = totalBias - totalSlope * tsFinal
           = 1100 - 2*150
           = 800

LockedPoint = { bias: 800, slope: 2, timestamp: 150 }
```

Compare to **truth at t=150**: only L is active.
```
true_bias  = slope_L * (end_L - tsFinal) = 1 * (1000 - 150) = 850
true_slope = slope_L = 1
```

The seeded LockedPoint says `(bias=800, slope=2)`. Truth says `(bias=850, slope=1)`. The bias is **under-counted by 50** (= `slope_S * (tsFinal - subEnd_S) = 1*50`) and the slope is **over-counted by 1** (= `slope_S`).

The stranded `lockedSlopeChanges[100] = -1` is the smoking gun: it should have brought the slope from 2 down to 1, but no future walk will ever consume it.

### 5.4 What the supply curve looks like over time

**True locked subcurve:**

```
locked bias
  │
1000┤●  (only L is alive after t=100; bias = 1*(1000-t))
  │ ╲
800 ┤  ●─── slope = 2 → 1 at t=100 (S drops out)
  │   ╲
  │    ╲___      <- decays at slope 1 for the rest of L's life
  │        ╲___
500 ┤           ╲___
  │                ╲___
  │                    ╲___
  │                         ╲___
  0 ┤─────────────────────────────●  reaches 0 at t=1000
  │
  └──┬───┬─────┬─────┬───── time
     0 100    500   1000
```

**Seeded locked subcurve (with bug):**

```
locked bias
  │
1000┤
  │
800 ┤    ●  ← LockedPoint written at t=150 (bias=800, slope=2)
  │     ╲
  │      ╲
  │       ╲           <- decays at slope=2 (phantom), NOT slope=1
  │        ╲
500 ┤         ╲
  │           ╲
  │            ╲
  │              ╲
  0 ┤────────────●─────────────────  reaches 0 at t=550
  │             ↑
  │             550 (true curve still at bias=450 here)
  └──┬─────┬─────┬─────┬───── time
     0   150   550   1000
```

**Overlay (truth vs seeded):**

```
locked bias
  │       TRUTH
  │       ────────
850 ┤●────╲                                       SEEDED
  │       ╲___                                    - - - -
800 ┤    ╳─    ╲___        truth slope = 1
  │   ╱  ╲         ╲___
  │  ╱    ╲             ╲___
  │ ╱      ╲                 ╲___
500 ┤        ╲                     ╲___
  │           ╲ seeded slope = 2        ╲___
  │            ╲                             ╲___
  │             ╲                                 ╲___
  0 ┤              ●─────────────────────────────────●
  │              550 (seeded clamps)              1000 (truth clamps)
  └─────────────────────────────────────────────────── time

Gap = under-count, growing linearly until t=550, then = entire truth value.
```

### 5.5 Querying at t=200

Walk through `_subcurveSupplyAtFromPoint` starting from `(bias=800, slope=2, ts=150)`:

```
t_i = (150/10)*10 = 150
iter 1: t_i = 160. dSlope = lockedSlopeChanges[160] = 0.
        bias -= 2 * (160-150) = 20.  bias = 780.  slope = 2.  ts = 160.
iter 2: t_i = 170. bias = 760.
iter 3: t_i = 180. bias = 740.
iter 4: t_i = 190. bias = 720.
iter 5: t_i = 200 (= timestamp_, break). bias -= 2*10 = 20. bias = 700.

Seeded returns: 700
True at t=200: 1 * (1000 - 200) = 800
Under-count: 100
```

The walk visited 160, 170, 180, 190 — all empty. It did **not** visit 100, where the slope change sits.

### 5.6 When does the seeded curve clamp to zero?

```
seeded_bias(t) = 800 - 2 * (t - 150) = 0
                t = 150 + 400 = 550
```

The seeded subcurve reports `locked = 0` from `t=550` onward. The true subcurve doesn't reach zero until `t=1000`. **The locked supply view is wrong for 450 time units (almost half of L's remaining life).**

---

## Part 6 — Impact on view functions

| Function | Returns | After-finalize correctness with carry |
|---|---|---|
| `nonTransferableTotalVeHemiSupply()` | locked bias at now | **Under-counted** |
| `nonTransferableTotalVeHemiSupplyAt(t)` | locked bias at t | **Under-counted** for `t > tsFinal` |
| `forfeitableTotalVeHemiSupply()` | forfeitable bias at now | **Under-counted** |
| `forfeitableTotalVeHemiSupplyAt(t)` | forfeitable bias at t | **Under-counted** for `t > tsFinal` |
| `supplyBreakdown().total` | global bias at now | Correct (global curve untouched) |
| `supplyBreakdown().locked_` | locked bias at now (capped at total) | **Under-counted** |
| `supplyBreakdown().forfeitable_` | forfeitable bias at now | **Under-counted** |
| `supplyBreakdown().transferable` | total - locked_ | **Over-counted** (mirrors locked_ under-count) |

The defensive caps `forfeitable ≤ locked ≤ total` **don't help** — they guard against over-count (`locked > total`), but phantom carry is an under-count. The ordering invariant stays satisfied even while all three subcurve numbers are wrong.

### 6.1 Downstream impact

- **Reward distribution by locked share** (if implemented): transferable holders receive an inflated share.
- **Governance gating by locked quorum** (if implemented): locked-quorum proposals are easier to pass.
- **Dashboards / subgraphs**: "Total locked" widget reads lower than reality, eventually shows 0 while real positions still exist.
- **Fund safety / governance correctness**: **unaffected**. The global curve is correct, `balanceOfNFT` is correct, Aragon's `getVotes`/`getPastVotes` is correct.

### 6.2 Why this is currently low-severity

No on-chain consumer in `src/` reads the subcurve views. They exist for future consumers (dashboards, differential rewards, sybil-gated governance modules). Severity rises if and when those consumers come online.

---

## Part 7 — The fix: walk-back in finalize

### 7.1 Intuition

The bug: `lockedSlopeChanges[subEnd] -= slope` for `subEnd < tsFinal` is stranded.
The fix: **consume those stranded entries inside `finalizeSeeding`** before writing the LockedPoint.

`seedBatch` tracks the **earliest** `subEnd` it sees (`minSubEnd`). In `finalizeSeeding`, instead of writing the LockedPoint with the naive formula `totalBias - totalSlope * tsFinal`, walk the subcurve from `minSubEnd` forward to `tsFinal` in `SIX_DAYS` buckets, applying `lockedSlopeChanges[t_i]` at each step. The final state at `tsFinal` is correct.

### 7.2 The walk produces the right state

Starting state at `t = minSubEnd` (just before any drop-off):
```
bias_at_minSubEnd  = totalBias - totalSlope * minSubEnd
                   = Σ slope_i * (subEnd_i - minSubEnd)         [time-independent identity]
slope_at_minSubEnd = totalSlope
```

At `t = minSubEnd`, positions with `subEnd_i == minSubEnd` are about to drop. Apply `lockedSlopeChanges[minSubEnd]`:
```
slope := slope + lockedSlopeChanges[minSubEnd]    // drops the slope of expiring positions
```

Then walk forward in `SIX_DAYS` steps. At each bucket `t_i`:
```
bias  := bias - slope * (t_i - ts)
slope := slope + lockedSlopeChanges[t_i]
ts    := t_i
```

Continue until `ts == tsFinal`. The resulting `(bias, slope)` is the correct LockedPoint state.

### 7.3 Re-running the example with the fix

```
minSubEnd = 100   (S's subEnd; the earliest among {100, 1000})

bias_at_100  = 1100 - 2*100 = 900    (sum of slope_i*(subEnd_i - 100):
                                       L: 1*(1000-100) = 900
                                       S: 1*(100-100) = 0
                                       Total: 900 ✓)
slope_at_100 = 2

Apply lockedSlopeChanges[100] = -1:
  slope = 2 + (-1) = 1     (S has dropped out)

Walk forward to tsFinal = 150:
  t_i = 110.  dSlope = 0.  bias -= 1*10 = 890.  slope = 1.  ts = 110.
  t_i = 120.  bias = 880.
  t_i = 130.  bias = 870.
  t_i = 140.  bias = 860.
  t_i = 150 (= tsFinal). bias -= 1*10 = 850.  break.

LockedPoint = { bias: 850, slope: 1, timestamp: 150 }
```

Compare to truth at t=150: `bias = 850, slope = 1`. **Match.** ✓

Query at t=200 with the fixed LockedPoint:
```
Walk from (850, 1, 150):
  t_i = 160. bias = 840.
  t_i = 170. bias = 830.
  ...
  t_i = 200. bias = 850 - 1*50 = 800.

Returns: 800.
True: 800. ✓
```

The seeded curve now matches truth.

### 7.4 Gas cost

The walk iterates `(tsFinal - minSubEnd) / SIX_DAYS` buckets — bounded by:

```
worst-case window duration = N * SIX_DAYS ≈ N * 6 days
worst-case iterations       = N
```

For a window of "a few hours" (operationally mandated), `tsFinal - minSubEnd` is at most a few hours plus some position's earliest `subEnd` offset. If the operator follows the runbook (no position with `subEnd` inside the window), `minSubEnd > tsFinal` and the walk runs **zero iterations** — bytecode-identical-output to the current code.

For pathological cases (operator opens window with positions about to expire), the walk caps at 255 iterations (same as `_subcurveSupplyAtFromPoint`). Each iteration is ~5K gas (one SLOAD on `lockedSlopeChanges` + one SLOAD on `forfeitableSlopeChanges` + arithmetic). 255 × 5K × 2 curves = ~2.5M gas worst case, well within block budget at finalize time.

### 7.5 Patch sketch

#### Storage change (`src/storage/VeHemiStorageV2.sol`)

```solidity
struct SeedingProgress {
    uint256 lastProcessedId;
    int128 totalSlope;
    int128 totalBias;
    int128 totalForfeitableSlope;
    int128 totalForfeitableBias;
    uint256 count;
    uint64 minSubEnd;            // NEW. 0 = no positions seeded.
    // (uint64 packs into the existing tail; check golden fixture for slot alignment)
}
```

Update `__gapV2` count and regenerate `test/fixtures/storage-layouts/VeHemi.json`. (Safe — V2 isn't deployed.)

#### `seedBatch` change (`src/VeHemi.sol:1279-1305`)

Inside the per-id loop, after computing `_subEnd`:

```solidity
// Track the earliest subEnd for the finalize walk-back.
uint64 _subEnd64 = uint64(_subEnd);
if (batchMinSubEnd == 0 || _subEnd64 < batchMinSubEnd) {
    batchMinSubEnd = _subEnd64;
}
```

After the loop, flush to storage:

```solidity
if (batchMinSubEnd != 0) {
    uint64 _existingMin = progress.minSubEnd;
    if (_existingMin == 0 || batchMinSubEnd < _existingMin) {
        progress.minSubEnd = batchMinSubEnd;
    }
}
```

#### `finalizeSeeding` change (`src/VeHemi.sol:1390-1414`)

Replace the direct bias formula with:

```solidity
uint256 _walkStart = progress.minSubEnd;
int128 _lockedBias;
int128 _lockedSlope;
int128 _forfBias;
int128 _forfSlope;

if (_walkStart == 0 || _walkStart >= block.timestamp) {
    // Happy path: no seeded subEnd has lapsed. Direct formula is correct.
    _lockedBias  = _totalBias - _totalSlope * _tsInt;
    _lockedSlope = _totalSlope;
    _forfBias    = _totalForfeitableBias - _totalForfeitableSlope * _tsInt;
    _forfSlope   = _totalForfeitableSlope;
} else {
    // Carry-mitigation walk: consume stranded slope-changes from minSubEnd → tsFinal.
    (_lockedBias, _lockedSlope) = _materializeFromAccumulator(
        _totalBias, _totalSlope, _walkStart, block.timestamp, false
    );
    (_forfBias, _forfSlope) = _materializeFromAccumulator(
        _totalForfeitableBias, _totalForfeitableSlope, _walkStart, block.timestamp, true
    );
}

if (_lockedBias < 0) _lockedBias = 0;
if (_forfBias < 0)   _forfBias = 0;

lockedGlobalPointHistory[_epoch] = LockedPoint({
    bias: _lockedBias,
    slope: _lockedSlope,
    timestamp: block.timestamp.toUint64(),
    blockNumber: block.number.toUint64()
});

forfeitableGlobalPointHistory[_epoch] = LockedPoint({
    bias: _forfBias,
    slope: _forfSlope,
    timestamp: block.timestamp.toUint64(),
    blockNumber: block.number.toUint64()
});
```

#### New helper

```solidity
/// @dev Walk a subcurve from `walkStart` forward to `tsFinal`, applying
///      slope-changes at each SIX_DAYS bucket. Used by finalizeSeeding to
///      materialize a LockedPoint that correctly accounts for positions
///      whose subEnd lapsed inside the seeding window.
function _materializeFromAccumulator(
    int128 totalBias_,
    int128 totalSlope_,
    uint256 walkStart_,
    uint256 tsFinal_,
    bool isForfeitable_
) internal view returns (int128 bias, int128 slope) {
    uint256 ts = walkStart_;
    bias  = totalBias_  - totalSlope_ * uint256(ts).toInt256().toInt128();
    slope = totalSlope_;

    // Apply slope-change at walkStart (positions ending exactly at minSubEnd).
    int128 dSlope = isForfeitable_
        ? forfeitableSlopeChanges[ts]
        : lockedSlopeChanges[ts];
    slope += dSlope;
    if (slope < 0) slope = 0;

    uint256 t_i = ts;
    for (uint256 i; i < 255; ++i) {
        t_i += SIX_DAYS;
        if (t_i >= tsFinal_) {
            bias -= slope * (tsFinal_ - ts).toInt256().toInt128();
            if (bias < 0) bias = 0;
            return (bias, slope);
        }
        dSlope = isForfeitable_
            ? forfeitableSlopeChanges[t_i]
            : lockedSlopeChanges[t_i];
        bias -= slope * (t_i - ts).toInt256().toInt128();
        if (bias < 0) bias = 0;
        slope += dSlope;
        if (slope < 0) slope = 0;
        ts = t_i;
    }
}
```

### 7.5.1 `seedBatch` wiring details

The two new `seedBatch` snippets above splice into the existing function at specific points. For clarity, here is the complete patched function with both blocks in place (additions marked `← NEW`):

```solidity
function seedBatch(uint256 maxIterations) external {
    _requireSeedingActive();

    SeedingProgress storage progress = _seedingProgress;
    uint256 startId = progress.lastProcessedId + 1;
    if (startId >= seedingTargetId) return;
    uint256 remaining = seedingTargetId - startId;
    uint256 step = maxIterations < remaining ? maxIterations : remaining;
    uint256 endIdExclusive = startId + step;

    int128 batchSlope;
    int128 batchBias;
    int128 batchForfSlope;
    int128 batchForfBias;
    uint256 batchCount;
    uint64 batchMinSubEnd;                              // ← NEW

    for (uint256 id = startId; id < endIdExclusive; ++id) {
        if (_ownerOf(id) == address(0)) continue;
        uint256 _ta = transferableAfter[id];
        if (_ta == 0 || _ta <= block.timestamp) continue;
        LockedBalance memory _lock = locked[id];
        if (_lock.amount <= 0 || _lock.end <= block.timestamp) continue;

        int128 slope = _lock.amount / MAX_TIME.toInt256().toInt128();
        uint256 _subEnd = _lock.end < _ta ? _lock.end : _ta;
        int128 _subEndI = uint256(_subEnd).toInt256().toInt128();

        batchSlope += slope;
        batchBias  += slope * _subEndI;
        lockedSlopeChanges[_subEnd] -= slope;
        unchecked { ++batchCount; }

        if (forfeitable[id]) {
            batchForfSlope += slope;
            batchForfBias  += slope * _subEndI;
            forfeitableSlopeChanges[_subEnd] -= slope;
        }

        // ← NEW: track earliest subEnd across the included set
        uint64 _subEnd64 = uint64(_subEnd);
        if (batchMinSubEnd == 0 || _subEnd64 < batchMinSubEnd) {
            batchMinSubEnd = _subEnd64;
        }
    }

    progress.lastProcessedId = endIdExclusive - 1;
    progress.totalSlope += batchSlope;
    progress.totalBias  += batchBias;
    progress.totalForfeitableSlope += batchForfSlope;
    progress.totalForfeitableBias  += batchForfBias;
    progress.count += batchCount;

    // ← NEW: merge batch min into persistent min
    if (batchMinSubEnd != 0) {
        uint64 _existingMin = progress.minSubEnd;
        if (_existingMin == 0 || batchMinSubEnd < _existingMin) {
            progress.minSubEnd = batchMinSubEnd;
        }
    }
}
```

#### Multi-batch worked example

Suppose three batches process the seed range. The minimum-tracking flows like a parallel reduction — per-batch stack-local min, then compare-and-swap into the persistent min at flush:

```
Batch 1: ids 1-1000
  positions included: 5
  subEnds: [t+10d, t+15d, t+20d, t+30d, t+60d]
  batchMinSubEnd = t+10d
  → progress.minSubEnd was 0, now t+10d  (first write through sentinel branch)

Batch 2: ids 1001-2000
  positions included: 3
  subEnds: [t+5d, t+25d, t+40d]
  batchMinSubEnd = t+5d
  → progress.minSubEnd was t+10d, t+5d < t+10d, now t+5d  (compare-and-swap)

Batch 3: ids 2001-3000
  positions included: 2
  subEnds: [t+50d, t+100d]
  batchMinSubEnd = t+50d
  → progress.minSubEnd was t+5d, t+50d > t+5d, no change  (swap rejected)
```

After all batches: `progress.minSubEnd = t+5d` — the global minimum across the full seed range. `finalizeSeeding` reads this and runs the walk-back from `t+5d` to `tsFinal`.

#### Design rationale

**Stack-local tracking + single SSTORE at flush.** Mirrors the pattern already used by `batchSlope`, `batchBias`, etc. — seedBatch can iterate thousands of ids per call, so per-iteration SSTOREs are intolerable. Per-batch flush costs ~2.1K gas regardless of batch size.

**Sentinel `0` is unambiguous.** A live non-transferable position has `transferableAfter > 0` (set to `unlockTime > now` at mint, `src/VeHemi.sol:976`) and `lock.end > 0`. So `subEnd = min(lock.end, transferableAfter) > 0` for every included position. Reserving `0` to mean "not yet set" creates no collision with any valid `subEnd` value.

**Strict `<` not `<=` on comparisons.** The first valid `subEnd` flows through the `batchMinSubEnd == 0` branch; subsequent updates only fire on strict decrease. Equal `subEnds` (typically positions in the same SIX_DAYS bucket) don't trigger redundant writes.

**`uint64` cast on `_subEnd` is safe.** Token end timestamps are bounded by `block.timestamp + MAX_TIME` (currently ~year 2034). `uint64` covers ~584 billion years past the unix epoch. The contract already uses `uint64` for `LockedBalance.end`, `LockedPoint.timestamp`, and `seedingStartedAt` — the new field follows the same convention.

**Track over the INCLUDED set only, not the full id range.** Positions skipped by `seedBatch`'s filter predicates (burned, transferable, already-transferable, expired, empty) do not write to `lockedSlopeChanges`. Tracking their `subEnd` in `minSubEnd` would cause `finalizeSeeding` to walk from a timestamp where there are no stranded slope-changes to consume — wasted iterations on the happy path. The placement inside the loop, AFTER the four `continue` guards, ensures only included positions contribute.

#### Edge cases the code handles correctly

| Edge | Behavior |
|---|---|
| Empty batch (all ids filtered) | `batchMinSubEnd` stays 0 → flush's `if (batchMinSubEnd != 0)` skips → persistent min unchanged |
| `maxIterations = 0` | Loop doesn't execute → same as empty batch |
| No non-transferable positions exist anywhere | All batches empty → `progress.minSubEnd` stays 0 at finalize → `finalizeSeeding` takes the happy-path direct formula (no walk) |
| Single batch covers full range | `batchMinSubEnd` is the global min directly; flush writes it once |
| Many ids share the same `subEnd` bucket | Strict `<` skips redundant updates; one write per distinct earlier min |
| Forfeitable position has the smallest `subEnd` | Tracked correctly — `subEnd` is computed before the `forfeitable[id]` branch, so all included positions contribute regardless of forfeitable flag |
| seedBatch called permissionlessly by adversary | Cannot corrupt the min — `subEnd` is a deterministic read of immutable position state, monotonic merge ensures adversary cannot push the min higher |

#### Gas cost summary

| Path | Cost vs current code |
|---|---|
| Per-token iteration | +3 gas (one comparison; rare stack-local write) |
| Per-batch flush | +5K gas in the worst case (one SSTORE if batch min < persistent min); 0 if not |
| Per-finalize | 0 on happy path (walk doesn't run); up to ~5K × `(tsFinal - minSubEnd) / SIX_DAYS` if walk runs |

Cost is paid only when phantom carry would otherwise have fired — i.e., exactly when the operator wants the protection.

#### What this does NOT enable

`progress.minSubEnd` is a **finalize-time backstop**, not an upfront gate. It cannot be used at `markSeedingStarted` to refuse opening the window — by definition, no positions have been processed yet at mark time, so `progress.minSubEnd == 0`. The check that prevents opening the window with imminent `subEnd`s remains off-chain (the multicall pre-flight in the runbook). The on-chain mechanism heals operator error after the fact; it does not prevent operator error.

### 7.6 Test plan

Add to `test/SeedingFlow.t.sol`:

1. **Happy path regression** — no position has `subEnd` inside the window; assert post-finalize LockedPoint matches the current (pre-patch) value. Confirms no regression for well-run seedings.

2. **Single-position carry** — one position with `subEnd` 1 hour inside the window; assert post-finalize `nonTransferableTotalVeHemiSupply()` equals the true value (only the other positions contribute).

3. **Multiple positions, staggered subEnds inside window** — three positions with subEnds at 1h, 2h, 3h inside the window; assert post-finalize value equals sum of remaining positions' biases.

4. **Edge: `subEnd == tsFinal` exactly** — assert the position is correctly excluded from the subcurve (contribution = 0).

5. **Edge: all seeded positions have `subEnd` inside the window** — assert post-finalize subcurves are zero (no positions remain).

6. **Edge: very old `subEnd`** — position has `subEnd` long before window opens (filtered by `seedBatch`'s skip); assert `minSubEnd` is set by the next-earliest position, not the skipped one.

7. **Differential test against post-walk supply query** — finalize, then query `nonTransferableTotalVeHemiSupplyAt(tsFinal)`; assert it equals the directly-materialized LockedPoint bias. Confirms the walk and the query are self-consistent.

---

## Part 8 — Alternatives considered and rejected

| Option | Why rejected |
|---|---|
| Block `withdraw`/`transferFrom` of non-transferable positions during window | Doesn't fix the math — Path B (time crossing `subEnd` without user action) still triggers carry. |
| Reject `markSeedingStarted` if any position's `subEnd` is too close | Requires iterating all positions at start — hits the gas wall the multi-block fix was designed to avoid. |
| Skip positions with imminent `subEnd` in `seedBatch` | Requires operator-supplied window-budget parameter; operator must judge correctly; doesn't degrade gracefully if budget is wrong. |
| Re-scan in `finalizeSeeding` to exclude lapsed positions | Doubles the gas cost of the entire flow. |
| Off-chain runbook only (current state) | Works but depends entirely on operator discipline; no on-chain enforcement. |

The walk-back fix is the only option that:
- Imposes zero overhead on the happy path.
- Caps worst-case cost at ~5K gas × walk length.
- Requires no operator parameter.
- Self-heals incorrect operator judgment within the contract.

---

## Part 9 — Operational note

Even with the fix, **operators should still run the off-chain pre-flight check**: enumerate all non-transferable positions, compute `min(subEnd) - now`, assert it's greater than the expected window duration + safety margin. The fix is defense-in-depth, not a license to be sloppy. The longer the walk back has to run, the more gas finalize costs.

The runbook check in `deploy/04_upgrade_vehemi_v2.ts` should be augmented with this enumeration before queueing the Safe MultiSend.

---

## Appendix A — Why `minSubEnd` and not `maxSubEnd`?

The walk needs to start at the **earliest** stranded slope-change to consume all of them. Walking from `maxSubEnd` would miss everything earlier; walking from `minSubEnd` covers the full range. The walk naturally terminates at `tsFinal`, so there's no concern about over-walking past positions still in-window.

## Appendix B — Why `int128` is safe for the accumulator

The seeded `totalBias = Σ slope_i * subEnd_i`. With realistic Hemi mainnet numbers:

```
max slope_i ≈ 1M HEMI / 4y in seconds = 1e24 / 1.26e8 ≈ 7.94e15
max subEnd  ≈ 2e9 (year 2033 timestamp)
max bias_i  ≈ 7.94e15 * 2e9 ≈ 1.6e25

Σ across 30K positions ≈ 5e29

int128 max  ≈ 1.7e38

Headroom: ~8 orders of magnitude. Safe.
```

## Appendix C — Why the bug exists in the first place

`seedBatch`'s decision to write `lockedSlopeChanges[subEnd] -= slope` eagerly (during the batch, not at finalize) is what creates the stranded entry. The alternative — write all slope changes inside `finalizeSeeding` from the accumulator — would require either:

- Storing every `(subEnd, slope)` pair in the accumulator (unbounded storage), or
- Re-iterating every position at finalize (defeats the multi-block split).

Eager writes are the right tradeoff; the fix is to consume the eager writes correctly, not to remove them.

---

## Summary

- **What's wrong:** `seedBatch` writes `lockedSlopeChanges[subEnd] -= slope`. If `subEnd < tsFinal`, the entry is stranded — the post-finalize walk never visits past buckets.
- **Effect:** Locked/forfeitable subcurve under-counts; transferable share over-counts; bias clamps to zero far earlier than reality.
- **Severity now:** Low — no on-chain consumer reads these views in this repo.
- **Severity later:** Medium-High if rewards or governance modules wire to these views.
- **Fix:** Track `minSubEnd` in the accumulator; in `finalizeSeeding`, walk from `minSubEnd` to `tsFinal` consuming stranded slope-changes before writing the LockedPoint.
- **Gas cost:** Zero for the happy path; bounded at ~2.5M gas worst case.
- **Storage change:** One `uint64` field added to `SeedingProgress`. Safe — V2 not deployed.
