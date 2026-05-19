// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/// @title IElfomoSwapCallback
/// @notice Implement this interface to receive callbacks from `ElfomoFi.swapWithCallback`
/// @dev Matches the signature on the deployed `ElfomoFi` contract; the callback must transfer
///      `uint256(fromTokenDelta)` of `fromToken` to `msg.sender` (the ElfomoFi contract) before returning.
interface IElfomoSwapCallback {
    /// @notice Called by ElfomoFi after the output side of a swap has been delivered to `receiver`
    /// @param fromTokenDelta Amount of `fromToken` the callee owes to the ElfomoFi contract (positive)
    /// @param toTokenDelta Amount of `toToken` that was sent to the receiver (negative)
    /// @param data The opaque bytes passed into `ElfomoFi.swapWithCallback`
    function elfomoSwapCallback(int256 fromTokenDelta, int256 toTokenDelta, bytes calldata data) external;
}
