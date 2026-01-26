// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {FeeConfig} from "../interfaces/IFeeConfiguration.sol";

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

    /// @notice Event emitted when a pool is initialized
    /// @param poolKey The PoolKey of the pool
    /// @param sqrtPriceX96 The initial starting price of the pool, expressed as a sqrtPriceX96
    /// @param feeConfig The fee configuration for the pool
    event PoolInitialized(PoolKey indexed poolKey, uint160 sqrtPriceX96, FeeConfig feeConfig);

    /// @notice Initialize a Uniswap v4 pool
    /// @param poolKey The PoolKey of the pool to initialize
    /// @param sqrtPriceX96 The initial starting price of the pool, expressed as a sqrtPriceX96
    /// @param feeConfig The fee configuration for the pool
    /// @return tick The current tick of the pool
    function initializePool(PoolKey calldata poolKey, uint160 sqrtPriceX96, FeeConfig calldata feeConfig)
        external
        returns (int24 tick);
}
