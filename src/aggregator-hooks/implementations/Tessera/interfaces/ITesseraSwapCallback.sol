// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/// @title ITesseraSwapCallback
/// @notice Implement this interface to receive callbacks from `TesseraSwap.tesseraSwapWithCallback`
/// @dev Matches the signature on the deployed `TesseraSwap` contract; the callback must transfer
///      `uint256(amountInDelta)` of `tokenIn` to `msg.sender` (the TesseraSwap contract) before returning.
interface ITesseraSwapCallback {
    /// @notice Called by TesseraSwap after the output side of a swap has been delivered to `recipient`
    /// @param amountInDelta Amount of `tokenIn` the callee owes to the TesseraSwap contract (positive)
    /// @param amountOutDelta Amount of `tokenOut` that was sent to the recipient (negative)
    /// @param data The opaque bytes passed into `TesseraSwap.tesseraSwapWithCallback`
    function tesseraSwapCallback(int256 amountInDelta, int256 amountOutDelta, bytes calldata data) external;
}
