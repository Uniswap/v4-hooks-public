// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import {ConfigManager} from "../base/ConfigManager.sol";
import {IConfigManager} from "../interfaces/IConfigManager.sol";

/// @title ConfigManagerImplementation
/// @notice Implementation of the ConfigManager contract
contract ConfigManagerImplementation is ConfigManager {
    constructor(address _configManager) ConfigManager(_configManager) {}
}
