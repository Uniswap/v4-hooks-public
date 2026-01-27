// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import {IFeeConfiguration, FeeConfig, HistoricalFeeData} from "../interfaces/IFeeConfiguration.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";

/// @title FeeConfiguration
/// @notice Abstract contract that implements the IFeeConfiguration interface
abstract contract FeeConfiguration is IFeeConfiguration {
    /// @notice The address of the config manager
    /// @dev The config manager is the address that can update the fee configuration for a pool
    address public configManager;

    /// @notice The fee configuration for each pool
    mapping(PoolId => FeeConfig) public feeConfig;
    /// @notice The historical data for each pool
    mapping(PoolId => HistoricalFeeData) public historicalFeeData;

    constructor(address _configManager) {
        configManager = _configManager;
    }

    /// @notice Modifier to only allow calls from the config manager
    /// @dev This modifier is used to prevent unauthorized updates to the fee configuration per pool
    modifier onlyConfigManager() {
        if (msg.sender != configManager) revert NotConfigManager(msg.sender);
        _;
    }

    /// @inheritdoc IFeeConfiguration
    function setConfigManager(address configManager_) external onlyConfigManager {
        // Setting the config manager to address(0) disables further updates to the fee configuration
        configManager = configManager_;
        emit ConfigManagerUpdated(configManager_);
    }

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
    function updateReferenceSqrtPriceX96(PoolId poolId, uint160 referenceSqrtPriceX96) external onlyConfigManager {
        _validateReferenceSqrtPrice(referenceSqrtPriceX96);
        feeConfig[poolId].referenceSqrtPriceX96 = referenceSqrtPriceX96;
        emit ReferenceSqrtPriceX96Updated(poolId, referenceSqrtPriceX96);
    }

    /// @inheritdoc IFeeConfiguration
    function resetHistoricalFeeData(PoolId poolId) external onlyConfigManager {
        _resetHistoricalFeeData(poolId);
        emit HistoricalFeeDataReset(poolId);
    }

    /// @notice Internal helper to initialize fee configuration and historical data
    /// @param _poolId The pool ID to initialize
    /// @param _feeConfiguration The fee configuration to set
    function _validateFeeConfig(PoolId _poolId, FeeConfig calldata _feeConfiguration) internal {
        _validateDecayFactor(_feeConfiguration.decayFactor);
        _validateOptimalFeeRate(_feeConfiguration.optimalFeeRate);
        _validateReferenceSqrtPrice(_feeConfiguration.referenceSqrtPriceX96);
        _resetHistoricalFeeData(_poolId);
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
    /// @param _poolId The pool ID to reset historical data for
    function _resetHistoricalFeeData(PoolId _poolId) internal {
        historicalFeeData[_poolId].previousFee = 1e12 + 1; // TODO: make constant
        historicalFeeData[_poolId].blockNumber = block.number;
    }
}
