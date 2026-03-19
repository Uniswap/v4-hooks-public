// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/// @notice Minimal Aave V3 Pool interface for supply/withdraw operations.
interface IAavePool {
    /// @notice Deposit underlying asset into Aave to receive aTokens.
    function supply(address asset, uint256 amount, address onBehalfOf, uint16 referralCode) external;

    /// @notice Withdraw underlying asset from Aave by burning aTokens.
    /// @return The actual amount withdrawn.
    function withdraw(address asset, uint256 amount, address to) external returns (uint256);
}
