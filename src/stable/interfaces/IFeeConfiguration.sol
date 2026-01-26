// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";

struct FeeConfig {
    uint256 k;
    uint256 logK;
    uint24 optimalFeeRate;
    uint160 referenceSqrtPriceX96;
}

struct HistoricalFeeData {
    uint256 previousFee;
    uint160 previousSqrtAmmPriceX96;
    uint256 blockNumber;
}

/// @notice Interface for the FeeConfiguration
interface IFeeConfiguration {
    /// @notice Error thrown when decay factor is invalid
    error InvalidDecayFactor(uint256 decayFactor);

    /// @notice Error thrown when optimal fee rate is too high
    error OptimalFeeRateTooHigh(uint256 optimalFeeRate);

    /// @notice Error thrown when reference sqrt price is invalid
    /// @param invalidSqrtPrice The invalid reference sqrt price
    error InvalidReferenceSqrtPrice(uint160 invalidSqrtPrice);

    /// @notice Event emitted when the decay factor is updated
    /// @param poolId The ID of the pool
    /// @param k The new k
    /// @param logK The new logK
    event DecayFactorUpdated(PoolId indexed poolId, uint256 k, uint256 logK);

    /// @notice Event emitted when the optimal fee rate is updated
    /// @param poolId The ID of the pool
    /// @param optimalFeeRate The new optimal fee rate
    event OptimalFeeRateUpdated(PoolId indexed poolId, uint256 optimalFeeRate);

    /// @notice Event emitted when the reference sqrt price is updated
    /// @param poolId The ID of the pool
    /// @param referenceSqrtPrice The new reference sqrt price
    event ReferenceSqrtPriceUpdated(PoolId indexed poolId, uint160 referenceSqrtPrice);

    /// @notice Event emitted when the historical fee data is reset
    /// @param poolId The ID of the pool
    event HistoricalFeeDataReset(PoolId indexed poolId);

    /// @notice Update the decay factor for a pool
    /// @param poolId The ID of the pool to update the decay factor for
    /// @param k The new k
    /// @param logK The new logK
    function updateDecayFactor(PoolId poolId, uint256 k, uint256 logK) external;

    /// @notice Update the optimal fee spread for a pool
    /// @param poolId The ID of the pool to update the optimal fee rate for
    /// @param optimalFeeRate The new optimal fee rate
    function updateOptimalFeeRate(PoolId poolId, uint24 optimalFeeRate) external;

    /// @notice Update the reference sqrt price for a pool
    /// @param poolId The ID of the pool to update the reference sqrt price for
    /// @param referenceSqrtPriceX96 The new reference sqrt price
    function updateReferenceSqrtPrice(PoolId poolId, uint160 referenceSqrtPriceX96) external;

    /// @notice Reset the historical data for a pool
    /// @param poolId The ID of the pool to reset the historical data for
    function resetHistoricalFeeData(PoolId poolId) external;
}
