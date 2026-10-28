# VolatilePairHook: Known and Accepted Behaviors

Behaviors of the VolatilePairHook that were considered and chosen on purpose. Read alongside the algorithm description. File references point to functions rather than line numbers.

---

## Fee algorithm

### 1. The temp fee applies to every swap in its block, not only the first

The temp fee is part of the backrun side's starting fee for the whole block. Every swap on that side in the block pays it, on top of the extra fee based on how far the price is from the block's opening price.

Where: `VolatileFeeCalculation.baselineFee`, `VolatilePairHook._getFee`

### 2. A backrun can wait and avoid the temp fee

The temp fee is based on the move since the open of the last block that had a swap, and only applies within `maxTempFeeBlockGap` blocks of that open. Say the price is pushed at the end of block 1. A correction avoids the temp fee in either of two ways:

- **Any swap in between.** If block 2 has at least one swap but none of them correct the price, the first swap of block 2 saves the pushed price as block 2's open. The first swap of block 3 then compares against that open, sees no move, and sets the temp fee to 0. Any swap in block 2 is enough, including a tiny one.
- **No swap for long enough.** If blocks 2 through `1 + maxTempFeeBlockGap` have no swaps, a correction in any later block pays no temp fee: the move is still measured from block 1's open, but the gap is too large. On Ethereum (`maxTempFeeBlockGap = 1`), one empty block is enough: with no swap in block 2, a correction in block 3 pays no temp fee.

In both cases the correction pays only the permanent fee. In the second case the permanent fee has just stepped, so the backrun side is cheaper than before the push, and can be 0 when `maxSkewE6 == restingSpreadE6`. This is accepted because a move nobody traded against within the gap is more likely informed, and the temp fee would then fall on ordinary flow trading against the move. Most backruns land in the same block, where the in block extra applies and cannot be avoided this way.

Where: `VolatilePairHook._loadTopOfBlockState`, `VolatileFeeCalculation.newPermAndTempFee`

### 3. Up and down moves are measured against the old price

Both the block to block move and the in block move are `|P_new - P_ref| / P_ref`. An up move has no upper limit, while a down move is always below 100%. So a move up and back to the same price leans the fees very slightly toward the ask side.

Where: `VolatileFeeCalculation.relativeMove`

### 4. Splitting a backrun in one block pays about half the extra fee of one big swap

Within a block, each swap pays an extra fee based on how far the price is from the block's opening price when that swap starts, and that rate applies to the whole swap. A backrun split into many small swaps in the same block pays on the remaining distance each time, so about half as much in total as one big swap.

Where: `VolatileFeeCalculation.displacementBackrunFee`

### 5. One side's permanent fee can reach 0

Validation allows `maxSkewE6 == restingSpreadE6`. After a strong enough trend, the leaning side's permanent fee reaches the whole resting spread and the other side's reaches 0. The temp fee and the extra fees based on distance from the block's opening price still apply on top.

Where: `VolatileFeeConfiguration._validateMaxSkewE6`

### 6. Fees ignore the pool's protocol fee

All fees are LP fees. If the pool's protocol fee is turned on, v4 adds it on top. `MAX_FEE_E6` is `1e6 - 2` so that the LP fee compounded with any allowed protocol fee stays below 100%.

Where: `VolatileFeeCalculation.MAX_FEE_E6`

### 7. Fees do not depend on swap size

The fee only depends on the pool state, block and direction, never the amount. `getFee` returns exactly what the first swap of the block pays. Later swaps in the same block can pay more, because the extra fee grows as the price moves further from the block's opening price.

Where: `VolatilePairHook.getFee`, `VolatilePairHook._getFee`

### 8. Price moves through ranges with no liquidity are free

In a price range with no active liquidity, a swap moves the price at no cost and can set the fee state (block open price, skew, temp fee). This affects thin pools: brand new pools, pools with sparse liquidity, and pools whose liquidity sits entirely on one side of the price. A normal pool can end up in that last state after a big move pushes the price past every position. In such a pool, one dust swap per block can keep the fee high on the side that trades into liquidity. A config reset does not help, because the state can be rebuilt in the next block. The hook is meant for pools that keep liquidity on both sides of the price.

## Configuration

### 9. A config update resets the pool's fee state immediately

`_updateFeeConfig` sets `blockNumber` and `sqrtPriceTopX96` to 0, the temp fee to 0 and the ask permanent fee to `restingSpreadE6 / 2` rounded down. The next swap, even in the same block, starts fresh from the current pool price. Any temp fee or in block displacement for that block is dropped. The bid permanent fee is always the rest of the spread, so with an odd spread the bid starts 1 pip above the ask.

