// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import {IConfigManager} from "../interfaces/IConfigManager.sol";

/// @title ConfigManager
/// @notice Abstract contract that implements the IConfigManager interface
abstract contract ConfigManager is IConfigManager {
    /// @notice The address of the config manager
    /// @dev The config manager is the address that can update the fee configuration for a pool
    address public configManager;

    constructor(address _configManager) {
        configManager = _configManager;
    }

    /// @notice Modifier to only allow calls from the config manager
    /// @dev This modifier is used to prevent unauthorized updates to the fee configuration per pool
    modifier onlyConfigManager() {
        if (msg.sender != configManager) revert NotConfigManager(msg.sender);
        _;
    }

    /// @inheritdoc IConfigManager
    function setConfigManager(address newConfigManager) external onlyConfigManager {
        configManager = newConfigManager;
        emit ConfigManagerUpdated(newConfigManager);
    }
}
