// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import {FeeConfiguration} from "../FeeConfiguration.sol";
import {FeeConfig} from "../types/FeeConfig.sol";
import {HistoricalFeeData} from "../types/HistoricalFeeData.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";

/// @title FeeConfigurationImplementation
/// @notice Implementation of the FeeConfiguration contract
contract FeeConfigurationImplementation is FeeConfiguration {
    constructor(address _feeController) FeeConfiguration(_feeController) {}

    function _getFeeConfig(PoolKey calldata poolKey) internal view override returns (FeeConfig storage) {
        return feeConfig[poolKey.toId()];
    }

    function _getHistoricalFeeData(PoolKey calldata poolKey)
        internal
        view
        override
        returns (HistoricalFeeData storage)
    {
        return historicalFeeData[poolKey.toId()];
    }
}