Where: `VolatileFeeConfiguration._updateFeeConfig`

### 10. There are no default values for the restore settings

A config that leaves `restoreFractionE6` at 0 turns the restore term off. `restoreFractionE6 = 1e6` with `restoreThresholdE6 = 0` adds back the full drop in the backrun side's permanent fee on every move. Launch configs must set both on purpose.

Where: `VolatileFeeCalculation.temporaryBackrunFee`

### 11. Config ranges

- `backrunCaptureFractionE6` and `restoreFractionE6` are capped at `1e6` (100%), inclusive. Capture cannot take more than the whole price move, and restore cannot add back more than the whole permanent fee drop.
- `backrunThresholdE6` and `restoreThresholdE6` must be below `1e6`, since a down move can never reach `1e6`.
- `skewRateE6` and `midFadeRateE6` are not capped. Their effect is limited by `maxSkewStepE6` and `maxMidFadeE6`, and every fee is clamped at `MAX_FEE_E6`.

## Access control and upgrades

### 12. Trust the owner

- `DEFAULT_ADMIN_ROLE` can upgrade the implementation and manage roles.
- `CONFIG_MANAGER_ROLE` can set any config that passes validation, including fees up to `MAX_FEE_E6`, and reset any pool's fee state.
- `POOL_INITIALIZER_ROLE` can create pools through `initializePool`.

Malicious or mistaken actions are out of scope.

### 13. Single step admin transfer

`DEFAULT_ADMIN_ROLE` uses plain OpenZeppelin `AccessControl`: handover is one step, and the last admin can renounce, which would freeze upgrades. Same as StablePairHook.

### 14. Pools can only be created through `initializePool`

`beforeInitialize` reverts for any caller other than the hook. `initializePool` calls `PoolManager.initialize` from the hook itself, which v4 does not call back into. So every pool using the hook has a config.

Where: `BaseDynamicFeeHook._beforeInitialize`, `VolatilePairHook.initializePool`

### 15. Some enabled hook flags do nothing today

The proxy address is mined for `beforeInitialize`, `afterInitialize`, `beforeAddLiquidity`, `afterAddLiquidity`, `beforeSwap` and `afterSwap`. Only `beforeInitialize` and `beforeSwap` do work. The others return immediately and are kept as room for future upgrades, since the flags are fixed by the proxy address. Remove liquidity, return delta and donate flags are off, so LP exits can never be blocked.

Where: `BaseDynamicFeeHook.getHookPermissions`

## Dependencies

### 16. OpenZeppelin versions

On this branch, `lib/openzeppelin-contracts` is at commit `45f032d1` (between v5.6.1 and v5.7.0) and `lib/openzeppelin-contracts-upgradeable` is at v5.5.0. The files the hook uses (`UUPSUpgradeable`, `AccessControl`, `ERC1967Utils`) differ only in comments between these versions. `ERC1967Proxy` at `45f032d1` reverts when deployed with empty init data.

## Rounding

### 17. Rounding direction

Each fee term (restore, capture, and the extra fees based on distance from the block's opening price) rounds up on its own, in favor of LPs, so a fee can be a few pips above the exact value. The Q48 step in `relativeMove` rounds down, which can only make the move look slightly larger.

The permanent fee step also rounds up, so any nonzero move steps the fee by at least 1 pip. On a quiet pool, someone could walk one side's permanent fee down with a tiny swap every block. The saving is at most RS/2 per unit traded at the lowered fee, and it needs a swap in every block for up to `maxSkew - RS/2` blocks with no swap in the other direction. On a low activity pool, liquidity is likely thin too, so slippage and gas make this unprofitable. Rounding up also keeps a slow steady drift leaning the fee the right way.

Where: `VolatileFeeCalculation.newPermanentFee`

## Deployment

### 18. The temp fee block gap is set per chain, not per pool

`maxTempFeeBlockGap` is an immutable of the implementation, so every pool on a chain shares it and changing it needs a new implementation and an upgrade. It is measured in blocks, so the same value means different times on chains with different block times: 1 is 12 seconds on Ethereum but a fraction of a second on a fast L2. Each chain's deployment picks its own value. It must be at least 1, since 0 would turn the temp fee off for every pool; `restoreFractionE6` and `backrunCaptureFractionE6` already turn its pieces off per pool.

Where: `VolatilePairHook.constructor`, `script/deploy/volatile-pair-hook/Parameters.sol`
