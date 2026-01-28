// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import {IFeeConfiguration, FeeConfig, FeeState} from "../interfaces/IFeeConfiguration.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";

/// @title FeeConfiguration
/// @notice Abstract contract that implements the IFeeConfiguration interface
abstract contract FeeConfiguration is IFeeConfiguration {
    /// @notice The address of the config manager
    /// @dev The config manager is the address that can update the fee configuration for a pool
    address public configManager;

    /// @notice The fee config for each pool
    mapping(PoolId => FeeConfig) public feeConfig;
    /// @notice The fee state for each pool
    mapping(PoolId => FeeState) public feeState;

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
    function updateFeeConfig(PoolId poolId_, FeeConfig calldata feeConfig_) external onlyConfigManager {
        _updateFeeConfig(poolId_, feeConfig_);
        emit FeeConfigUpdated(poolId_, feeConfig_);
    }

    /// @notice Internal helper to initialize fee config and fee state
    /// @param _poolId The pool ID to initialize
    /// @param _feeConfig The fee config to set
    function _updateFeeConfig(PoolId _poolId, FeeConfig calldata _feeConfig) internal {
        _validateKAndLogK(_feeConfig.k, _feeConfig.logK);
        _validateOptimalFeeRate(_feeConfig.optimalFeeRate);
        _validateReferenceSqrtPrice(_feeConfig.referenceSqrtPriceX96);
        _resetFeeState(_poolId);
        feeConfig[_poolId] = _feeConfig;
    }

    /// @notice Validate the decay factor
    /// @param _k The k value to validate
    /// @param _logK The logK value to validate
    function _validateKAndLogK(uint256 _k, uint256 _logK) internal pure {
        // TODO: set bounds on decay factor
        // revert InvalidKAndLogK(_k, _logK);
    }

    /// @notice Validate the optimal fee rate
    /// @param _optimalFeeRate The optimal fee rate to validate
    function _validateOptimalFeeRate(uint256 _optimalFeeRate) internal pure {
        // TODO: set bounds on optimal fee spread
        // revert InvalidOptimalFeeRate(_optimalFeeRate);
    }

    /// @notice Validate the reference sqrt price
    /// @param _referenceSqrtPriceX96 The reference sqrt price to validate
    function _validateReferenceSqrtPrice(uint160 _referenceSqrtPriceX96) internal pure {
        // TODO: set bounds on reference sqrt price
        // should they be close to stable price?
        // revert InvalidReferenceSqrtPrice(_referenceSqrtPriceX96);
    }

    /// @notice Internal helper to reset fee state
    /// @param _poolId The pool ID to reset fee state for
    function _resetFeeState(PoolId _poolId) internal {
        feeState[_poolId].previousFee = 1e12 + 1; // TODO: make constant
        feeState[_poolId].blockNumber = block.number;
    }
}
