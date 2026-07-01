# activeLiquidityFor
[Git Source](https://github.com/uniswap/v4-hooks-internal/blob/9ca86fbc7a5f56be0963bea4dd445ca15a270071/src/alf/types/ActiveLiquidity.sol)

Derive the active-liquidity base slot for `poolId`.

One keccak per JIT cycle; per-bucket slots are this base plus the bucket index.


```solidity
function activeLiquidityFor(PoolId poolId) pure returns (ActiveLiquidity);
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`poolId`|`PoolId`|The pool whose JIT liquidity slots to address.|

**Returns**

|Name|Type|Description|
|----|----|-----------|
|`<none>`|`ActiveLiquidity`|The per-pool transient base slot.|


