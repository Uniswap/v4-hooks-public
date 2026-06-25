// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Ownable, Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {BaseALFHook} from "./BaseALFHook.sol";
import {IALFHook} from "../interfaces/IALFHook.sol";

/// @title DualPoolBase
/// @author Uniswap Labs
/// @notice Minimal ALF/v4 base for SmartPoolHook. Layers owner administration (`Ownable2Step`
///         with `renounceOwnership` disabled), per-pool liveness, and a direct-initialize guard
///         on top of the shared `BaseALFHook` metadata surface: `maxGas`, `isLive`, reserves,
///         indicative quoting, the `ALFHookData`/attestation envelope, and `DeltaResolver`
///         settlement (`_pay`). The `IALFHook` view defaults (`getIndicativeQuote`,
///         `getReserves`, `getEffectiveLiquidity`, `swapToPrice` → 0) are inherited from
///         `BaseALFHook`; `SmartPoolHook` overrides the ones it supports.
/// @dev Pool fees are static per `PoolKey.fee` and immutable post-initialize. The owner has
///      only a per-pool liveness flag for pause/resume; pricing itself cannot be reconfigured
///      after deployment.
/// @custom:security-contact security@uniswap.org
abstract contract SmartPoolBase is BaseALFHook, Ownable2Step {
    /// @notice Whether each pool is currently quoting and executing swaps. Set by the
    ///         subclass's guarded `initializePool` and toggled via {DualPoolHook.setPoolLive}.
    mapping(PoolId => bool) public livePools;

    /// @notice Emitted whenever a pool's liveness flag changes.
    /// @param poolId The pool whose liveness changed.
    /// @param isLive The new liveness state.
    event PoolLivenessUpdated(PoolId indexed poolId, bool isLive);

    /// @dev A bucket's tick range is malformed (lower >= upper, out of `TickMath` range, or
    ///      not aligned to the pool's tickSpacing).
    error InvalidTickRange();
    /// @dev Direct `poolManager.initialize` for any DualPool-hooked pool is rejected;
    ///      callers MUST go through the subclass's guarded `initializePool` entry point so
    ///      pricing, distribution, and vault config are validated before PM init runs.
    error DirectInitializeBlocked();

    /// @dev `renounceOwnership` was called. Renouncing would permanently disable every
    ///      `onlyOwner` entry point in this hook (`initializePool`, `setPoolLive`,
    ///      `setExternalDeposits`, `setDistribution`, `refreshVaultApproval`, etc.) and
    ///      orphan every pool referencing this hook. The operator is the single trust
    ///      principal in this contract's model; their continuing presence is load-bearing.
    error RenounceOwnershipDisabled();

    /// @param manager The Uniswap v4 PoolManager.
    /// @param maxGas_ Gas budget declared for `getIndicativeQuote` staticcalls.
    /// @param owner_  Initial contract owner. Transferable via OZ's two-step
    ///                {Ownable2Step.transferOwnership} / {Ownable2Step.acceptOwnership} flow.
    constructor(IPoolManager manager, uint32 maxGas_, address owner_) BaseALFHook(manager, maxGas_) Ownable(owner_) {}

    /// @dev Reject direct `poolManager.initialize`. Per v4 `Hooks.noSelfCall`, the hook's own
    ///      `poolManager.initialize` from `initializePool` skips this callback, so the only
    ///      caller path that reaches here is an external party's direct attempt.
    function _beforeInitialize(address, PoolKey calldata, uint160) internal pure override returns (bytes4) {
        revert DirectInitializeBlocked();
    }

    /// @notice Disabled. The hook's design requires a live owner indefinitely; renouncing
    ///         would permanently brick every `onlyOwner` entry point and orphan every pool
    ///         referencing this hook. Use `Ownable2Step.transferOwnership` to rotate to a
    ///         new operator address; never call this.
    /// @dev    Mirrors the standard OZ pattern for contracts where administrative recovery
    ///         is load-bearing. See `RenounceOwnershipDisabled` for the rationale.
    function renounceOwnership() public pure override {
        revert RenounceOwnershipDisabled();
    }

    /// @inheritdoc IALFHook
    /// @dev Always reports live; hook-level liveness is per-pool via `livePools[poolId]`.
    ///      Routers call this to reject offline hooks; this hook is always reachable, but
    ///      individual pools may pause via {DualPoolHook.setPoolLive}.
    function isLive() external pure override returns (bool) {
        return true;
    }
}
