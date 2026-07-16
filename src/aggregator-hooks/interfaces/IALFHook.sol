// SPDX-License-Identifier: CC0-1.0
pragma solidity >=0.8.0;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";

/// @notice Thrown when the hook requires a payload and hookData is empty.
error MissingHookData();

/// @notice Thrown when non-empty hookData cannot be interpreted by the hook.
error MalformedHookData();

/// @notice Router-facing ALF interface for custom-accounting hooks.
/// @dev Vendored from URC-4 (Active Liquidity Framework Hook Interface) reference implementation.
interface IALFHook is IERC165 {
    /// @notice Get a non-binding indicative quote.
    /// @dev Returns 0 when the hook cannot price the swap under normal conditions.
    ///      Reverts with MissingHookData or MalformedHookData for missing or
    ///      undecodable hookData.
    /// @param key The pool key.
    /// @param zeroForOne Swap direction.
    /// @param amountSpecified Negative = exact input, positive = exact output.
    /// @param hookData Empty bytes or a hook-specific payload.
    /// @return quoteAmount For exact input, expected output. For exact output, expected input.
    function getIndicativeQuote(PoolKey calldata key, bool zeroForOne, int256 amountSpecified, bytes calldata hookData)
        external
        returns (uint256 quoteAmount);

    /// @notice Whether the hook is generally live and accepting swaps.
    function isLive() external view returns (bool);

    /// @notice Declared maximum gas for getIndicativeQuote execution.
    function maxGas() external view returns (uint32);

    /// @notice Simulate a swap up to a target price.
    /// @dev Returns (0, 0) when price-bounded simulation is unsupported.
    /// @param key The pool key.
    /// @param zeroForOne Swap direction.
    /// @param amountSpecified Negative = exact input, positive = exact output.
    /// @param sqrtPriceLimitX96 Target Q64.96 sqrt price.
    /// @param hookData Empty bytes or a hook-specific payload.
    /// @return amountIn Input consumed, including fees.
    /// @return amountOut Output received.
    function swapToPrice(
        PoolKey calldata key,
        bool zeroForOne,
        int256 amountSpecified,
        uint160 sqrtPriceLimitX96,
        bytes calldata hookData
    ) external view returns (uint256 amountIn, uint256 amountOut);
}
