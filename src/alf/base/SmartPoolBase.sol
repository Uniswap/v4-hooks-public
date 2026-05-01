// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {DeltaResolver} from "@uniswap/v4-periphery/src/base/DeltaResolver.sol";
import {Ownable, Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {BaseHook} from "../../base/BaseHook.sol";
import {IALFHook} from "../interfaces/IALFHook.sol";

/// @title SmartPoolBase
/// @author Uniswap Labs
/// @notice Minimal ALF/v4 base for SmartPoolHook.
/// @dev Deliberately avoids BaseALFHook/SpreadQuoterBase because SmartPool does not use
///      signed hookData updates, attestation resolution, EIP-712, or active-tick LPs.
/// @custom:security-contact security@uniswap.org
abstract contract SmartPoolBase is BaseHook, DeltaResolver, Ownable2Step, IALFHook {
    using PoolIdLibrary for PoolKey;

    /// @notice Pricing state per pool. Single symmetric LP fee applied in both swap directions.
    /// @param feePips Fee override (in pips, max `LPFeeLibrary.MAX_LP_FEE`) applied to all swaps.
    /// @param live    Whether the pool currently quotes and executes swaps.
    struct PricingState {
        uint24 feePips;
        bool live;
    }

    /// @dev Gas budget declared for `getIndicativeQuote` staticcalls. Returned by `maxGas()`.
    uint32 private immutable _maxGas;

    /// @notice Pricing state for each pool managed by this hook.
    mapping(PoolId => PricingState) public pricingState;

    /// @notice Emitted whenever a pool's pricing state is committed via `_commitPricingState`.
    /// @param poolId The pool whose pricing was updated.
    /// @param state  The full new pricing state (post-validation).
    event PricingStateUpdated(PoolId indexed poolId, PricingState state);

    /// @dev A bucket's tick range is malformed (lower >= upper, out of `TickMath` range, or
    ///      not aligned to the pool's tickSpacing).
    error InvalidTickRange();
    /// @dev `feePips` exceeds `LPFeeLibrary.MAX_LP_FEE`. Without this guard, fees > 100% break
    ///      v4 swap math (denominator underflow).
    error FeeOutOfBounds();
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
    /// @dev Always reports live; hook-level liveness is per-pool via `pricingState[poolId].live`.
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

    /// @notice Update the pricing state for a pool.
    /// @dev    Routes through `_commitPricingState`: validates fee bounds, writes storage,
    ///         and emits {PricingStateUpdated}. Subclasses MAY override to add an in-flight-
    ///         JIT guard. The pool need not be initialized for this call to succeed.
    /// @param key   The pool to update.
    /// @param state The new pricing state.
    function updatePricingState(PoolKey calldata key, PricingState calldata state) external virtual onlyOwner {
        _commitPricingState(key, state);
    }

    /// @dev Single chokepoint for committing a `PricingState`. Validates fee bounds, writes
    ///      storage, and emits {PricingStateUpdated}. The PoolManager's stored dynamic LP fee
    ///      is intentionally NOT synced; off-chain readers consult `pricingState(poolId)` for
    ///      the canonical fee + live state.
    /// @param key   The pool to update.
    /// @param state The validated state to commit.
    function _commitPricingState(PoolKey calldata key, PricingState memory state) internal {
        _validateFeeBounds(state);
        emit PricingStateUpdated(key.toId(), state);
        pricingState[key.toId()] = state;
    }

    /// @dev Validate that the fee is within v4's `[0, MAX_LP_FEE]` range. Reverts with
    ///      {FeeOutOfBounds} if exceeded.
    function _validateFeeBounds(PricingState memory state) internal pure {
        if (state.feePips > LPFeeLibrary.MAX_LP_FEE) revert FeeOutOfBounds();
    }

    /// @inheritdoc DeltaResolver
    /// @dev Settles a hook-owed delta by transferring `amount` of `token` directly to the
    ///      PoolManager. The `payer` argument is unused because settlement is always from
    ///      the hook's own balance.
    function _pay(Currency token, address, uint256 amount) internal override {
        token.transfer(address(poolManager), amount);
    }
}
