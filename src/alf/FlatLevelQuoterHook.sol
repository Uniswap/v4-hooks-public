// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20Minimal} from "@uniswap/v4-core/src/interfaces/external/IERC20Minimal.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary, toBeforeSwapDelta} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {FlatQuoterBase} from "./base/FlatQuoterBase.sol";

/// @title FlatLevelQuoterHook
/// @notice Flat-price quoter with delta override settlement and ERC-20 inventory.
///         Executes swaps at fixed coefficients (bid/ask) without using v4's AMM math.
///         The hook holds ERC-20 tokens deposited by the maker. Capacity = token balance.
///         Supports signed pricing updates via hookData with one-update-per-block enforcement.
contract FlatLevelQuoterHook is FlatQuoterBase {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;

    constructor(
        IPoolManager _poolManager,
        uint32 maxGas_,
        address owner_
    ) FlatQuoterBase(_poolManager, maxGas_, owner_, "FlatLevelQuoterHook", "1") {}

    // ──── Hook Permissions ────

    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: false,
            afterInitialize: true,
            beforeAddLiquidity: true,
            beforeRemoveLiquidity: false,
            afterAddLiquidity: false,
            afterRemoveLiquidity: false,
            beforeSwap: true,
            afterSwap: false,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: true,
            afterSwapReturnDelta: false,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    // ──── Core Swap Logic ────

    function _beforeSwap(address, PoolKey calldata key, SwapParams calldata params, bytes calldata hookData)
        internal
        override
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        {
            (bytes memory curveUpdateData,,) = _resolveHookData(hookData);
            if (curveUpdateData.length > 0) {
                _applyCurveUpdate(key.toId(), curveUpdateData);
            }
        }

        // Compute amounts — state dies at end of block to free stack
        uint256 inputAmount;
        uint256 outputAmount;
        {
            FlatPricingState memory state = flatPricingState[key.toId()];
            if (!state.live) {
                return (IHooks.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
            }
            PoolId poolId = key.toId();
            uint256 absAmount =
                params.amountSpecified < 0 ? uint256(-params.amountSpecified) : uint256(params.amountSpecified);
            uint128 coefficient = params.zeroForOne ? state.bidCoefficient : state.askCoefficient;
            if (params.amountSpecified < 0) {
                inputAmount = absAmount;
                outputAmount = _computeOutput(poolId, params.zeroForOne, absAmount, coefficient);
            } else {
                outputAmount = absAmount;
                inputAmount = _computeInput(poolId, params.zeroForOne, absAmount, coefficient);
            }
        }

        // Settle and apply protocol fee
        return _settleAndBuildDelta(key, params, inputAmount, outputAmount);
    }

    /// @dev Settle output from inventory, mint input claims, apply protocol fee, build delta.
    ///      Separated to manage stack depth in _beforeSwap.
    function _settleAndBuildDelta(
        PoolKey calldata key,
        SwapParams calldata params,
        uint256 inputAmount,
        uint256 outputAmount
    ) private returns (bytes4, BeforeSwapDelta, uint24) {
        Currency outputCurrency = params.zeroForOne ? key.currency1 : key.currency0;
        Currency inputCurrency = params.zeroForOne ? key.currency0 : key.currency1;

        uint256 available = IERC20Minimal(Currency.unwrap(outputCurrency)).balanceOf(address(this))
            + poolManager.balanceOf(address(this), outputCurrency.toId());
        if (available < outputAmount) revert InsufficientInventory();

        _settleWithClaimPriority(outputCurrency, outputAmount);
        poolManager.mint(address(this), inputCurrency.toId(), inputAmount);

        bool isExactInput = params.amountSpecified < 0;
        int128 unspecifiedDelta =
            isExactInput ? -int128(uint128(outputAmount)) : int128(uint128(inputAmount));
        int128 fee = _applyProtocolFee(poolManager, key, params, unspecifiedDelta);

        BeforeSwapDelta bsd = isExactInput
            ? toBeforeSwapDelta(int128(uint128(inputAmount)), -int128(uint128(outputAmount)) + fee)
            : toBeforeSwapDelta(-int128(uint128(outputAmount)), int128(uint128(inputAmount)) + fee);
        return (IHooks.beforeSwap.selector, bsd, 0);
    }
}
