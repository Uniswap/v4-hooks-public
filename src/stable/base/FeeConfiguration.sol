// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import {IFeeConfiguration, FeeConfig, HistoricalFeeData} from "../interfaces/IFeeConfiguration.sol";
import {ConfigManager} from "./ConfigManager.sol";
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
    /// @dev Should be called in a multicall with resetHistoricalFeeData()
    function updateDecayFactor(PoolId poolId, uint256 decayFactor) external onlyConfigManager {
        _validateDecayFactor(decayFactor);
        feeConfig[poolId].decayFactor = decayFactor;
        emit DecayFactorUpdated(poolId, decayFactor);
    }

    /// @inheritdoc IFeeConfiguration
    /// @dev Should be called in a multicall with resetHistoricalFeeData()
    function updateOptimalFeeRate(PoolId poolId, uint24 optimalFeeRate) external onlyConfigManager {
        _validateOptimalFeeRate(optimalFeeRate);
        feeConfig[poolId].optimalFeeRate = optimalFeeRate;
        emit OptimalFeeRateUpdated(poolId, optimalFeeRate);
    }

    /// @inheritdoc IFeeConfiguration
    /// @dev Should be called in a multicall with resetHistoricalFeeData()
    function updateReferenceSqrtPrice(PoolId poolId, uint160 referenceSqrtPriceX96) external onlyConfigManager {
        _validateReferenceSqrtPrice(referenceSqrtPriceX96);
        feeConfig[poolId].referenceSqrtPriceX96 = referenceSqrtPriceX96;
        emit ReferenceSqrtPriceUpdated(poolId, referenceSqrtPriceX96);
    }

    /// @inheritdoc IFeeConfiguration
    function resetHistoricalFeeData(PoolId poolId) external onlyConfigManager {
        _resetHistoricalFeeData(poolId);
        emit HistoricalFeeDataReset(poolId);
    }

    /// @notice Internal helper to initialize fee configuration and historical data
    /// @param poolId The pool ID to initialize
    /// @param feeConfiguration The fee configuration to set
    function _validateFeeConfig(PoolId poolId, FeeConfig calldata feeConfiguration) internal {
        _validateDecayFactor(feeConfiguration.decayFactor);
        _validateOptimalFeeRate(feeConfiguration.optimalFeeRate);
        _validateReferenceSqrtPrice(feeConfiguration.referenceSqrtPriceX96);
        _resetHistoricalFeeData(poolId);
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

    /// @notice Internal helper to reset historical fee data
    /// @param poolId The pool ID to reset historical data for
    function _resetHistoricalFeeData(PoolId poolId) internal {
        historicalFeeData[poolId].previousFee = 1e12 + 1; // TODO: make constant
        historicalFeeData[poolId].blockNumber = block.number;
    }
}
