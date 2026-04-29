// SPDX-License-Identifier: MIT
pragma solidity 0.8.29;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {IUniswapV3Pool} from "../UniswapV3/interfaces/IUniswapV3Pool.sol";
import {UniswapV3Aggregator} from "../UniswapV3/UniswapV3Aggregator.sol";
import {ISlipstreamFactory} from "./interfaces/ISlipstreamFactory.sol";
import {IQuoterV2} from "./interfaces/IQuoterV2.sol";

/// @title SlipstreamAggregator
/// @notice Singleton hook aggregating Slipstream-style concentrated liquidity (tickSpacing-keyed factory lookup)
contract SlipstreamAggregator is UniswapV3Aggregator {
    /// @param manager PoolManager
    /// @param slipstreamFactory Slipstream pool factory (tickSpacing `getPool`)
    /// @param quoter Aerodrome Slipstream quoter (`IQuoterV2`, not Uni QuoterV2 `fee` tuple)
    constructor(IPoolManager manager, address slipstreamFactory, address quoter)
        UniswapV3Aggregator(manager, slipstreamFactory, quoter, "SlipstreamAggregator v1.0")
    {}

    /// @inheritdoc UniswapV3Aggregator
    /// @dev Aerodrome Slipstream quoters use `int24 tickSpacing` in params (Uni QuoterV2 uses `uint24 fee`).
    function _rawQuote(bool zeroToOne, int256 amountSpecified, PoolId poolId)
        internal
        virtual
        override
        returns (uint256 amountUnspecified)
    {
        address poolAddr = poolIdToExternalPool[poolId];
        if (poolAddr == address(0)) revert PoolDoesNotExist();

        address token0 = IUniswapV3Pool(poolAddr).token0();
        address token1 = IUniswapV3Pool(poolAddr).token1();
        uint24 hint = quoterRoutingHintByPoolId[poolId];
        int24 tickSpacing = int24(int256(uint256(hint)));

        uint160 sqrtLimitQuote = 0;

        if (amountSpecified < 0) {
            address tokenIn = zeroToOne ? token0 : token1;
            address tokenOut = zeroToOne ? token1 : token0;
            amountUnspecified = IQuoterV2(quoter)
                .quoteExactInputSingle(
                    IQuoterV2.QuoteExactInputSingleParams({
                        tokenIn: tokenIn,
                        tokenOut: tokenOut,
                        amountIn: uint256(-amountSpecified),
                        tickSpacing: tickSpacing,
                        sqrtPriceLimitX96: sqrtLimitQuote
                    })
                );
        } else {
            address tokenIn = zeroToOne ? token0 : token1;
            address tokenOut = zeroToOne ? token1 : token0;
            amountUnspecified = IQuoterV2(quoter)
                .quoteExactOutputSingle(
                    IQuoterV2.QuoteExactOutputSingleParams({
                        tokenIn: tokenIn,
                        tokenOut: tokenOut,
                        amountOut: uint256(amountSpecified),
                        tickSpacing: tickSpacing,
                        sqrtPriceLimitX96: sqrtLimitQuote
                    })
                );
        }
    }

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

    /// @inheritdoc UniswapV3Aggregator
    /// @dev Stored bits match Slipstream quoter `tickSpacing` (same encoding as uint24 narrow cast from `key.tickSpacing`).
    function _quoterRoutingHintFromKey(PoolKey calldata key) internal pure override returns (uint24) {
        return uint24(uint256(int256(key.tickSpacing)));
    }
}
