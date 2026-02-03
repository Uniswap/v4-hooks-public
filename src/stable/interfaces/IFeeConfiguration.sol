// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";

struct FeeConfig {
    uint256 k; // Decay rate per block; controls how fast fees decrease toward target
    uint256 logK; // Used for efficient decay calculation over many blocks
    uint24 optimalFeeRateE6; // Optimal rate width in 1e6 precision; inside = consistent buy/sell prices, outside = flexible
    uint160 referenceSqrtPriceX96; // Reference sqrt price; optimal rate centered around this
}

struct FeeState {
    uint40 previousFeeE12; // Last flexible fee charged in 1e12 precision; used for exponential decay calculation
    uint160 previousSqrtAmmPriceX96; // AMM sqrt price at last swap; used to detect price movement direction
    uint256 blockNumber; // Block when fee was last updated; determines decay based on blocks elapsed
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

    /// @notice Error thrown when optimal fee rate is invalid
    /// @param optimalFeeRateE6 The invalid optimal fee rate
    error InvalidOptimalFeeRateE6(uint24 optimalFeeRateE6);

    /// @notice Error thrown when reference sqrt price is invalid
    /// @param invalidSqrtPrice The invalid reference sqrt price
    error InvalidReferenceSqrtPriceX96(uint160 invalidSqrtPrice);

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
