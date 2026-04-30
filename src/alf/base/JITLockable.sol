// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";

/// @title JITLockable
/// @author Uniswap Labs
/// @notice Transient-storage JIT-cycle reentrancy lock for hooks that deploy and tear down
///         per-swap LP liquidity in `_beforeSwap` / `_afterSwap`.
///
///         Two slots cover two distinct reentrancy paths:
///
///         1. **Per-pool lock** -- read by `_afterSwap` to decide whether to run teardown.
///            Set on entry to a JIT cycle, cleared on exit. Boolean (0/1).
///
///         2. **Global in-flight counter** -- incremented when any pool's cycle starts,
///            decremented on exit. Read by {whenJITNotInProgress} to reject cross-pool
///            reentry from a vault callback during pool A's cycle into pool B's user/admin
///            entry points (e.g., `addLiquidity`, `setDistribution`).
///
///         Both slots are namespaced via `keccak256(...)` so they cannot collide with
///         OpenZeppelin's `ReentrancyGuardTransient` slot or any other transient state in
///         the consumer contract.
///
/// @dev Subclasses MUST guard external user/admin entry points with {whenJITNotInProgress}
///      and call `_setJITLock(poolId)` / `_clearJITLock(poolId)` exactly once per cycle.
///      `_isJITLocked(poolId)` should be read at the top of `_beforeSwap` to reject same-
///      pool reentrancy (which would otherwise corrupt the lifecycle: an inner cycle's
///      `_clearJITLock` would zero the per-pool slot while the outer cycle is still
///      mid-flight, orphaning its deployed positions).
/// @custom:security-contact security@uniswap.org
abstract contract JITLockable {
    /// @dev Transient namespace for per-pool JIT locks. The slot for `poolId` is
    ///      `keccak256(abi.encode(_JIT_LOCK_NAMESPACE, poolId))`. Per-pool scoping is
    ///      required so cross-pool reentry (vault on pool A invokes a swap on pool B
    ///      during pool A's JIT cycle) cannot clear pool A's lock when pool B's
    ///      `_afterSwap` runs.
    bytes32 private constant _JIT_LOCK_NAMESPACE = keccak256("alf.jitlockable.lock.v1");

    /// @dev Transient slot for the global "any JIT in flight" counter. Incremented on
    ///      `_setJITLock`, decremented on `_clearJITLock`. Read by `whenJITNotInProgress`
    ///      to reject ANY reentrant user/admin call that originates inside an in-flight
    ///      JIT cycle anywhere in this hook -- closing the cross-pool path that a per-pool
    ///      lock alone would leave open.
    bytes32 private constant _JIT_GLOBAL_COUNTER_SLOT = keccak256("alf.jitlockable.global.v1");

    /// @dev A user-facing or admin entry point was called from inside an active JIT cycle
    ///      anywhere in this hook, or `_beforeSwap` was re-entered for an already-locked pool.
    error JITInProgress();

    /// @dev Reverts if any pool served by this hook has a JIT cycle in flight. Apply to
    ///      external user/admin functions whose effects would conflict with mid-flight JIT
    ///      state (deposits, withdrawals, distribution updates, pricing updates, etc.).
    modifier whenJITNotInProgress() {
        if (_isAnyJITInProgress()) revert JITInProgress();
        _;
    }

    /// @dev Set the per-pool JIT lock and increment the global in-flight counter. Call at
    ///      the top of a JIT cycle (typically `_beforeSwap`).
    function _setJITLock(PoolId poolId) internal {
        bytes32 perPool = _jitLockSlot(poolId);
        bytes32 global = _JIT_GLOBAL_COUNTER_SLOT;
        assembly ("memory-safe") {
            tstore(perPool, 1)
            tstore(global, add(tload(global), 1))
        }
    }

    /// @dev Clear the per-pool JIT lock and decrement the global counter. Call at the end of
    ///      a JIT cycle (typically `_afterSwap`). Callers MUST check `_isJITLocked(poolId)`
    ///      before invoking, otherwise the counter underflows.
    function _clearJITLock(PoolId poolId) internal {
        bytes32 perPool = _jitLockSlot(poolId);
        bytes32 global = _JIT_GLOBAL_COUNTER_SLOT;
        assembly ("memory-safe") {
            tstore(perPool, 0)
            tstore(global, sub(tload(global), 1))
        }
    }

    /// @dev Returns whether the given pool has its own JIT cycle in flight.
    function _isJITLocked(PoolId poolId) internal view returns (bool locked) {
        bytes32 slot = _jitLockSlot(poolId);
        assembly ("memory-safe") {
            locked := tload(slot)
        }
    }

    /// @dev Returns whether ANY pool served by this hook has a JIT cycle in flight. Used by
    ///      `whenJITNotInProgress` to reject cross-pool reentry from a vault callback.
    function _isAnyJITInProgress() internal view returns (bool inProgress) {
        bytes32 slot = _JIT_GLOBAL_COUNTER_SLOT;
        assembly ("memory-safe") {
            inProgress := iszero(iszero(tload(slot)))
        }
    }

    /// @dev Per-pool transient slot for the JIT lock.
    function _jitLockSlot(PoolId poolId) private pure returns (bytes32) {
        return keccak256(abi.encode(_JIT_LOCK_NAMESPACE, poolId));
    }
}
