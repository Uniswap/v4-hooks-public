# Constants
[Git Source](https://github.com/uniswap/v4-hooks-internal/blob/9ca86fbc7a5f56be0963bea4dd445ca15a270071/src/alf/types/JITLock.sol)

### JIT_LOCK_NAMESPACE
Transient-storage namespace seed for the per-pool JIT lock. Combined with a `PoolId` to
derive a per-pool slot; see {jitLockFor}. Kept identical to the prior `JITLockable`
abstract contract so the lock slots are bit-for-bit unchanged across this refactor.


```solidity
bytes32 constant JIT_LOCK_NAMESPACE = keccak256("alf.jitlockable.lock.v1")
```

### JIT_GLOBAL_COUNTER_SLOT
Transient slot for the global "any JIT in flight" counter, shared across every pool a hook
serves. Incremented by {enter}, decremented by {clear}, read by {anyJITInProgress}.


```solidity
bytes32 constant JIT_GLOBAL_COUNTER_SLOT = keccak256("alf.jitlockable.global.v1")
```

