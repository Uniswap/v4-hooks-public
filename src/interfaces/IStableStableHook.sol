// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {FeeConfig} from "../types/FeeConfig.sol";

/// @notice Interface for the StableStableHook
interface IStableStableHook {
    /// @notice Error thrown when the pool trying to be initialized is not using a dynamic fee
    /// @param lpFee The LP fee that was used to try to initialize the pool
    error MustUseDynamicFee(uint24 lpFee);

    /// @notice Error thrown when the hook address is not address(this)
    /// @param hookAddress The invalid hook address
    error InvalidHookAddress(address hookAddress);

    /// @notice Error thrown when the caller of `initializePool` is not address(this)
    /// @param caller The invalid address attempting to initialize the pool
    error InvalidInitializer(address caller);

    /// @notice Error thrown when the caller is not the fee controller
    /// @param caller The invalid address attempting to update the pool fee data
    error NotFeeController(address caller);

    /// @notice Error thrown when decay factor is invalid
    error InvalidDecayFactor(uint256 decayFactor);

    /// @notice Error thrown when optimal fee rate is too high
    error OptimalFeeRateTooHigh(uint256 optimalFeeRate);

    /// @notice Error thrown when reference sqrt price is invalid
    /// @param invalidSqrtPrice The invalid reference sqrt price
    error InvalidReferenceSqrtPrice(uint160 invalidSqrtPrice);

    /// @notice Event emitted when a pool is initialized
    /// @param poolKey The PoolKey of the pool
    /// @param sqrtPriceX96 The initial starting price of the pool, expressed as a sqrtPriceX96
    /// @param feeConfig The fee configuration for the pool
    event PoolInitialized(PoolKey indexed poolKey, uint160 sqrtPriceX96, FeeConfig feeConfig);

    /// @notice Event emitted when the decay factor is updated
    /// @param poolKey The PoolKey of the pool
    /// @param decayFactor The new decay factor
    event DecayFactorUpdated(PoolKey indexed poolKey, uint256 decayFactor);

    /// @notice Event emitted when the optimal fee rate is updated
    /// @param poolKey The PoolKey of the pool
    /// @param optimalFeeRate The new optimal fee rate
    event OptimalFeeRateUpdated(PoolKey indexed poolKey, uint256 optimalFeeRate);

    /// @notice Event emitted when the reference sqrt price is updated
    /// @param poolKey The PoolKey of the pool
    /// @param referenceSqrtPrice The new reference sqrt price
    event ReferenceSqrtPriceUpdated(PoolKey indexed poolKey, uint160 referenceSqrtPrice);

    /// @notice Event emitted when the historical fee data is cleared
    /// @param poolKey The PoolKey of the pool
    event HistoricalFeeDataCleared(PoolKey indexed poolKey);

    /// @notice Initialize a Uniswap v4 pool
    /// @param poolKey The PoolKey of the pool to initialize
    /// @param sqrtPriceX96 The initial starting price of the pool, expressed as a sqrtPriceX96
    /// @param feeConfig The fee configuration for the pool
    /// @return tick The current tick of the pool
    function initializePool(PoolKey calldata poolKey, uint160 sqrtPriceX96, FeeConfig calldata feeConfig)
        external
        returns (int24 tick);

    /// @notice Update the decay factor for a pool
    /// @param poolKey The PoolKey of the pool to update the decay factor for
    /// @param decayFactor The new decay factor
    function updateDecayFactor(PoolKey calldata poolKey, uint256 decayFactor) external;

    /// @notice Update the optimal fee spread for a pool
    /// @param poolKey The PoolKey of the pool to update the optimal fee rate for
    /// @param optimalFeeRate The new optimal fee rate
    function updateOptimalFeeRate(PoolKey calldata poolKey, uint256 optimalFeeRate) external;

    /// @notice Update the reference sqrt price for a pool
    /// @param poolKey The PoolKey of the pool to update the reference sqrt price for
    /// @param referenceSqrtPrice The new reference sqrt price
    function updateReferenceSqrtPrice(PoolKey calldata poolKey, uint160 referenceSqrtPrice) external;

    /// @notice Clear the historical data for a pool
    /// @param poolKey The PoolKey of the pool to clear the historical data for
    function clearHistoricalFeeData(PoolKey calldata poolKey) external;
}
