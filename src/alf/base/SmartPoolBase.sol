// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {DeltaResolver} from "@uniswap/v4-periphery/src/base/DeltaResolver.sol";
import {Ownable, Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {BaseHook} from "../../base/BaseHook.sol";
import {IALFHook} from "../interfaces/IALFHook.sol";

/// @title SmartPoolBase
/// @author Uniswap Labs
/// @notice Minimal ALF/v4 base for SmartPoolHook.
/// @dev Pool fees are static per `PoolKey.fee` and immutable post-initialize. The owner has
///      only a per-pool liveness flag for pause/resume; pricing itself cannot be reconfigured
///      after deployment.
/// @custom:security-contact security@uniswap.org
abstract contract SmartPoolBase is BaseHook, DeltaResolver, Ownable2Step, IALFHook {
    using PoolIdLibrary for PoolKey;

    /// @dev Gas budget declared for `getIndicativeQuote` staticcalls. Returned by `maxGas()`.
    uint32 private immutable _maxGas;

    /// @notice Whether each pool is currently quoting and executing swaps. Set by the
    ///         subclass's guarded `initializePool` and toggled via {SmartPoolHook.setPoolLive}.
    mapping(PoolId => bool) public livePools;

    /// @notice Emitted whenever a pool's liveness flag changes.
    /// @param poolId The pool whose liveness changed.
    /// @param isLive The new liveness state.
    event PoolLivenessUpdated(PoolId indexed poolId, bool isLive);

    /// @dev A bucket's tick range is malformed (lower >= upper, out of `TickMath` range, or
    ///      not aligned to the pool's tickSpacing).
    error InvalidTickRange();
    /// @dev Direct `poolManager.initialize` for any SmartPool-hooked pool is rejected;
    ///      callers MUST go through the subclass's guarded `initializePool` entry point so
    ///      pricing, distribution, and vault config are validated before PM init runs.
    error DirectInitializeBlocked();

    /// @dev Reject direct `poolManager.initialize`. Per v4 `Hooks.noSelfCall`, the hook's own
    ///      `poolManager.initialize` from `initializePool` skips this callback, so the only
    ///      caller path that reaches here is an external party's direct attempt.
    function _beforeInitialize(address, PoolKey calldata, uint160) internal pure override returns (bytes4) {
        revert DirectInitializeBlocked();
    }

    /// @param manager The Uniswap v4 PoolManager.
    /// @param maxGas_ Gas budget declared for `getIndicativeQuote` staticcalls.
    /// @param owner_  Initial contract owner. Transferable via OZ's two-step
    ///                {Ownable2Step.transferOwnership} / {Ownable2Step.acceptOwnership} flow.
    constructor(IPoolManager manager, uint32 maxGas_, address owner_)
        BaseHook(manager)
        Ownable(owner_)
    {
        _maxGas = maxGas_;
    }

    /// @inheritdoc IALFHook
    function maxGas() external view override returns (uint32) {
        return _maxGas;
    }

    /// @inheritdoc IALFHook
    /// @dev Always reports live; hook-level liveness is per-pool via `livePools[poolId]`.
    ///      Routers call this to reject offline hooks; this hook is always reachable, but
    ///      individual pools may pause via {SmartPoolHook.setPoolLive}.
    function isLive() external pure override returns (bool) {
        return true;
    }

    /// @inheritdoc IALFHook
    /// @dev SmartPool's deployable single-contract build does not include the heavy virtual
    ///      multi-range tick-walking quoter. Returning 0 is the IALFHook unsupported-quote path.
    function getIndicativeQuote(PoolKey calldata, bool, int256, bytes calldata)
        external
        view
        virtual
        override
        returns (uint256)
    {
        return 0;
    }

    /// @inheritdoc IALFHook
    function getReserves(PoolKey calldata) external view virtual override returns (uint256, uint256) {
        return (0, 0);
    }

    /// @inheritdoc IALFHook
    function getEffectiveLiquidity(PoolKey calldata) external view virtual override returns (uint256, uint256) {
        return (0, 0);
    }

    /// @inheritdoc IALFHook
    /// @dev Same unsupported-simulation policy as `getIndicativeQuote`.
    function swapToPrice(PoolKey calldata, bool, int256, uint160, bytes calldata)
        external
        view
        virtual
        override
        returns (uint256, uint256)
    {
        return (0, 0);
    }

    /// @inheritdoc DeltaResolver
    /// @dev Settles a hook-owed delta by transferring `amount` of `token` directly to the
    ///      PoolManager. The `payer` argument is unused because settlement is always from
    ///      the hook's own balance.
    function _pay(Currency token, address, uint256 amount) internal override {
        token.transfer(address(poolManager), amount);
    }
}
