# get
[Git Source](https://github.com/uniswap/v4-hooks-internal/blob/9ca86fbc7a5f56be0963bea4dd445ca15a270071/src/alf/types/Distribution.sol)

The configured buckets for `poolId`.


```solidity
function get(Distribution storage self, PoolId poolId) view returns (LiquidityBucket[] memory);
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`self`|`Distribution`|  Distribution storage.|
|`poolId`|`PoolId`|The pool to read.|

**Returns**

|Name|Type|Description|
|----|----|-----------|
|`<none>`|`LiquidityBucket[]`|The pool's bucket list (tick ranges and weights).|


