// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import {IFeeConfiguration, FeeConfig, HistoricalFeeData} from "../interfaces/IFeeConfiguration.sol";
import {ConfigManager} from "./ConfigManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";

/// @title FeeConfiguration
/// @notice Abstract contract that implements the IFeeConfiguration interface
abstract contract FeeConfiguration is ConfigManager, IFeeConfiguration {
    /// @notice The fee configuration for each pool
    mapping(PoolId => FeeConfig) public feeConfig;
    /// @notice The historical data for each pool
    mapping(PoolId => HistoricalFeeData) public historicalFeeData;

    constructor(address _configManager) ConfigManager(_configManager) {}

    /// @inheritdoc IFeeConfiguration
    /// @dev Should be called in a multicall with clearHistoricalFeeData()
    function updateDecayFactor(PoolKey calldata poolKey, uint256 decayFactor) external onlyConfigManager {
        _validateDecayFactor(decayFactor);
        feeConfig[poolKey.toId()].decayFactor = decayFactor;
        emit DecayFactorUpdated(poolKey, decayFactor);
    }

    /// @inheritdoc IFeeConfiguration
    /// @dev Should be called in a multicall with clearHistoricalFeeData()
    function updateOptimalFeeRate(PoolKey calldata poolKey, uint24 optimalFeeRate) external onlyConfigManager {
        _validateOptimalFeeRate(optimalFeeRate);
        feeConfig[poolKey.toId()].optimalFeeRate = optimalFeeRate;
        emit OptimalFeeRateUpdated(poolKey, optimalFeeRate);
    }

    /// @inheritdoc IFeeConfiguration
    /// @dev Should be called in a multicall with clearHistoricalFeeData()
    function updateReferenceSqrtPrice(PoolKey calldata poolKey, uint160 referenceSqrtPriceX96)
        external
        onlyConfigManager
    {
        _validateReferenceSqrtPrice(referenceSqrtPriceX96);
        feeConfig[poolKey.toId()].referenceSqrtPriceX96 = referenceSqrtPriceX96;
        emit ReferenceSqrtPriceUpdated(poolKey, referenceSqrtPriceX96);
    }

    /// @inheritdoc IFeeConfiguration
    function clearHistoricalFeeData(PoolKey calldata poolKey) external onlyConfigManager {
        historicalFeeData[poolKey.toId()].previousFee = 1e12 + 1; // TODO: make constant
        historicalFeeData[poolKey.toId()].blockNumber = block.number;
        emit HistoricalFeeDataCleared(poolKey);
    }

    /// @notice Validate the decay factor
    /// @param _decayFactor The decay factor to validate
    function _validateDecayFactor(uint256 _decayFactor) internal pure {
        // TODO: set bounds on decay factor
    }

    /// @notice Validate the optimal fee rate
    /// @param _optimalFeeRate The optimal fee rate to validate
    function _validateOptimalFeeRate(uint256 _optimalFeeRate) internal pure {
        // TODO: set bounds on optimal fee spread
    }

    /// @notice Validate the reference sqrt price
    /// @param _referenceSqrtPriceX96 The reference sqrt price to validate
    function _validateReferenceSqrtPrice(uint160 _referenceSqrtPriceX96) internal pure {
        // TODO: set bounds on reference sqrt price
        // should they be close to stable price?
    }

    /// @notice Get the fee configuration for a pool
    /// @param poolKey The PoolKey of the pool
    /// @return The fee configuration for the pool
    function _getFeeConfig(PoolKey calldata poolKey) internal virtual returns (FeeConfig storage);

    /// @notice Get the historical fee data for a pool
    /// @param poolKey The PoolKey of the pool
    /// @return The historical fee data for the pool
    function _getHistoricalFeeData(PoolKey calldata poolKey) internal virtual returns (HistoricalFeeData storage);
}
