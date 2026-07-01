# JITInProgress
[Git Source](https://github.com/uniswap/v4-hooks-internal/blob/9ca86fbc7a5f56be0963bea4dd445ca15a270071/src/alf/types/JITLock.sol)

A user-facing or admin entry point was called from inside an active JIT cycle anywhere in
the hook, or `beforeSwap` was re-entered for an already-locked pool.


```solidity
error JITInProgress();
```

