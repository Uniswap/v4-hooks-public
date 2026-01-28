// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title IFluidDexV2Callback
/// @notice Callback interface required by Fluid DEX V2 operations
interface IFluidDexV2Callback {
    /// @notice Called by Fluid DEX V2 during startOperation to execute batched operations
    /// @dev Implement this to perform swaps, liquidity operations, or other DEX interactions
    /// @param data Encoded operation data passed from startOperation
    /// @return Result data from the callback execution
    function startOperationCallback(bytes calldata data) external returns (bytes memory);

    /// @notice Called by Fluid DEX V2 when settle(..., isCallback=true) is used
    /// @dev Must transfer exactly `amount` of `token` to `to` address
    /// @param token The token address that must be transferred
    /// @param to The recipient address for the token transfer
    /// @param amount The exact amount of tokens to transfer
    function dexCallback(address token, address to, uint256 amount) external;
}
