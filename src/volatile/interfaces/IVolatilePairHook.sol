// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {VolatileFeeConfig} from "./IVolatileFeeConfiguration.sol";
import {IDynamicFeeHook} from "../../interfaces/IDynamicFeeHook.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";

/// @notice Interface for VolatilePairHook
interface IVolatilePairHook is IDynamicFeeHook {
    /// @notice Thrown when poolKey.fee is not the dynamic-fee sentinel
    /// @param lpFee The fee that was provided
    error MustUseDynamicFee(uint24 lpFee);

    /// @notice Thrown when poolKey.hooks is not this contract
    /// @param hookAddress The address that was provided
    error InvalidHookAddress(address hookAddress);

    /// @notice Thrown when the implementation is deployed with a max temp fee block gap of 0
    error MaxTempFeeBlockGapCannotBeZero();

    /// @notice Emitted when a pool is initialized through this hook
    /// @param poolKey The pool that was initialized
    /// @param sqrtPriceX96 The initial sqrt price
    /// @param feeConfig The fee config applied to the pool
    event PoolInitialized(PoolKey indexed poolKey, uint160 sqrtPriceX96, VolatileFeeConfig feeConfig);

    /// @notice Emitted on the first swap of each block, when the pool's top-of-block fee state is written
    /// @param poolId The pool whose state was updated
    /// @param blockNumber Block the state applies to
    /// @param sqrtPriceTopX96 Block-open sqrt price
    /// @param askPermFeeE6 Permanent ask-side fee
    /// @param bidPermFeeE6 Permanent bid-side fee (restingSpreadE6 - askPermFeeE6)
    /// @param tempFeeE6 One-block backrun charge on the side named by tempOnBid
    /// @param tempOnBid True if tempFeeE6 is on the bid side, false if on the ask side
    event FeeStateUpdated(
        PoolId indexed poolId,
        uint40 blockNumber,
        uint160 sqrtPriceTopX96,
        uint24 askPermFeeE6,
        uint24 bidPermFeeE6,
        uint24 tempFeeE6,
        bool tempOnBid
    );

    /// @notice Initializes a pool on the PoolManager and sets its fee config.
    /// @param poolKey Pool key; fee must be the dynamic-fee sentinel and hooks must be this contract
    /// @param sqrtPriceX96 Initial sqrt price
    /// @param feeConfig Fee config to seed for the pool
    /// @return tick Resulting tick
    function initializePool(PoolKey calldata poolKey, uint160 sqrtPriceX96, VolatileFeeConfig calldata feeConfig)
        external
        returns (int24 tick);

    /// @notice Most blocks after the previous block open at which a block's temp fee still applies.
    /// @dev Past this gap the temp fee is 0 and the permanent fee still steps. Measured in blocks
    /// @return The max block gap
    function maxTempFeeBlockGap() external view returns (uint256);
}
