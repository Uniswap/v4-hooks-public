// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {BaseHook} from "@uniswap/v4-periphery/src/utils/BaseHook.sol";

/// @title IAggregatorHook
/// @notice Interface for the AggregatorHook contract. An implemented aggregator hook should be able to use liquidity from external sources
interface IAggregatorHook {
    error InsufficientLiquidity();
    error UnspecifiedAmountExceeded();
    error PoolDoesNotExist();

    event AggregatorPoolRegistered(PoolId indexed poolId);

    /// @notice Quotes amount of unspecified side for a given amount of specified side
    /// @param zeroToOne Whether the swap is from token0 to token1 or from token1 to token0
    /// @param amountSpecified The amount of tokens in or out (negative for exact-in, positive for exact-out)
    /// @return amountUnspecified amount of unspecified side (always positive)
    /// @dev This function is meant to be called as a view function even though it is not one. This is because the swap
    /// might be simulated but not finalized
    function quote(bool zeroToOne, int256 amountSpecified, PoolId poolId)
        external
        payable
        returns (uint256 amountUnspecified);

    /// @notice Returns the pseudo TVL: the amount of the UniswapV4 pool's tokens locked in the aggregated pool
    /// @param poolId The pool ID of the UniswapV4 pool
    /// @return amount0 The amount of token0 in the aggregated pool
    /// @return amount1 The amount of token1 in the aggregated pool
    function pseudoTotalValueLocked(PoolId poolId) external view returns (uint256 amount0, uint256 amount1);
}
