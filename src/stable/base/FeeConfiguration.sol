// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import {IFeeConfiguration, FeeConfig, HistoricalFeeData} from "../interfaces/IFeeConfiguration.sol";
import {ConfigManager} from "./ConfigManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";

/// @title FeeConfiguration
/// @notice Abstract contract that implements the IFeeConfiguration interface
abstract contract FeeConfiguration is ConfigManager, IFeeConfiguration {
    uint256 internal constant ONE = 1e12;
    uint256 internal constant UNDEFINED_FLEXIBLE_FEE = ONE + 1;

    /// @notice The fee configuration for each pool
    mapping(PoolId => FeeConfig) public feeConfig;
    /// @notice The historical data for each pool
    mapping(PoolId => HistoricalFeeData) public historicalFeeData;

    constructor(address _configManager) ConfigManager(_configManager) {}

    /// @inheritdoc IFeeConfiguration
    /// @dev Should be called in a multicall with clearHistoricalFeeData()
    function updateDecayFactor(PoolKey calldata poolKey, uint256 k, uint256 logK) external onlyConfigManager {
        _validateDecayFactor(k, logK);
        feeConfig[poolKey.toId()].k = k;
        feeConfig[poolKey.toId()].logK = logK;
        emit DecayFactorUpdated(poolKey, k, logK);
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
    function resetHistoricalFeeData(PoolKey calldata poolKey) external onlyConfigManager {
        _resetHistoricalFeeData(poolKey.toId());
        emit HistoricalFeeDataReset(poolKey);
    }

    /// @notice Internal helper to initialize fee configuration and historical data
    /// @param poolId The pool ID to initialize
    /// @param feeConfiguration The fee configuration to set
    function _initializeFeeConfig(PoolId poolId, FeeConfig calldata feeConfiguration) internal {
        _validateDecayFactor(feeConfiguration.k, feeConfiguration.logK);
        _validateOptimalFeeRate(feeConfiguration.optimalFeeRate);
        _validateReferenceSqrtPrice(feeConfiguration.referenceSqrtPriceX96);

        feeConfig[poolId] = feeConfiguration;
        _resetHistoricalFeeData(poolId);
    }

    /// @notice Internal helper to reset historical fee data to default state
    /// @param poolId The pool ID to reset historical data for
    function _resetHistoricalFeeData(PoolId poolId) internal {
        historicalFeeData[poolId].previousFee = UNDEFINED_FLEXIBLE_FEE;
        historicalFeeData[poolId].blockNumber = block.number;
    }

    /// @notice Validate the decay factor
    /// @param _k The k to validate
    /// @param _logK The logK to validate
    function _validateDecayFactor(uint256 _k, uint256 _logK) internal pure {
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
}
