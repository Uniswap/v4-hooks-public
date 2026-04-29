// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/// @title IQuoterV2
/// @notice Uniswap V3 Periphery QuoterV2-compatible quoting
interface IQuoterV2 {
    struct QuoteExactInputSingleParams {
        address tokenIn;
        address tokenOut;
        uint256 amountIn;
        uint24 fee;
        uint160 sqrtPriceLimitX96;
    }

    struct QuoteExactOutputSingleParams {
        address tokenIn;
        address tokenOut;
        uint256 amountOut;
        uint24 fee;
        uint160 sqrtPriceLimitX96;
    }

    function quoteExactInputSingle(QuoteExactInputSingleParams memory params) external returns (uint256 amountOut);

    function quoteExactOutputSingle(QuoteExactOutputSingleParams memory params) external returns (uint256 amountIn);
}
