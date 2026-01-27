// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";

struct FeeConfig {
    uint256 decayFactor;
    uint24 optimalFeeRate;
    uint160 referenceSqrtPriceX96;
}

struct HistoricalFeeData {
    uint40 previousFee;
    uint160 previousSqrtAmmPriceX96;
    uint256 blockNumber;
}

/// @notice Interface for the FeeConfiguration
interface IFeeConfiguration {
    /// @notice Error thrown when the caller is not the config manager
    /// @param caller The invalid address attempting to update the pool fee data
    error NotConfigManager(address caller);

    /// @notice Error thrown when decay factor is invalid
    error InvalidDecayFactor(uint256 decayFactor);

    /// @notice Error thrown when optimal fee rate is too high
    error OptimalFeeRateTooHigh(uint256 optimalFeeRate);

    /// @notice Error thrown when reference sqrt price is invalid
    /// @param invalidSqrtPrice The invalid reference sqrt price
    error InvalidReferenceSqrtPrice(uint160 invalidSqrtPrice);

    /// @notice Event emitted when the config manager is updated
    /// @param configManager The new config manager
    event ConfigManagerUpdated(address indexed configManager);

    /// @notice Event emitted when the decay factor is updated
    /// @param poolId The ID of the pool
    /// @param decayFactor The new decay factor
    event DecayFactorUpdated(PoolId indexed poolId, uint256 decayFactor);

    /// @notice Event emitted when the optimal fee rate is updated
    /// @param poolId The ID of the pool
    /// @param optimalFeeRate The new optimal fee rate
    event OptimalFeeRateUpdated(PoolId indexed poolId, uint256 optimalFeeRate);

    /// @notice Event emitted when the reference sqrt price is updated
    /// @param poolId The ID of the pool
    /// @param referenceSqrtPriceX96 The new reference sqrt price
    event ReferenceSqrtPriceX96Updated(PoolId indexed poolId, uint160 referenceSqrtPriceX96);

    /// @notice Event emitted when the historical fee data is reset
    /// @param poolId The ID of the pool
    event HistoricalFeeDataReset(PoolId indexed poolId);

    /// @notice Set the config manager
    /// @param configManager The address of the new config manager
    function setConfigManager(address configManager) external;

    /// @notice Update the decay factor for a pool
    /// @param poolId The ID of the pool to update the decay factor for
    /// @param decayFactor The new decay factor
    function updateDecayFactor(PoolId poolId, uint256 decayFactor) external;

    /// @notice Update the optimal fee spread for a pool
    /// @param poolId The ID of the pool to update the optimal fee rate for
    /// @param optimalFeeRate The new optimal fee rate
    function updateOptimalFeeRate(PoolId poolId, uint24 optimalFeeRate) external;

    /// @notice Update the reference sqrt price for a pool
    /// @param poolId The ID of the pool to update the reference sqrt price for
    /// @param referenceSqrtPriceX96 The new reference sqrt price
    function updateReferenceSqrtPriceX96(PoolId poolId, uint160 referenceSqrtPriceX96) external;

    /// @notice Reset the historical data for a pool
    /// @param poolId The ID of the pool to reset the historical data for
    function resetHistoricalFeeData(PoolId poolId) external;
}
