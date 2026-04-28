// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/// @title IAavePool
/// @notice Minimal Aave V3 Pool interface for supply/withdraw operations.
/// @dev    Subset of the upstream `IPool` interface (Aave V3) sufficient for ALF integrations.
interface IAavePool {
    /// @notice Deposit underlying asset into Aave to receive aTokens.
    /// @param asset        The ERC-20 underlying to supply.
    /// @param amount       The amount of underlying to supply.
    /// @param onBehalfOf   The address that will receive the aTokens.
    /// @param referralCode Aave referral program code (0 for none).
    function supply(address asset, uint256 amount, address onBehalfOf, uint16 referralCode) external;

    /// @notice Withdraw underlying asset from Aave by burning aTokens.
    /// @param asset  The ERC-20 underlying to withdraw.
    /// @param amount The amount of underlying to withdraw (`type(uint256).max` for all).
    /// @param to     The recipient of the withdrawn underlying.
    /// @return The actual amount of underlying withdrawn.
    function withdraw(address asset, uint256 amount, address to) external returns (uint256);
}
