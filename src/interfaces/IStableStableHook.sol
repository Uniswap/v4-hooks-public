// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

/// @notice The fee configuration for each pool
struct FeeConfig {
    uint256 decayFactor;
    uint256 optimalFeeSpread;
    uint160 referenceSqrtPrice;
}

/// @notice The historical data for each pool
struct HistoricalData {
    uint24 previousFee;
    uint160 previousSqrtAmmPrice;
    uint256 blockNumber;
}

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

    /// @notice Error thrown when optimal fee spread is too high
    error OptimalFeeSpreadTooHigh(uint256 optimalFeeSpread);

    /// @notice Error thrown when reference sqrt price is invalid
    /// @param invalidSqrtPrice The invalid reference sqrt price
    error InvalidReferenceSqrtPrice(uint160 invalidSqrtPrice);

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
    /// @param poolKey The PoolKey of the pool to update the optimal fee spread for
    /// @param optimalFeeSpread The new optimal fee spread
    function updateOptimalFeeSpread(PoolKey calldata poolKey, uint256 optimalFeeSpread) external;

    /// @notice Update the reference sqrt price for a pool
    /// @param poolKey The PoolKey of the pool to update the reference sqrt price for
    /// @param referenceSqrtPrice The new reference sqrt price
    function updateReferenceSqrtPrice(PoolKey calldata poolKey, uint160 referenceSqrtPrice) external;

    /// @notice Clear the historical data for a pool
    /// @param poolKey The PoolKey of the pool to clear the historical data for
    function clearHistoricalData(PoolKey calldata poolKey) external;
}
