# activeLiquidity
[Git Source](https://github.com/uniswap/v4-hooks-internal/blob/9ca86fbc7a5f56be0963bea4dd445ca15a270071/src/alf/types/Distribution.sol)

Sum the in-range liquidity the buckets would deploy at the current tick, for an
indicative quote. Uses the same per-bucket weighted-balance pre-budgeting as
{computeAllocations} so the indicative tracks what the JIT cycle actually deploys.


```solidity
function activeLiquidity(
LiquidityBucket[] memory buckets,
uint160 sqrtPriceX96,
int24 currentTick,
uint256 bal0,
uint256 bal1
) pure returns (uint128 liquidity);
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`buckets`|`LiquidityBucket[]`|     The pool's buckets (caller fetches via {get}).|
|`sqrtPriceX96`|`uint160`|The current pool sqrt price (Q64.96).|
|`currentTick`|`int24`| The current pool tick.|
|`bal0`|`uint256`|        The deployable currency0 balance.|
|`bal1`|`uint256`|        The deployable currency1 balance.|

**Returns**

|Name|Type|Description|
|----|----|-----------|
|`liquidity`|`uint128`|The total active (in-range) liquidity.|


