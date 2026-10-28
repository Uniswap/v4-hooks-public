# VolatilePairHook

Technical specification for a dynamic fee hook for volatile pairs (for example ETH/USDC) on Uniswap v4 mainnet.

## Table of Contents

- [Overview](#overview)
- [Architecture](#architecture)
- [Configuration](#configuration)
  - [VolatileFeeConfig](#volatilefeeconfig-per-pool)
  - [VolatileFeeState](#volatilefeestate-per-pool-updated-once-per-block)
  - [Validation Rules](#validation-rules)
  - [Access Control](#access-control)
- [Measuring Price Moves](#measuring-price-moves)
- [Top of Block Fees](#top-of-block-fees)
  - [Permanent Fee](#permanent-fee)
  - [Temporary Fee](#temporary-fee)
  - [Starting Fee for the Block](#starting-fee-for-the-block)
- [Mid Block Fees](#mid-block-fees)
- [beforeSwap and getFee](#beforeswap-and-getfee)
- [Worked Example](#worked-example)
- [Rounding](#rounding)
- [Invariants](#invariants)
- [Known and Accepted Behaviors](#known-and-accepted-behaviors)

---

## Overview

`VolatilePairHook` sets a separate LP fee for each swap direction on every swap, through `beforeSwap`. A swap that buys token0 (price goes up, `zeroForOne = false`) pays the **ask** fee. A swap that sells token0 (price goes down, `zeroForOne = true`) pays the **bid** fee.

The fee has three parts:

```
fee = permanent fee (its side) + temporary fee (backrun side only) + mid block extra
```

- **Permanent fee:** ask and bid always add up to the resting spread. After a price move, the side the price moved toward gets more expensive and the other side gets cheaper by the same amount. This lean carries over to later blocks.
- **Temporary fee:** for one block after a move, the side that trades against the move (the "backrun" side) pays extra. It has two pieces, restore and capture, explained below. It only applies when the block comes soon enough after the previous block open (`maxTempFeeBlockGap`, 1 block on Ethereum).
- **Mid block extra:** within a block, swaps after the first pay more the further the price has moved since the block opened.

### Design Goals

1. **A constant quoted spread in calm blocks.** When the price does not move between blocks, ask + bid equals the resting spread.
2. **Lower LVR.** Leaning the fees in the direction of the last price move makes the side that informed flow trades on more expensive, without changing the total spread.
3. **A share of backrun profit for LPs.** When a large uninformed trade moves the price, backrunning it is still possible, but part of the profit goes to LPs through the temporary fee and the mid block extra.
4. **Less sandwiching.** The mid block extra cuts the profit of the back leg of a sandwich.

---

## Architecture

`PoolManager` calls `beforeSwap` on every swap. On the first swap of a new block, the hook compares the current pool price with the price saved at the previous block's first swap, updates the permanent and temporary fees, and saves the new state. Every swap, including the first, then pays the block's starting fee for its side plus a mid block extra based on how far the price has moved since the block opened.

`VolatilePairHook` is a UUPS implementation deployed behind an ERC1967 proxy. The proxy, whose mined address encodes the hook permission flags, is the registered v4 hook. All state lives in the proxy's storage under the ERC-7201 namespace `uniswap.storage.VolatileFeeConfiguration`.

One setting is not per pool: `maxTempFeeBlockGap` is an immutable passed to the implementation's constructor (at least 1). It is measured in blocks, so it is chosen per chain, and changing it means deploying a new implementation and upgrading. Ethereum uses 1.

The fee math lives in the `VolatileFeeCalculation` library. `RelativeMoveLibrary` holds the `RelativeMove` type used for price moves. `VolatileFeeConfiguration` holds config, state, validation and the config manager functions. `VolatilePairHook` loads state, calls the library and stores the result.

---

## Configuration

Each pool has two structs: **VolatileFeeConfig** (parameters, set at pool creation and updatable by the config manager) and **VolatileFeeState** (updated on the first swap of each block). Both fit in one storage slot each. All fee values are in pips: `1e6` is 100% and `100` is 1 bp.

### VolatileFeeConfig (per pool)

| Field                      | Type     | Description                                                                                                                                                                        |
| -------------------------- | -------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `restingSpreadE6`          | `uint24` | Ask permanent fee + bid permanent fee. The quoted spread in a calm block. `0` marks an unconfigured pool.                                                                          |
| `backrunCaptureFractionE6` | `uint24` | Share of a price move charged to the backrun side: used by the capture piece of the temporary fee and by the mid block backrun extra. Described as the LP share of backrun profit. |
| `midFadeRateE6`            | `uint24` | Growth rate of the mid block extra for swaps that continue in the direction of the in block move.                                                                                  |
| `maxMidFadeE6`             | `uint24` | Cap on that continuing mid block extra.                                                                                                                                            |
| `skewRateE6`               | `uint24` | Permanent fee step per unit of price impact.                                                                                                                                       |
| `maxSkewStepE6`            | `uint24` | Cap on the permanent fee step per block.                                                                                                                                           |
| `maxSkewE6`                | `uint24` | Cap on either side's permanent fee.                                                                                                                                                |
| `backrunThresholdE6`       | `uint24` | Minimum price impact for the capture piece of the temporary fee.                                                                                                                   |
| `restoreFractionE6`        | `uint24` | Share of the backrun side's permanent fee drop that the restore piece adds back.                                                                                                   |
| `restoreThresholdE6`       | `uint24` | Minimum price impact for the restore piece of the temporary fee.                                                                                                                   |

### VolatileFeeState (per pool, updated once per block)

| Field             | Type      | Description                                                                                                                                                                                                          |
| ----------------- | --------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `blockNumber`     | `uint40`  | Block of the last update. `0` after pool creation or a config update, so the next swap always counts as a new block.                                                                                                 |
| `sqrtPriceTopX96` | `uint160` | Pool sqrt price at the first swap of the last updated block (the block open). Used as the reference for the next block's price impact and for the in block displacement. `0` after pool creation or a config update. |
| `askPermFeeE6`    | `uint24`  | Ask permanent fee. The bid permanent fee is `restingSpreadE6 - askPermFeeE6` and is not stored.                                                                                                                      |
| `tempFeeE6`       | `uint24`  | Temporary fee (restore + capture) for the block.                                                                                                                                                                     |
| `tempOnBid`       | `bool`    | `true` if the temporary fee is on the bid side, `false` if on the ask side.                                                                                                                                          |

Starting fees for each side are not stored. They are derived from the permanent fees and the temporary fee (see [Starting Fee for the Block](#starting-fee-for-the-block)).

### Validation Rules

Every config write (`initializePool`, `updateFeeConfig`, `batchUpdateFeeConfig`) checks:

- **`restingSpreadE6`**: nonzero, and at most `2 * MAX_FEE_E6`.
- **`backrunCaptureFractionE6`**: at most `1e6`.
- **`maxSkewE6`**: at most `restingSpreadE6`, at least `restingSpreadE6 / 2` (so `2 * maxSkewE6 >= restingSpreadE6`), and at most `MAX_FEE_E6`.
- **`maxSkewStepE6`**: at most `2 * maxSkewE6 - restingSpreadE6`, the width of the band the permanent fees can move in.
- **`maxMidFadeE6`**: at most `MAX_FEE_E6`.
- **`restoreFractionE6`**: at most `1e6`.
- **`backrunThresholdE6`** and **`restoreThresholdE6`**: below `1e6`, since a down move can never reach `1e6`.

`skewRateE6` and `midFadeRateE6` are not bounded. They are limited in effect by `maxSkewStepE6` and `maxMidFadeE6`, and every fee is clamped at `MAX_FEE_E6`.

Every config write also resets the pool's fee state: `blockNumber = 0`, `sqrtPriceTopX96 = 0`, `askPermFeeE6 = restingSpreadE6 / 2`, `tempFeeE6 = 0`, `tempOnBid = false`. The division rounds down and the bid permanent fee is the rest of the spread, so with an odd `restingSpreadE6` the bid starts 1 pip above the ask.

### Access Control

Roles use OpenZeppelin `AccessControl` and are granted when the proxy is initialized (`initialize(admin, poolInitializer, configManager)`):

| Role                    | Permissions                                                                                                                                             |
| ----------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `DEFAULT_ADMIN_ROLE`    | Grants and revokes all roles. Authorizes implementation upgrades.                                                                                       |
| `POOL_INITIALIZER_ROLE` | Calls `initializePool()` to create pools.                                                                                                               |
| `CONFIG_MANAGER_ROLE`   | Calls `updateFeeConfig()` and `batchUpdateFeeConfig()` for pools that already exist. Every update validates the config and resets the pool's fee state. |

`_beforeInitialize` reverts for any caller other than the hook. v4 skips hook callbacks when the hook itself calls `PoolManager.initialize()`, so the only way to create a pool is `initializePool()`, which checks the dynamic fee flag and `hooks == this`, writes the config and initializes the pool in one call. No pool can exist without a config, and no config can exist without a pool.

Upgrades check that the new implementation uses the same PoolManager and the same hook permission flags as the proxy address.

---

## Measuring Price Moves

Two price moves drive the fees:

- **Price impact (PI):** the move between block opens, from the previous block's saved open price to the current price at this block's first swap. Drives the top of block fees.
- **Displacement:** the move within the block, from this block's open price to the price before the current swap. Drives the mid block extra.

Both are measured against the old price, in price space (sqrt price squared):

```
move = |P_new - P_ref| / P_ref
```

`relativeMove` returns the move as a `RelativeMove`: an exact fraction (numerator, denominator) plus a direction flag, packed in one word. The move itself is never rounded. It is only scaled once, when multiplied by an E6 rate (`mulUp`), or compared exactly with an E6 threshold (`gte`).

Internally, `relativeMove` takes the ratio of the smaller to the larger sqrt price scaled by `2^48` (rounded down) and squares it to get the price ratio scaled by `2^96`. Rounding down here can only make the move look slightly larger. For an extreme up move the ratio can round to 0; it is clamped to 1 so the result is a very large move that every fee clamps, rather than a division by zero.

An up move has no upper limit (the price doubling is a 100% move). A down move is always below 100%.

---

## Top of Block Fees

On the first swap of a new block, if a previous open price exists, the hook computes PI and calls `newPermAndTempFee`. The side the price moved toward is the **leaning** side; the other side is the **backrun** side:

- Price went up: the ask leans, and the temporary fee goes on the bid (`tempOnBid = true`).
- Price went down: the bid leans, and the temporary fee goes on the ask.

### Permanent Fee

```
step         = min(skewRateE6 * PI, maxSkewStepE6)
newLeanPerm  = min(oldLeanPerm + step, maxSkewE6)
backrun perm = restingSpreadE6 - newLeanPerm
```

The leaning side goes up by the step and the backrun side goes down by the same amount, so the two always add up to the resting spread. Both stay within `[restingSpreadE6 - maxSkewE6, maxSkewE6]`.

### Temporary Fee

The temporary fee goes on the backrun side for this block. It has two independent pieces, each with its own threshold:

```
restore = restoreFractionE6 * (newLeanPerm - oldLeanPerm)   if PI >= restoreThresholdE6, else 0
capture = backrunCaptureFractionE6 * PI                      if PI >= backrunThresholdE6, else 0
tempFee = restore + capture   (clamped to MAX_FEE_E6)
```

- **Restore** adds back what the backrun side's permanent fee just dropped, so the backrun side does not get cheaper right after a move. With `restoreFractionE6 = 1e6` and `restoreThresholdE6 = 0` it adds back the whole drop on every move.
- **Capture** charges the backrun side a share of the move, but only after a large move.

The thresholds are independent and either can be higher. For example, both at 10 bp means small moves get no temporary fee and large moves get both pieces.

The whole temporary fee (restore and capture) is 0 when the previous block open is more than `maxTempFeeBlockGap` blocks back:

```
if currentBlock - previous block open > maxTempFeeBlockGap:  tempFee = 0
```

The permanent fee still steps as usual, so the backrun side pays its lowered permanent fee. A move that nobody traded against within the gap is treated like an ordinary block-to-block move. With `maxTempFeeBlockGap = 1`, only the block right after the previous block open pays the temporary fee, and one block with no swap in between is enough to drop it.

The temporary fee is saved in state and applies to every swap on the backrun side for the rest of the block. It is replaced on the first swap of the next block that has a swap.

### Starting Fee for the Block

`baselineFee` derives each side's starting fee from the saved state:

```
leaning side:  permanent fee
backrun side:  permanent fee + tempFee   (clamped to MAX_FEE_E6)
```

When the price did not move since the last block, the temporary fee is 0 and ask + bid equals the resting spread.

---

## Mid Block Fees

Every swap measures its displacement from the block open price and adds an extra on top of its side's starting fee (`_getFee`):

- **Against the displacement** (a backrun, for example selling after the price went up in this block):

```
fee = startingFee + backrunCaptureFractionE6 * displacement
```

- **With the displacement** (continuing in the same direction):

```
fee = startingFee + min(midFadeRateE6 * displacement, maxMidFadeE6)
```

Both are clamped to `MAX_FEE_E6`. The mid block extra has no threshold.

On the first swap of a block the displacement is 0, so it pays exactly the starting fee. A swap later in the block is never charged less than the first swap of the block on the same side.

Because the extra is fixed at the start of each swap, splitting a backrun into many small swaps pays on the remaining displacement each time. In the limit LPs receive about `backrunCaptureFractionE6` of the backrunner's profit.

---

## beforeSwap and getFee

`beforeSwap`:

1. Load config and state, and read the current sqrt price from `slot0`.
2. If the current block is greater than the saved `blockNumber`, it is a new block:
   - If `sqrtPriceTopX96` is nonzero, compute PI and update the permanent and temporary fees. If the saved `blockNumber` is more than `maxTempFeeBlockGap` blocks back, set the temporary fee to 0.
   - Set `sqrtPriceTopX96` to the current price and `blockNumber` to the current block, and save the state.
3. Compute the fee for the swap's direction (starting fee + mid block extra).
4. Return the fee with `LPFeeLibrary.OVERRIDE_FEE_FLAG`.

`getFee(key)` runs steps 1 to 3 in memory without saving, for both directions. It returns exactly what the next swap in each direction would pay, given the current state. The fee never depends on swap size.

The block number comes from `BlockNumberish`. A block number that is not greater than the saved one is treated as the same block, so no subtraction on block numbers can underflow.

---

## Worked Example

Config: `restingSpreadE6 = 900` (9 bp), `skewRateE6 = 100_000` (10%), `maxSkewStepE6 = 300`, `maxSkewE6 = 900`, `backrunCaptureFractionE6 = 500_000` (50%), `backrunThresholdE6 = 1000` (10 bp), `midFadeRateE6 = 50_000` (5%), `maxMidFadeE6 = 200`, `restoreFractionE6 = 1e6`, `restoreThresholdE6 = 0`, `maxTempFeeBlockGap = 1`. Start: ask 450, bid 450. Blocks A, B and C come right after each other. Numbers are approximate (rounding ignored).

**Block A, price up 5 bp (PI = 500):**

- Step: 10% of 500 = 50. Ask perm 500, bid perm 400.
- Restore: 100% of 50 = 50. Capture: 500 < 1000, so 0. Temporary fee on bid = 50.
- Starting fees: ask 500, bid 450. Quoted spread 950 (9.5 bp).

**Block B, price up 20 bp (PI = 2000):**

- Step: 10% of 2000 = 200. Ask perm 700, bid perm 200.
- Restore: 200. Capture: 50% of 2000 = 1000. Temporary fee on bid = 1200.
- Starting fees: ask 700, bid 1400. Quoted spread 2100 (21 bp).
- If block B had come one block later, with no swap in the block between A and B, the temporary fee would be 0: starting fees ask 700, bid 200.

**Within block B, a buy then moves the price up 1% from the block open (displacement 10,000):**

- A sell (backrun) now pays 1400 + 50% of 10,000 = 6400.
- A buy (continuing) pays 700 + min(5% of 10,000, 200) = 900.

**Block C, the price is back where block B opened (for example a backrun returned it):**

- Step 0, temporary fee 0. Starting fees: ask 700, bid 200. Quoted spread 900.

---

## Rounding

- Every fee term (restore, capture, mid block extras) rounds up on its own, in favour of LPs, so a fee can be a few pips above the exact value.
- The `2^48` sqrt ratio in `relativeMove` rounds down, which can only make the move look larger.
- Threshold checks (`gte`) are exact.
- The permanent fee step rounds up, so any nonzero move steps the permanent fee by at least 1 pip. Why this is accepted is in item 17 of the [accepted behaviors](./VolatilePairHook-accepted-behaviors.md).

---

## Invariants

The following hold for any config that passes validation, any sqrt price in `[MIN_SQRT_PRICE, MAX_SQRT_PRICE]`, and any sequence of blocks and swaps:

| #   | Invariant           | Description                                                                                                                              |
| --- | ------------------- | ---------------------------------------------------------------------------------------------------------------------------------------- |
| 1   | `fee <= MAX_FEE_E6` | Every returned fee is at most 999,998, so v4 never rejects the override fee and exact output swaps stay available with any protocol fee. |
| 2   | No revert           | `beforeSwap` and `getFee` never revert for a configured pool.                                                                            |
| 3   | Permanent fee band  | `restingSpreadE6 - maxSkewE6 <= askPermFeeE6 <= maxSkewE6`, and the same for the bid.                                                    |
| 4   | Fixed total         | Ask permanent fee + bid permanent fee = `restingSpreadE6`.                                                                               |
| 5   | Calm block          | With no move since the last block open, both starting fees equal the permanent fees.                                                     |
| 6   | Fee floor           | A swap never pays less than its side's starting fee, and the starting fee is never below the permanent fee.                              |
| 7   | Temporary fee side  | The temporary fee is only ever charged on the backrun side.                                                                              |
| 8   | Monotone            | A larger price impact or displacement never lowers a fee.                                                                                |
| 9   | Restore gate        | With PI below `restoreThresholdE6`, the restore piece is 0.                                                                              |
| 10  | Full restore        | `restoreFractionE6 = 1e6` with `restoreThresholdE6 = 0` adds back exactly the backrun side's permanent fee drop on every move.           |
| 11  | Quote matches swap  | `getFee` equals the fee `beforeSwap` charges for the same state, block and direction.                                                    |
| 12  | Temporary fee gap   | The temporary fee is 0 in any block more than `maxTempFeeBlockGap` blocks after the previous block open.                                  |

---

## Known and Accepted Behaviors

Behaviors that were considered and accepted, with the reasoning for each, are listed in [VolatilePairHook-accepted-behaviors.md](./VolatilePairHook-accepted-behaviors.md).
