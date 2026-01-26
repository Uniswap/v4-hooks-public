// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import {FeeConfiguration} from "../base/FeeConfiguration.sol";
import {FeeConfig, HistoricalFeeData} from "../interfaces/IFeeConfiguration.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

/// @title FeeConfigurationImplementation
/// @notice Implementation of the FeeConfiguration contract
contract FeeConfigurationImplementation is FeeConfiguration {
    constructor(address _configManager) FeeConfiguration(_configManager) {}
}
