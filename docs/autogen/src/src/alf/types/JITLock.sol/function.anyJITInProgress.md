# anyJITInProgress
[Git Source](https://github.com/uniswap/v4-hooks-internal/blob/9ca86fbc7a5f56be0963bea4dd445ca15a270071/src/alf/types/JITLock.sol)

Whether any pool served by the hook has a JIT cycle in flight.

Reads the global counter, not a per-pool slot, so it takes no `JITLock` self.


```solidity
function anyJITInProgress() view returns (bool inProgress);
```
**Returns**

|Name|Type|Description|
|----|----|-----------|
|`inProgress`|`bool`|True if the global in-flight counter is non-zero.|


