// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ExternalLiqSourceHook} from "../../ExternalLiqSourceHook.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {ITempoExchange} from "./interfaces/ITempoExchange.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @title TempoExchangeAggregator
/// @notice Uniswap V4 hook that aggregates liquidity from Tempo's enshrined stablecoin DEX
/// @dev Supports both exact-input and exact-output swaps
/// @dev Tempo uses uint128 for amounts; this contract handles the conversion from uint256
contract TempoExchangeAggregator is ExternalLiqSourceHook {
    using StateLibrary for IPoolManager;
    using SafeERC20 for IERC20;

    /// @notice The Tempo stablecoin exchange (precompiled contract)
    ITempoExchange public immutable TEMPO_EXCHANGE;

    /// @notice The Uniswap V4 pool ID associated with this aggregator
    PoolId public localPoolId;

    /// @notice Token addresses for the pool
    address public token0;
    address public token1;

    error AmountExceedsUint128();
    error TokenNotSupported(address token);
    error TokensNotSupported(address token0, address token1);

    /// @param _manager The Uniswap V4 PoolManager contract
    /// @param _tempoExchange The Tempo stablecoin exchange address
    constructor(IPoolManager _manager, ITempoExchange _tempoExchange) ExternalLiqSourceHook(_manager) {
        TEMPO_EXCHANGE = _tempoExchange;
    }

    /// @inheritdoc ExternalLiqSourceHook
    /// @dev Although Tempo's quote functions are view, this must be payable to match the base contract
    function quote(bool zeroToOne, int256 amountSpecified, PoolId poolId)
        external
        payable
        override
        returns (uint256 amountUnspecified)
    {
        if (PoolId.unwrap(poolId) != PoolId.unwrap(localPoolId)) revert PoolDoesNotExist();

        address tokenIn = zeroToOne ? token0 : token1;
        address tokenOut = zeroToOne ? token1 : token0;

        if (amountSpecified < 0) {
            // Exact-In: get expected output
            uint128 amountIn = _safeToUint128(uint256(-amountSpecified));
            amountUnspecified = uint256(TEMPO_EXCHANGE.quoteSwapExactAmountIn(tokenIn, tokenOut, amountIn));
        } else {
            // Exact-Out: get required input
            uint128 amountOut = _safeToUint128(uint256(amountSpecified));
            amountUnspecified = uint256(TEMPO_EXCHANGE.quoteSwapExactAmountOut(tokenIn, tokenOut, amountOut));
        }
    }

    /// @inheritdoc ExternalLiqSourceHook
    function pseudoTotalValueLocked(PoolId poolId) external view override returns (uint256 amount0, uint256 amount1) {
        if (PoolId.unwrap(poolId) != PoolId.unwrap(localPoolId)) revert PoolDoesNotExist();
        // Tempo exchange is a precompiled contract, query token balances directly
        amount0 = IERC20(token0).balanceOf(address(TEMPO_EXCHANGE));
        amount1 = IERC20(token1).balanceOf(address(TEMPO_EXCHANGE));
    }

    function _beforeInitialize(address, PoolKey calldata key, uint160) internal override returns (bytes4) {
        // Store token addresses for this pool
        token0 = Currency.unwrap(key.currency0);
        token1 = Currency.unwrap(key.currency1);

        // Validate tokens are supported by querying a small quote
        // If tokens aren't supported, the quote will revert
        try TEMPO_EXCHANGE.quoteSwapExactAmountIn(token0, token1, 1) {}
        catch {
            revert TokensNotSupported(token0, token1);
        }

        localPoolId = key.toId();

        // Approve Tempo exchange to spend tokens
        IERC20(token0).safeIncreaseAllowance(address(TEMPO_EXCHANGE), type(uint256).max);
        IERC20(token1).safeIncreaseAllowance(address(TEMPO_EXCHANGE), type(uint256).max);

        emit AggregatorPoolRegistered(key.toId());
        return IHooks.beforeInitialize.selector;
    }

    function _conductSwap(Currency settleCurrency, Currency takeCurrency, SwapParams calldata params, PoolId)
        internal
        override
        returns (uint256 amountSettle, uint256 amountTake, bool hasSettled)
    {
        address tokenIn = Currency.unwrap(takeCurrency);
        address tokenOut = Currency.unwrap(settleCurrency);

        if (params.amountSpecified < 0) {
            // Exact-In swap
            amountTake = uint256(-params.amountSpecified);
            uint128 amountIn = _safeToUint128(amountTake);

            // Take input tokens from PoolManager to hook
            poolManager.take(takeCurrency, address(this), amountTake);

            // Execute swap on Tempo (output comes to hook)
            uint128 amountOut = TEMPO_EXCHANGE.swapExactAmountIn(tokenIn, tokenOut, amountIn, 0);
            amountSettle = uint256(amountOut);

            // Sync output currency and transfer to PoolManager
            poolManager.sync(settleCurrency);
            IERC20(tokenOut).safeTransfer(address(poolManager), amountSettle);
            poolManager.settle();
            hasSettled = true;
        } else {
            // Exact-Out swap
            amountSettle = uint256(params.amountSpecified);
            uint128 amountOut = _safeToUint128(amountSettle);

            // Get the required input amount
            uint128 requiredIn = TEMPO_EXCHANGE.quoteSwapExactAmountOut(tokenIn, tokenOut, amountOut);
            amountTake = uint256(requiredIn);

            // Take input tokens from PoolManager to hook
            poolManager.take(takeCurrency, address(this), amountTake);

            // Execute swap on Tempo (output comes to hook)
            TEMPO_EXCHANGE.swapExactAmountOut(tokenIn, tokenOut, amountOut, type(uint128).max);

            // Sync output currency and transfer to PoolManager
            poolManager.sync(settleCurrency);
            IERC20(tokenOut).safeTransfer(address(poolManager), amountSettle);
            poolManager.settle();
            hasSettled = true;
        }

        return (amountSettle, amountTake, hasSettled);
    }

    /// @notice Safely converts uint256 to uint128, reverting on overflow
    /// @param value The uint256 value to convert
    /// @return The uint128 value
    function _safeToUint128(uint256 value) internal pure returns (uint128) {
        if (value > type(uint128).max) revert AmountExceedsUint128();
        return uint128(value);
    }
}
