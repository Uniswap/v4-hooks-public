// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/// @title ILitePSM
/// @notice Interface for MakerDAO's LitePSM and LitePSMWrapper contracts
/// @dev The wrapper at 0xA188EEc8F81263234dA3622A406892F3D630f98c presents USDS ↔ USDC
///      The "gem" is USDC (6 decimals). USDS is 18 decimals.
///      to18ConversionFactor = 10^(18 - gem.decimals()) = 10^12 for USDC
interface ILitePSM {
    /// @notice Sell gem (USDC) to receive USDS
    /// @dev Pulls gemAmt of gem from msg.sender; sends USDS to usr
    /// @param usr Address to receive USDS
    /// @param gemAmt Amount of gem (USDC, 6 dec) to sell
    /// @return usdsAmt Amount of USDS sent to usr
    function sellGem(address usr, uint256 gemAmt) external returns (uint256 usdsAmt);

    /// @notice Buy gem (USDC) by spending USDS
    /// @dev Pulls USDS from msg.sender; sends gemAmt of gem to usr
    /// @param usr Address to receive gem (USDC)
    /// @param gemAmt Amount of gem (USDC, 6 dec) to receive
    /// @return usdsAmt Amount of USDS pulled from msg.sender
    function buyGem(address usr, uint256 gemAmt) external returns (uint256 usdsAmt);

    /// @notice Fee rate for sellGem (USDC → USDS), in WAD (1e18 = 100%)
    function tin() external view returns (uint256);

    /// @notice Fee rate for buyGem (USDS → USDC), in WAD (1e18 = 100%)
    function tout() external view returns (uint256);

    /// @notice Conversion factor from gem decimals to 18 decimals (10^(18 - gem.decimals()))
    function to18ConversionFactor() external view returns (uint256);

    /// @notice The gem token address (USDC)
    function gem() external view returns (address);

    /// @notice The pocket contract that holds USDC liquidity
    function pocket() external view returns (address);
}
