# isLive
[Git Source](https://github.com/uniswap/v4-hooks-internal/blob/9ca86fbc7a5f56be0963bea4dd445ca15a270071/src/alf/types/Liveness.sol)

Whether `poolId` is currently live.


```solidity
function isLive(Liveness storage self, PoolId poolId) view returns (bool);
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`self`|`Liveness`|  Liveness storage.|
|`poolId`|`PoolId`|The pool to read.|

**Returns**

|Name|Type|Description|
|----|----|-----------|
|`<none>`|`bool`|Whether the pool is live and accepting swaps.|


