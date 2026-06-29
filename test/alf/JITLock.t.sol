// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {
    JITLock,
    JITInProgress,
    jitLockFor,
    anyJITInProgress,
    requireJITNotInProgress
} from "../../src/alf/types/JITLock.sol";

/// @notice Thin harness so the type's transient state is exercised through external calls (needed
///         to assert reverts with `vm.expectRevert`). Transient storage persists across these
///         sub-calls within a single test transaction and is reset between tests.
contract JITLockHarness {
    function enterPool(PoolId id) external {
        jitLockFor(id).enter();
    }

    function clearPool(PoolId id) external {
        jitLockFor(id).clear();
    }

    function anyInProgress() external view returns (bool) {
        return anyJITInProgress();
    }

    function requireNotInProgress() external view {
        requireJITNotInProgress();
    }
}

/// @title JITLockTest
/// @notice Isolated unit tests for the `JITLock` transient reentrancy-lock type, covering the
///         per-pool lock, the global in-flight counter, and the cross-pool guard, without standing
///         up a full hook.
contract JITLockTest is Test {
    JITLockHarness internal h;

    PoolId internal poolA = PoolId.wrap(bytes32(uint256(0xA)));
    PoolId internal poolB = PoolId.wrap(bytes32(uint256(0xB)));

    function setUp() public {
        h = new JITLockHarness();
    }

    function test_enter_setsInProgress() public {
        assertFalse(h.anyInProgress(), "starts idle");
        h.enterPool(poolA);
        assertTrue(h.anyInProgress(), "in-flight after enter");
    }

    function test_clear_resetsInProgress() public {
        h.enterPool(poolA);
        h.clearPool(poolA);
        assertFalse(h.anyInProgress(), "idle again after clear");
    }

    function test_enter_rejectsSamePoolReentry() public {
        h.enterPool(poolA);
        vm.expectRevert(JITInProgress.selector);
        h.enterPool(poolA);
    }

    function test_requireNotInProgress_revertsWhileAnyCycleInFlight() public {
        h.enterPool(poolA);
        vm.expectRevert(JITInProgress.selector);
        h.requireNotInProgress();
    }

    /// @dev The cross-pool guard: an in-flight cycle on pool A blocks an entry-point gated by
    ///      `requireJITNotInProgress` even for a different pool B (the global counter is nonzero
    ///      though B's per-pool slot is clear). This is the path a per-pool lock alone would miss.
    function test_requireNotInProgress_blocksOtherPoolDuringCycle() public {
        h.enterPool(poolA);
        vm.expectRevert(JITInProgress.selector);
        h.requireNotInProgress(); // would gate pool B's addLiquidity/etc.
    }

    function test_requireNotInProgress_passesWhenIdle() public {
        h.requireNotInProgress(); // no revert
        h.enterPool(poolA);
        h.clearPool(poolA);
        h.requireNotInProgress(); // no revert after the cycle completes
    }

    /// @dev Distinct pools have independent per-pool locks but share the global counter, so both
    ///      can be in flight at once and the hook is only idle once every cycle has cleared.
    function test_distinctPools_independentLocks_sharedCounter() public {
        h.enterPool(poolA);
        h.enterPool(poolB); // different per-pool slot, allowed; counter now 2
        assertTrue(h.anyInProgress());

        h.clearPool(poolA); // counter 1
        assertTrue(h.anyInProgress(), "pool B still in flight");

        h.clearPool(poolB); // counter 0
        assertFalse(h.anyInProgress(), "idle once all cycles clear");
    }

    function testFuzz_jitLockFor_isDeterministicAndPerPool(bytes32 a, bytes32 b) public pure {
        PoolId idA = PoolId.wrap(a);
        PoolId idB = PoolId.wrap(b);
        assertEq(JITLock.unwrap(jitLockFor(idA)), JITLock.unwrap(jitLockFor(idA)), "same pool yields same slot");
        if (a != b) {
            assertTrue(
                JITLock.unwrap(jitLockFor(idA)) != JITLock.unwrap(jitLockFor(idB)),
                "distinct pools yield distinct slots"
            );
        }
    }
}
