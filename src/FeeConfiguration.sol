// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import {IFeeConfiguration} from "./interfaces/IFeeConfiguration.sol";
import {FeeController} from "./FeeController.sol";
import {FeeConfig} from "./types/FeeConfig.sol";
import {HistoricalFeeData} from "./types/HistoricalFeeData.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";

/// @title FeeConfiguration
/// @notice Abstract contract that implements the IFeeConfiguration interface
abstract contract FeeConfiguration is FeeController, IFeeConfiguration {
    /// @notice The fee configuration for each pool
    mapping(PoolId => FeeConfig) public feeConfig;
    /// @notice The historical data for each pool
    mapping(PoolId => HistoricalFeeData) public historicalFeeData;

    constructor(address _feeController) FeeController(_feeController) {}

    /// @inheritdoc IFeeConfiguration
    /// @dev Should be called in a multicall with clearHistoricalFeeData()
    function updateDecayFactor(PoolKey calldata poolKey, uint256 decayFactor) external onlyFeeController {
        _validateDecayFactor(decayFactor);
        feeConfig[poolKey.toId()].decayFactor = decayFactor;
        emit DecayFactorUpdated(poolKey, decayFactor);
    }

    /// @inheritdoc IFeeConfiguration
    /// @dev Should be called in a multicall with clearHistoricalFeeData()
    function updateOptimalFeeRate(PoolKey calldata poolKey, uint24 optimalFeeRate) external onlyFeeController {
        _validateOptimalFeeRate(optimalFeeRate);
        feeConfig[poolKey.toId()].optimalFeeRate = optimalFeeRate;
        emit OptimalFeeRateUpdated(poolKey, optimalFeeRate);
    }

    /// @inheritdoc IFeeConfiguration
    /// @dev Should be called in a multicall with clearHistoricalFeeData()
    function updateReferenceSqrtPrice(PoolKey calldata poolKey, uint160 referenceSqrtPriceX96)
        external
        onlyFeeController
    {
        _validateReferenceSqrtPrice(referenceSqrtPriceX96);
        feeConfig[poolKey.toId()].referenceSqrtPriceX96 = referenceSqrtPriceX96;
        emit ReferenceSqrtPriceUpdated(poolKey, referenceSqrtPriceX96);
    }

    /// @inheritdoc IFeeConfiguration
    function clearHistoricalFeeData(PoolKey calldata poolKey) external onlyFeeController {
        historicalFeeData[poolKey.toId()].previousFee = 0;
        historicalFeeData[poolKey.toId()].blockNumber = block.number;
        emit HistoricalFeeDataCleared(poolKey);
    }

    function _validateDecayFactor(uint256 _decayFactor) internal pure {
        // TODO: set bounds on decay factor
    }

    function _validateOptimalFeeRate(uint256 _optimalFeeRate) internal pure {
        // TODO: set bounds on optimal fee spread
    }

    function _validateReferenceSqrtPrice(uint160 _referenceSqrtPriceX96) internal pure {
        // TODO: set bounds on reference sqrt price
        // should they be close to stable price?
    }

    function _getFeeConfig(PoolKey calldata poolKey) internal virtual returns (FeeConfig storage);

    function _getHistoricalFeeData(PoolKey calldata poolKey) internal virtual returns (HistoricalFeeData storage);
}
