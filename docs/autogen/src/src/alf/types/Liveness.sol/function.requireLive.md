# requireLive
[Git Source](https://github.com/uniswap/v4-hooks-internal/blob/9ca86fbc7a5f56be0963bea4dd445ca15a270071/src/alf/types/Liveness.sol)

Revert {PoolNotLive} if `poolId` is paused.


```solidity
function requireLive(Liveness storage self, PoolId poolId) view;
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`self`|`Liveness`|  Liveness storage.|
|`poolId`|`PoolId`|The pool to gate on.|


