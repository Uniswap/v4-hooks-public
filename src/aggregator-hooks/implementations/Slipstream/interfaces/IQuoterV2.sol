// SPDX-License-Identifier: MIT
pragma solidity 0.8.29;

/// @title IQuoterV2
/// @notice Aerodrome Slipstream Base quoter ABI (`int24 tickSpacing` — Uni QuoterV2 uses `uint24 fee`).
interface IQuoterV2 {
    struct QuoteExactInputSingleParams {
        address tokenIn;
        address tokenOut;
        uint256 amountIn;
        int24 tickSpacing;
        uint160 sqrtPriceLimitX96;
    }

    struct QuoteExactOutputSingleParams {
        address tokenIn;
        address tokenOut;
        uint256 amountOut;
        int24 tickSpacing;
        uint160 sqrtPriceLimitX96;
    }

    function quoteExactInputSingle(QuoteExactInputSingleParams memory params) external returns (uint256 amountOut);

    function quoteExactOutputSingle(QuoteExactOutputSingleParams memory params) external returns (uint256 amountIn);
}
