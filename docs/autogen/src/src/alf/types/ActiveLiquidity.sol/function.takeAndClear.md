# takeAndClear
[Git Source](https://github.com/uniswap/v4-hooks-internal/blob/9ca86fbc7a5f56be0963bea4dd445ca15a270071/src/alf/types/ActiveLiquidity.sol)

Read bucket `i`'s recorded liquidity and clear the slot in one step.

Reads slot `base + i` then zeroes it (see the type-level "Load-and-clear" note). Returns
`0` for any bucket that was never {store}d this cycle.


```solidity
function takeAndClear(ActiveLiquidity self, uint256 i) returns (uint128 liq);
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`self`|`ActiveLiquidity`|The pool's active-liquidity base slot.|
|`i`|`uint256`|   The bucket index.|

**Returns**

|Name|Type|Description|
|----|----|-----------|
|`liq`|`uint128`|The liquidity recorded for the bucket, or `0` if none.|


