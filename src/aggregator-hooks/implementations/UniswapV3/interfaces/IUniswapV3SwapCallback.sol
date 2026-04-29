// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/// @title IUniswapV3SwapCallback
/// @notice Callback from Uniswap V3 compatible pools during swap
interface IUniswapV3SwapCallback {
    function uniswapV3SwapCallback(int256 amount0Delta, int256 amount1Delta, bytes calldata data) external;
}
