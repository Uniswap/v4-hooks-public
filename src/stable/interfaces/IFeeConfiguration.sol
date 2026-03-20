// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";

struct FeeConfig {
    uint24 k; // Decay factor per block in Q24 format (e.g., 0.99 in Q24 means fee retains 99% of its value each block)
    uint24 logK; // Precomputed -ln(k) >> 40; used for > 4 blocks decay: k^n = exp(-logK * n)
    uint24 optimalFeeE6; // Fee rate defining optimal range width in PRICE space (not sqrt price), 1e6 precision
    uint8 targetMultiplier; // Multiplier for target fee: targetFee = farBoundaryFee - closeBoundaryFee * targetMultiplier / 100. Must be 0-100.
    uint160 referenceSqrtPriceX96; // Reference center point in sqrt Q96 format
}

// Fee state snapshot, only updated on the first swap in a new block
struct FeeState {
    uint40 decayingFeeE12; // Decaying fee in 1e12 precision, or UNDEFINED_DECAYING_FEE_E12 if inside optimal range
    uint160 sqrtAmmPriceX96; // AMM sqrt price at the start of the most recently swapped block; used as cached price for same-block swaps and cross-block price movement detection (0 when the pool is initialized or reset)
    uint40 blockNumber; // Block number of the most recent swap (0 when the pool is initialized or reset); used to detect same-block swaps and compute blocks elapsed for decay
}

/// @notice Interface for the FeeConfiguration
interface IFeeConfiguration {
    /// @notice Error thrown when the caller is not the config manager
    /// @param caller The invalid address attempting to update the pool fee data
    error NotConfigManager(address caller);

    /// @notice Error thrown when k and logK are invalid
    /// @param k The invalid k value
    /// @param logK The invalid logK value
    error InvalidKAndLogK(uint256 k, uint256 logK);

    /// @notice Error thrown when optimal fee is invalid
    /// @param optimalFeeE6 The invalid optimal fee
    error InvalidOptimalFeeE6(uint256 optimalFeeE6);

    /// @notice Error thrown when reference sqrt price is invalid
    /// @param invalidSqrtPrice The invalid reference sqrt price
    error InvalidReferenceSqrtPriceX96(uint256 invalidSqrtPrice);

    /// @notice Error thrown when target multiplier is invalid (must be 0-100)
    /// @param targetMultiplier The invalid target multiplier
    error InvalidTargetMultiplier(uint256 targetMultiplier);

    /// @notice Event emitted when the config manager is updated
    /// @param configManager The new config manager
    event ConfigManagerUpdated(address indexed configManager);

    /// @notice Event emitted when the fee config is updated
    /// @param poolId The ID of the pool
    /// @param feeConfig The new fee config
    event FeeConfigUpdated(PoolId indexed poolId, FeeConfig feeConfig);

    /// @notice Set the config manager
    /// @param configManager The address of the new config manager
    function setConfigManager(address configManager) external;

    /// @notice Update the fee config for a pool
    /// @param poolId The ID of the pool
    /// @param feeConfig The new fee config
    function updateFeeConfig(PoolId poolId, FeeConfig calldata feeConfig) external;
}
