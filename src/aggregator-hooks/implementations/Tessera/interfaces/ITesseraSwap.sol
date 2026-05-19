// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/// @title ITesseraSwap
/// @notice Interface for the TesseraSwap PropAMM router
/// @dev Lives at 0x55555522005BcAE1c2424D474BfD5ed477749E3e on Base and BSC.
///      `amountSpecified` follows Tessera's convention: positive = exact input, negative = exact output
///      (the inverse of Uniswap V4's convention).
interface ITesseraSwap {
    /// @notice Emitted when TesseraSwap settles a trade through its engine.
    /// @param tokenIn The token spent by `msg.sender`.
    /// @param tokenOut The token delivered to `recipient`.
    /// @param amountIn Amount of `tokenIn` consumed, in token base units.
    /// @param amountOut Amount of `tokenOut` delivered, in token base units.
    /// @param recipient The recipient of `tokenOut`.
    event TesseraTrade(address tokenIn, address tokenOut, uint256 amountIn, uint256 amountOut, address recipient);

    /// @notice View-quote for a swap. Returns the same `(amountIn, amountOut)` the matching execution
    ///         call would produce in the same block.
    /// @param tokenIn The address of the token being spent.
    /// @param tokenOut The address of the token being received.
    /// @param amountSpecified Positive for exact input, negative for exact output (Tessera convention).
    /// @return amountIn Amount of `tokenIn` that would be consumed, in token base units.
    /// @return amountOut Amount of `tokenOut` that would be delivered, in token base units.
    function tesseraSwapViewAmounts(address tokenIn, address tokenOut, int256 amountSpecified)
        external
        view
        returns (uint256 amountIn, uint256 amountOut);

    /// @notice Approval-based swap entrypoint; assumes `msg.sender` has approved `tokenIn` to TesseraSwap.
    /// @param tokenIn The address of the token being spent.
    /// @param tokenOut The address of the token being received.
    /// @param amountSpecified Positive for exact input, negative for exact output (Tessera convention).
    /// @param amountCheck Min `amountOut` for exact input, max `amountIn` for exact output.
    /// @param recipient The address to receive `tokenOut`.
    /// @param swapData Engine-specific routing payload (use empty bytes for default routing).
    function tesseraSwapWithAllowances(
        address tokenIn,
        address tokenOut,
        int256 amountSpecified,
        uint256 amountCheck,
        address recipient,
        bytes calldata swapData
    ) external;

    /// @notice Callback-based swap entrypoint; TesseraSwap pulls `tokenIn` from `msg.sender` via the callback.
    /// @param tokenIn The address of the token being spent.
    /// @param tokenOut The address of the token being received.
    /// @param amountSpecified Positive for exact input, negative for exact output (Tessera convention).
    /// @param amountCheck Min `amountOut` for exact input, max `amountIn` for exact output.
    /// @param recipient The address to receive `tokenOut`.
    /// @param callbackData Opaque bytes passed through to `tesseraSwapCallback` on `msg.sender`.
    /// @param swapData Engine-specific routing payload (use empty bytes for default routing).
    function tesseraSwapWithCallback(
        address tokenIn,
        address tokenOut,
        int256 amountSpecified,
        uint256 amountCheck,
        address recipient,
        bytes calldata callbackData,
        bytes calldata swapData
    ) external;
}
