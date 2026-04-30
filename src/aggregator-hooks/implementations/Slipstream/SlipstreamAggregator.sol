// SPDX-License-Identifier: MIT
pragma solidity 0.8.29;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {IUniswapV3Pool} from "../UniswapV3/interfaces/IUniswapV3Pool.sol";
import {UniswapV3Aggregator} from "../UniswapV3/UniswapV3Aggregator.sol";
import {ISlipstreamFactory} from "./interfaces/ISlipstreamFactory.sol";

/// @title SlipstreamAggregator
/// @notice Singleton hook aggregating Slipstream-style concentrated liquidity (tickSpacing-keyed factory lookup)
contract SlipstreamAggregator is UniswapV3Aggregator {
    /// @param manager PoolManager
    /// @param slipstreamFactory Slipstream pool factory (tickSpacing `getPool`)
    constructor(IPoolManager manager, address slipstreamFactory)
        UniswapV3Aggregator(manager, slipstreamFactory, "SlipstreamAggregator v1.0")
    {}

    /// @inheritdoc UniswapV3Aggregator
    /// @dev Slipstream pools are keyed by tickSpacing, not fee tier.
    function _resolveExternalPool(address token0, address token1, PoolKey calldata key)
        internal
        view
        override
        returns (address pool)
    {
        pool = ISlipstreamFactory(factory).getPool(token0, token1, key.tickSpacing);
        require(IUniswapV3Pool(pool).tickSpacing() == key.tickSpacing);
    }
}
