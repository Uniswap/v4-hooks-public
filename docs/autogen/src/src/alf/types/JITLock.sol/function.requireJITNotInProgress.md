# requireJITNotInProgress
[Git Source](https://github.com/uniswap/v4-hooks-internal/blob/9ca86fbc7a5f56be0963bea4dd445ca15a270071/src/alf/types/JITLock.sol)

Revert {JITInProgress} if any pool served by the hook has a JIT cycle in flight.

The guard for external user/admin entry points whose effects would conflict with
mid-flight JIT state. Consumers wrap this in a thin `whenJITNotInProgress` modifier so the
guard stays visible in each function signature and is hard to omit.


```solidity
function requireJITNotInProgress() view;
```

