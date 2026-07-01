# enter
[Git Source](https://github.com/uniswap/v4-hooks-internal/blob/9ca86fbc7a5f56be0963bea4dd445ca15a270071/src/alf/types/JITLock.sol)

Enter the per-pool JIT lock and increment the global in-flight counter.

Call at the top of a JIT cycle. Reverts {JITInProgress} on same-pool reentry. Combines the
reentrancy check with the lock write so hot swap paths pay for one slot derivation.


```solidity
function enter(JITLock self) ;
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`self`|`JITLock`|The pool's JIT lock.|


