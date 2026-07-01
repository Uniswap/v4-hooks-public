# clear
[Git Source](https://github.com/uniswap/v4-hooks-internal/blob/9ca86fbc7a5f56be0963bea4dd445ca15a270071/src/alf/types/JITLock.sol)

Clear the per-pool JIT lock and decrement the global in-flight counter.

Call at the end of a JIT cycle after a successful {enter}. A matching prior {enter} is a
hard precondition: the global counter decrement underflows otherwise. The pairing is
structurally enforced by the hook's begin/end JIT cycle ({enter} in `beforeSwap`, [clear](/src/alf/types/JITLock.sol/function.clear.md#clear)
in `afterSwap`), so [clear](/src/alf/types/JITLock.sol/function.clear.md#clear) is never reached without a preceding {enter}.


```solidity
function clear(JITLock self) ;
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`self`|`JITLock`|The pool's JIT lock.|


