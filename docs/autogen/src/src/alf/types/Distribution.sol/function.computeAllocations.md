# computeAllocations
[Git Source](https://github.com/uniswap/v4-hooks-internal/blob/9ca86fbc7a5f56be0963bea4dd445ca15a270071/src/alf/types/Distribution.sol)

Compute the weighted liquidity to deploy per bucket and the total token amounts the
deployment needs, at the current price.

Each bucket is pre-budgeted against its weighted share of the balance, so the summed
liquidity matches what the pool can actually deploy (passing the full balance to
`getLiquidityForAmounts` and post-scaling would over-count across in-range buckets). The
result array is indexed by bucket position, matching the caller's deploy/remove order.


```solidity
function computeAllocations(LiquidityBucket[] memory buckets, uint160 sqrtPriceX96, uint256 bal0, uint256 bal1)
pure
returns (uint128[MAX_BUCKETS] memory liqs, uint256 totalNeed0, uint256 totalNeed1);
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`buckets`|`LiquidityBucket[]`|     The pool's buckets (caller fetches via {get}).|
|`sqrtPriceX96`|`uint160`|The current pool sqrt price (Q64.96).|
|`bal0`|`uint256`|        The deployable currency0 balance.|
|`bal1`|`uint256`|        The deployable currency1 balance.|

**Returns**

|Name|Type|Description|
|----|----|-----------|
|`liqs`|`uint128[MAX_BUCKETS]`|      Per-bucket liquidity to deploy, indexed by position.|
|`totalNeed0`|`uint256`|Total currency0 the deployment consumes.|
|`totalNeed1`|`uint256`|Total currency1 the deployment consumes.|


