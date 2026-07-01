# JITLock
[Git Source](https://github.com/uniswap/v4-hooks-internal/blob/9ca86fbc7a5f56be0963bea4dd445ca15a270071/src/alf/types/JITLock.sol)

**Title:**
JITLock

**Author:**
Uniswap Labs

The transient per-pool JIT-cycle reentrancy lock, as a type-driven value. A JIT hook
derives one `JITLock` per pool via {jitLockFor}, calls {enter} at the top of a cycle
(`beforeSwap`) and {clear} at the end (`afterSwap`), and gates its external user/admin
entry points on {requireJITNotInProgress}.
Two transient slots cover two distinct reentrancy paths:
1. **Per-pool lock** (this type's wrapped slot): set by {enter}, cleared by {clear}.
{enter} rejects same-pool reentry, which would otherwise corrupt the lifecycle: an
inner cycle's {clear} would zero the slot while the outer cycle is still mid-flight,
orphaning the outer's deployed positions.
2. **Global in-flight counter** ({JIT_GLOBAL_COUNTER_SLOT}): a single process-wide slot
incremented and decremented alongside the per-pool lock. {requireJITNotInProgress}
reads it to reject cross-pool reentry, e.g. a vault callback during pool A's cycle
calling into pool B's entry points; a per-pool lock alone would leave that open.
The slots are namespaced via `keccak256` so they cannot collide with OpenZeppelin's
`ReentrancyGuardTransient` slot or any other transient state in the consumer. Transient
storage is used because the locks live only for one `beforeSwap`/`afterSwap` pair and
the counter nets back to zero by transaction end.

**Note:**
security-contact: security@uniswap.org


```solidity
type JITLock is bytes32
```

