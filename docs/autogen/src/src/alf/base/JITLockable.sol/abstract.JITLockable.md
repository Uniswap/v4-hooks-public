# JITLockable
[Git Source](https://github.com/uniswap/v4-hooks-internal/blob/510f5fe7d91535158cac5795bb284c347ddb8126/src/alf/base/JITLockable.sol)

**Title:**
JITLockable

**Author:**
Uniswap Labs

Transient-storage JIT-cycle reentrancy lock for hooks that deploy and tear down
per-swap LP liquidity in `_beforeSwap` / `_afterSwap`.
Two slots cover two distinct reentrancy paths:
1. **Per-pool lock** -- read by `_afterSwap` to decide whether to run teardown.
Set on entry to a JIT cycle, cleared on exit. Boolean (0/1).
2. **Global in-flight counter** -- incremented when any pool's cycle starts,
decremented on exit. Read by [whenJITNotInProgress](/src/alf/base/JITLockable.sol/abstract.JITLockable.md#whenjitnotinprogress) to reject cross-pool
reentry from a vault callback during pool A's cycle into pool B's user/admin
entry points (e.g., `addLiquidity`, `setDistribution`).
Both slots are namespaced via `keccak256(...)` so they cannot collide with
OpenZeppelin's `ReentrancyGuardTransient` slot or any other transient state in
the consumer contract.

Subclasses MUST guard external user/admin entry points with [whenJITNotInProgress](/src/alf/base/JITLockable.sol/abstract.JITLockable.md#whenjitnotinprogress)
and call `_enterJITLock(poolId)` / `_clearJITLock(poolId)` exactly once per cycle.
`_enterJITLock(poolId)` rejects same-pool reentrancy (which would otherwise corrupt
the lifecycle: an inner cycle's `_clearJITLock` would zero the per-pool slot while
the outer cycle is still mid-flight, orphaning its deployed positions).

**Note:**
security-contact: security@uniswap.org


## State Variables
### _JIT_LOCK_NAMESPACE
Transient namespace for per-pool JIT locks. The slot for `poolId` is
`keccak256(abi.encode(_JIT_LOCK_NAMESPACE, poolId))`. Per-pool scoping is
required so cross-pool reentry (vault on pool A invokes a swap on pool B
during pool A's JIT cycle) cannot clear pool A's lock when pool B's
`_afterSwap` runs.


```solidity
bytes32 private constant _JIT_LOCK_NAMESPACE = keccak256("alf.jitlockable.lock.v1")
```


### _JIT_GLOBAL_COUNTER_SLOT
Transient slot for the global "any JIT in flight" counter. Incremented on
`_enterJITLock`, decremented on `_clearJITLock`. Read by `whenJITNotInProgress`
to reject ANY reentrant user/admin call that originates inside an in-flight
JIT cycle anywhere in this hook -- closing the cross-pool path that a per-pool
lock alone would leave open.


```solidity
bytes32 private constant _JIT_GLOBAL_COUNTER_SLOT = keccak256("alf.jitlockable.global.v1")
```


## Functions
### whenJITNotInProgress

Reverts if any pool served by this hook has a JIT cycle in flight. Apply to
external user/admin functions whose effects would conflict with mid-flight JIT
state (deposits, withdrawals, distribution updates, pricing updates, etc.).


```solidity
modifier whenJITNotInProgress() ;
```

### _enterJITLock

Enter the per-pool JIT lock and increment the global in-flight counter. Call at
the top of a JIT cycle (typically `_beforeSwap`). Combines the reentrancy check
with the lock write so hot swap paths pay for one slot derivation instead of two.


```solidity
function _enterJITLock(PoolId poolId) internal;
```

### _clearJITLock

Clear the per-pool JIT lock and decrement the global counter. Call at the end of
a JIT cycle (typically `_afterSwap`) after a successful `_enterJITLock`.


```solidity
function _clearJITLock(PoolId poolId) internal;
```

### _isAnyJITInProgress

Returns whether ANY pool served by this hook has a JIT cycle in flight. Used by
`whenJITNotInProgress` to reject cross-pool reentry from a vault callback.


```solidity
function _isAnyJITInProgress() internal view returns (bool inProgress);
```

### _jitLockSlot

Per-pool transient slot for the JIT lock.


```solidity
function _jitLockSlot(PoolId poolId) private pure returns (bytes32);
```

## Errors
### JITInProgress
A user-facing or admin entry point was called from inside an active JIT cycle
anywhere in this hook, or `_beforeSwap` was re-entered for an already-locked pool.


```solidity
error JITInProgress();
```

