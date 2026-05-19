// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/// @title ITesseraManager
/// @notice Interface for the Tessera pool registry
/// @dev Lives at 0x31e99E05fee3DCE580af777C3fD63eE1B3B40c17 on Base and BSC.
interface ITesseraManager {
    /// @notice Returns whether a direct Tessera pool exists for the given pair, and its address if so.
    /// @param tokenA One side of the pair (any ordering).
    /// @param tokenB The other side of the pair.
    /// @return exists True if a direct pool is registered for the pair (not a multi-hop route).
    /// @return pool The underlying Tessera pool address, or `address(0)` if `exists` is false.
    function getTesseraPool(address tokenA, address tokenB) external view returns (bool exists, address pool);

    /// @notice The asset Tessera uses as the routing hop for indirect pairs (typically USDC).
    /// @dev Our hook rejects multi-hop pairs; this is only useful for diagnostics.
    /// @return The base routing asset address used by Tessera for two-hop routes.
    function baseRoutingAsset() external view returns (address);

    /// @notice Global on/off switch for the manager.
    /// @return True if the Tessera system is currently accepting trades.
    function isActive() external view returns (bool);

    /// @notice Number of pools currently registered with the manager.
    /// @return The count of registered Tessera pools.
    function tesseraPoolsCount() external view returns (uint256);
}
