# StableStableHook

Dynamic fee hook for stable/stable pools on Uniswap v4.

## Table of Contents

- [Overview](#overview)
- [Architecture](#architecture)
- [Configuration](#configuration)
- [The Optimal Range](#the-optimal-range)
  - [Close Boundary Fee](#close-boundary-fee)
  - [Far Boundary Fee](#far-boundary-fee)
- [beforeSwap Algorithm](#beforeswap-algorithm)
- [Inside Optimal Range Fee](#inside-optimal-range-fee)
- [Outside Optimal Range Fee](#outside-optimal-range-fee)
- [Decay Mechanism](#decay-mechanism)
- [Invariants](#invariants)

---

## Overview

The `StableStableHook` implements a dynamic fee mechanism for Uniswap v4 pools containing two stable assets (e.g., USDC/USDT). The hook overrides the LP fee on every swap via `beforeSwap`, adjusting the fee based on how far the current AMM price has drifted from a configured reference price.

### Goals

- **Consistent effective prices**: inside a tight band around the reference price, all buys execute at one price and all sells at another, regardless of the AMM spot price.
- **Incentivize mean-reversion**: outside that band, fees decay over time to attract arbitrageurs who push the price back toward the reference.
- **Zero-fee for adverse movement**: swaps that push the price further from the reference are not penalized (fee = 0), since those swaps provide volume without extracting value.

---

## Architecture

![Architecture](diagrams/architecture.svg)

PoolManager calls `beforeSwap` on every swap; the hook computes and returns a dynamic fee based on how far the AMM price has drifted from the reference price.

---

## Configuration

Each pool has two data structures. **FeeConfig** is set by the owner at pool creation (and optionally updated by a config manager) — it defines the pool's economic parameters: how wide the optimal range is, where the reference price sits, and how fast fees decay. **FeeState** is written by the hook on every swap — it tracks the latest fee, price, and block number so the next swap can compute how much time has passed and how the price moved.

### FeeConfig (per pool)

| Field                   | Type      | Description                                                                                                         |
| ----------------------- | --------- | ------------------------------------------------------------------------------------------------------------------- |
| `k`                     | `uint24`  | Decay factor per block in Q24 format. E.g., `16,609,443` represents 0.99 — fee retains 99% of its value each block. |
| `logK`                  | `uint24`  | Precomputed `-ln(k) >> 40`. Used for efficient exponential computation when `blocksPassed > 4`.                     |
| `optimalFeeE6`          | `uint24`  | Fee rate defining optimal range width in **price space**, 1e6 precision. E.g., `90` = 0.009%. Max: `10,000` (1%).   |
| `referenceSqrtPriceX96` | `uint160` | Reference center price in sqrt Q96 format. The "true" exchange rate of the stable pair.                             |

### FeeState (per pool, updated every swap)

| Field                     | Type      | Description                                                                                              |
| ------------------------- | --------- | -------------------------------------------------------------------------------------------------------- |
| `previousDecayingFeeE12`  | `uint40`  | Last decaying fee in 1e12 precision, or `UNDEFINED_DECAYING_FEE_E12` if previously inside optimal range. |
| `previousSqrtAmmPriceX96` | `uint160` | AMM sqrt price at last swap. Used to detect price movement direction.                                    |
| `blockNumber`             | `uint40`  | Block when fee was last updated. Determines time-based decay.                                            |

### Validation Rules

**k and logK**: Both must be nonzero. `logK` must exactly equal `uint256(-lnWad(k_as_wad)) >> 40`. This prevents:

- `k = 0`: instant decay (division by zero risk)
- `logK = 0`: no decay at all (fee never changes)

**optimalFeeE6**: Must be `<= MAX_OPTIMAL_FEE_E6` (10,000 = 1%).

**referenceSqrtPriceX96**: Must be bounded such that the optimal range stays within v4's valid sqrt price range `[MIN_SQRT_PRICE, MAX_SQRT_PRICE)`. The bounds are derived from:

- Lower: `referenceSqrtPrice * sqrt(1 - maxOptimalFee) >= MIN_SQRT_PRICE`
- Upper: `referenceSqrtPrice / sqrt(1 - maxOptimalFee) < MAX_SQRT_PRICE`

Note: the optimal range is defined in **price** space, so the sqrt price bounds use `sqrt(1 - fee)`, not `(1 - fee)`.

### Access Control

| Role            | Permissions                                                                                                         |
| --------------- | ------------------------------------------------------------------------------------------------------------------- |
| `owner`         | Can call `initializePool()` to create new pools                                                                     |
| `configManager` | Can call `updateFeeConfig()` and `setConfigManager()`. Setting to `address(0)` permanently disables config updates. |

The `_beforeInitialize` hook reverts unless the caller is the hook itself. Since a hook cannot call itself externally, this ensures pools can only be created through `initializePool()`, which calls `PoolManager.initialize()` internally — guaranteeing the fee config is set atomically with pool creation.

---

## The Optimal Range

### Definition

The optimal range is a price band around the reference price, defined in **price space** (not sqrt price space):

```
Lower bound = RP * (1 - optimalFee)
Upper bound = RP / (1 - optimalFee)
```

where `RP` is the reference price (i.e., `referenceSqrtPriceX96²` expressed as a price).

The asymmetry is intentional: multiplying by `(1 - f)` on the lower side and dividing by `(1 - f)` on the upper side ensures that a buy-then-sell roundtrip at the boundaries costs the same percentage in both directions.

### Price Ratio

To unify the math for "price above RP" and "price below RP", the system computes a **normalized price ratio** that is always `<= 1`:

```
priceRatio = min(ammPrice, RP) / max(ammPrice, RP)
```

---

### Close Boundary Fee

The close boundary fee measures **how far the AMM price is from the nearer edge of the optimal range**. Its sign is the primary branching condition in `beforeSwap` — it determines whether the price is inside or outside the range.

The fee `f` is derived by setting the effective price (after fee) equal to the close boundary. Whether `ammPrice < RP` or `ammPrice > RP`, the normalized `priceRatio` collapses both cases into one formula:

```
closeBoundaryFeeE12 = 1 - priceRatio / (1 - optimalFee)
```

**Sign convention:**

- `closeBoundaryFeeE12 <= 0`: AMM price is **inside** the optimal range
- `closeBoundaryFeeE12 > 0`: AMM price is **outside** the optimal range

---

### Far Boundary Fee

The far boundary fee measures **how far the AMM price is from the farther edge of the optimal range**. It is only used when the price is outside the optimal range, where it serves as the upper bound for the decaying fee and contributes to the target fee calculation.

Same approach as above — set the effective price equal to the far boundary. Both cases unify to:

```
farBoundaryFeeE12 = 1 - (1 - optimalFee) * priceRatio
```

**Key property**: `farBoundaryFee >= closeBoundaryFee` when outside the optimal range.

---

### Price-Fee Relationship

## beforeSwap Algorithm

![beforeSwap Flow](diagrams/before-swap-flow.svg)

The `beforeSwap` hook is the entry point for all fee logic. It reads the current AMM price, computes the price ratio relative to the reference, and branches based on whether the price is inside or outside the optimal range. The following sections detail each branch.

---

## Inside Optimal Range Fee

When the AMM price is inside the optimal range, the hook enforces **consistent effective prices** for all swappers:

- **All sells** execute at effective price = `RP * (1 - optimalFee)` (lower bound)
- **All buys** execute at effective price = `RP / (1 - optimalFee)` (upper bound)

The fee varies depending on where within the range the AMM price sits and which direction the swap goes. The branching condition is `ammPriceBelowRP == userSellsZeroForOne`:

**Swap toward closer boundary** (`ammPriceBelowRP == userSellsZeroForOne`):

```
fee = 1 - (1 - optimalFee) / priceRatio
```

**Swap toward farther boundary** (`ammPriceBelowRP != userSellsZeroForOne`):

```
fee = 1 - (1 - optimalFee) * priceRatio
```

Note the formulas mirror `closeBoundaryFee` and `farBoundaryFee` — same derivation approach (set effective price equal to the target boundary, solve for fee). At the reference price (`priceRatio = 1`), both produce exactly `optimalFee`. As the price drifts toward a boundary, fee for swaps pushing toward it decreases (approaching 0) while fee for swaps pushing away increases (approaching ~2 \* optimalFee).

---

## Outside Optimal Range Fee

When the AMM price is outside the optimal range (`closeBoundaryFeeE12 > 0`), the fee system switches to a different regime.

### Direction-Based Zero Fee

If the swap pushes the price **further from the reference price**, the fee is **0**:

```solidity
lpFeeE12 = (ammPriceBelowRP == userSellsZeroForOne) ? 0 : decayingFeeE12;
```

The condition `ammPriceBelowRP == userSellsZeroForOne` is true when:

- Price is below RP and user sells token0 (pushing price further down), OR
- Price is above RP and user buys token0 (pushing price further up)

**Rationale**: the pool is already mispriced. Penalizing swaps that worsen the mispricing would reduce volume without helping LPs. The fee is only charged on swaps pushing price **back toward** reference, because those swappers benefit from buying a temporarily cheap asset.

### Target Fee

When outside the optimal range, a **target fee** is computed as the decay destination:

```
targetFee = farBoundaryFee - closeBoundaryFee / 2
```

**Tuning property**: the further the price drifts outside the range (larger `closeBoundaryFee`), the more the target drops below `farBoundaryFee`. This creates stronger incentive for mean-reversion — the longer the price stays outside the range, the cheaper it becomes for arbitrageurs to push it back.

**Key properties**: `targetFee > 0` and `targetFee <= farBoundaryFee` when outside the optimal range. The gap between `targetFee` and `farBoundaryFee` is always exactly `closeBoundaryFee / 2`.

### Decaying Fee

The fee charged to swappers pushing price toward RP is a **decaying fee** that starts high and exponentially converges toward the target fee over time (measured in blocks). The fee resets to `farBoundaryFee` when price first leaves the optimal range, decays between swaps, and is adjusted based on price movement — see [Decay Mechanism](#decay-mechanism) for the full algorithm.

---

## Decay Mechanism

The decay mechanism is the most complex part of the fee system. It operates in two phases:

1. **Adjust** the previous fee based on how the price moved since the last swap
2. **Decay** the adjusted fee exponentially toward the target fee

### Phase 1: Fee Adjustment (State Machine)

![Decay State Machine](diagrams/decay-state-machine.svg)

The previous swap state determines which of four adjustment paths is taken before exponential decay is applied.

#### Case 1: Reset

**Condition**: `previousDecayingFeeE12 == UNDEFINED` (was inside optimal range) or price jumped across the reference price (was above RP, now below, or vice versa).

**Action**: `decayStartFee = farBoundaryFee`

**Rationale**: there is no meaningful previous fee to adjust from. Starting from the far boundary is conservative — the maximum fee that makes economic sense.

#### Case 2: Adjust Upward

**Condition**: price moved **further** from reference (still on the same side of RP, but more extreme).

**Action**: adjust the previous fee to preserve the same effective price at the new (worse) AMM price.

**Derivation**:

Let `EP` = effective price from the previous swap, computed as `ammPrice_prev / (1 - previousFee)` (or the sell equivalent). As price moves further from RP, the AMM price worsens. To maintain the same effective price:

```
ammPrice_new / (1 - decayStartFee) = ammPrice_prev / (1 - previousFee)
```

Let `priceMovementRatio = ammPrice_new / ammPrice_prev` (normalized, always <= 1 since `calculatePriceRatioX96` takes min/max):

```
decayStartFee = 1 - priceMovementRatio * (1 - previousFee)
```

This always increases the fee: `decayStartFee >= previousFee`.

#### Case 3: Cap at Far Boundary

**Condition**: price moved **toward** reference, but the previous fee exceeds the new `farBoundaryFee`.

**Action**: `decayStartFee = farBoundaryFee`

**Rationale**: as the price improves (moves toward RP), `farBoundaryFee` decreases. The fee should never exceed what the far boundary would produce.

#### Case 4: Pass-Through

**Condition**: price moved toward reference, and `previousFee <= farBoundaryFee`.

**Action**: `decayStartFee = previousFee` (no adjustment needed).

**Rationale**: the previous fee is still within valid bounds; let exponential decay handle the reduction.

### Phase 2: Exponential Decay

After adjustment, the fee decays exponentially toward the target:

```
decayingFee = targetFee + k^blocksPassed * (decayStartFee - targetFee)
```

where:

- `k` < 1 (e.g., 0.99) — the per-block retention factor
- `k^blocksPassed` -> 0 as blocks increase, so `decayingFee` -> `targetFee`

`k^blocksPassed` is computed via direct multiplication (`fastPow`) for 1-4 blocks, or `exp(-logK * n)` using Solady's `expWad` for 5+ blocks. Both paths are equivalent: `k^n = exp(-n * (-ln(k)))`.

---

## Invariants

| Invariant                                                         | Guarantee                                                                                                                                                      |
| ----------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `lpFeeE12 <= ONE_E12`                                             | Fee never exceeds 100% for any input                                                                                                                           |
| `targetFee <= decayingFee <= decayStartFee`                       | Decay is bounded between target and starting fee                                                                                                               |
| Consistent effective prices                                       | Inside the optimal range, effective buy price = `RP / (1 - optimalFee)` and effective sell price = `RP * (1 - optimalFee)` for all AMM prices within the range |
| No revert                                                         | `beforeSwap` never reverts for any valid price, direction, and block gap                                                                                       |
| `previousFee == targetFee -> decayingFee == targetFee`            | No gap = no decay, regardless of k or blocks                                                                                                                   |
| `decayStartFee >= previousFee` (when price moves further from RP) | Price worsening can only increase the fee                                                                                                                      |

---
