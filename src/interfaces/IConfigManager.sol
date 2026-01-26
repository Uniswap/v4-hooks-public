// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

/// @notice Interface for the ConfigManager
interface IConfigManager {
    /// @notice Error thrown when the caller is not the config manager
    /// @param caller The invalid address attempting to update the pool fee data
    error NotConfigManager(address caller);

    /// @notice Event emitted when the config manager is updated
    /// @param configManager The new config manager
    event ConfigManagerUpdated(address indexed configManager);

    /// @notice Set the config manager
    /// @param newConfigManager The address of the new config manager
    function setConfigManager(address newConfigManager) external;
}
