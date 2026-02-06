// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {FeeConfiguration} from "../base/FeeConfiguration.sol";
import {FeeConfig, FeeState} from "../interfaces/IFeeConfiguration.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";

/// @title FeeConfigurationImplementation
/// @notice Implementation of the FeeConfiguration contract
contract FeeConfigurationImplementation is FeeConfiguration {
    constructor(address _configManager) FeeConfiguration(_configManager) {}

    /// @notice Test helper to set fee state directly
    function setFeeState(PoolId poolId, FeeState calldata _feeState) external {
        feeState[poolId] = _feeState;
    }
}
