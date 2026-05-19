// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/// @title ITesseraPool
/// @notice Per-pair Tessera pool view interface
interface ITesseraPool {
    /// @notice The base token of this Tessera pair (the non-numeraire side).
    /// @return The base token address.
    function baseToken() external view returns (address);

    /// @notice The quote token of this Tessera pair (the numeraire side, typically USDC).
    /// @return The quote token address.
    function quoteToken() external view returns (address);

    /// @notice Decimals of the base token, cached by the pool at registration.
    /// @return The base token's `decimals()` value.
    function baseTokenDecimal() external view returns (uint8);

    /// @notice Decimals of the quote token, cached by the pool at registration.
    /// @return The quote token's `decimals()` value.
    function quoteTokenDecimal() external view returns (uint8);

    /// @notice Per-pool trading kill-switch maintained by the Tessera operator.
    /// @return True if the pool is currently accepting swaps.
    function tradingEnabled() external view returns (bool);
}
