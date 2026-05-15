// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {SwapSimulator} from "./libraries/SwapSimulator.sol";

/// @title INativeBookQuoterSource
/// @author Uniswap Labs
/// @notice Minimal read interface used by {NativeBookQuoter} to inspect a NativeBook hook.
/// @custom:security-contact security@uniswap.org
interface INativeBookQuoterSource {
    /// @notice Side of a native-book maker position.
    enum Side {
        Bid,
        Ask
    }

    /// @notice Return whether a pool is currently live for swaps.
    /// @param poolId Pool being queried.
    /// @return live True if the pool is live.
    function poolLive(PoolId poolId) external view returns (bool);

    /// @notice Return canonical native-book configuration for a pool.
    /// @param poolId Pool being queried.
    /// @return binSpacingTicks Width of each book bin in ticks.
    /// @return binsPerSide Number of canonical bins available on each side.
    /// @return maxMakerBins Maximum active bins per maker.
    /// @return maxRetirePerSwap Maximum stale/crossed bins inspected and retired per swap.
    /// @return maxQuoteTtl Maximum quote lifetime in seconds.
    /// @return minBinLiquidity Minimum native v4 liquidity for a newly posted bin.
    function poolConfigs(PoolId poolId)
        external
        view
        returns (
            int24 binSpacingTicks,
            uint8 binsPerSide,
            uint8 maxMakerBins,
            uint8 maxRetirePerSwap,
            uint40 maxQuoteTtl,
            uint128 minBinLiquidity
        );

    /// @notice Return a pool's active position id at an index.
    /// @param poolId Pool being queried.
    /// @param index Zero-based active position index.
    /// @return positionId Active position id at `index`.
    function activePositionAt(PoolId poolId, uint256 index) external view returns (bytes32);

    /// @notice Return the number of active position ids tracked for a pool.
    /// @param poolId Pool being queried.
    /// @return count Number of active position ids.
    function activePositionCount(PoolId poolId) external view returns (uint256);

    /// @notice Return the pool's bounded retirement cursor.
    /// @param poolId Pool being queried.
    /// @return cursor Current cursor into the pool's active position ids.
    function retireCursor(PoolId poolId) external view returns (uint256);

    /// @notice Return metadata for a hook-owned maker position.
    /// @param positionId Position id being queried.
    /// @return maker Maker that owns the position.
    /// @return poolId Pool the position belongs to.
    /// @return side Bid or ask side.
    /// @return tickLower Lower tick of the native v4 position.
    /// @return tickUpper Upper tick of the native v4 position.
    /// @return liquidity Native v4 liquidity currently deployed.
    /// @return expiry Unix timestamp when the quote becomes retirable.
    /// @return active True if the position currently owns native v4 liquidity.
    function positions(bytes32 positionId)
        external
        view
        returns (
            address maker,
            PoolId poolId,
            Side side,
            int24 tickLower,
            int24 tickUpper,
            uint128 liquidity,
            uint40 expiry,
            bool active
        );
}

/// @title NativeBookQuoter
/// @notice View-only ALF quote helper for NativeBookHook.
/// @dev Kept out of the hook runtime so full native v4 tick-walking quotes do not push the
///      hook over EIP-170. Quotes mirror NativeBookHook's bounded pre-swap retirement by
///      applying equivalent virtual liquidity removals before simulation.
/// @custom:security-contact security@uniswap.org
contract NativeBookQuoter {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    /// @notice Maximum initialized-tick steps walked for an ALF quote before returning zero.
    uint16 public constant MAX_QUOTE_TICK_STEPS = 512;

    IPoolManager public immutable poolManager;

    /// @notice Deploy the native-book quote helper.
    /// @param _poolManager The Uniswap v4 PoolManager read by the simulator.
    constructor(IPoolManager _poolManager) {
        poolManager = _poolManager;
    }

    /// @notice Return an indicative ALF quote for a native-book pool.
    /// @dev Returns output for exact-input swaps and required input for exact-output swaps.
    /// @param source Hook contract exposing native-book position state.
    /// @param key Pool key being quoted.
    /// @param zeroForOne Swap direction.
    /// @param amountSpecified Negative for exact input, positive for exact output.
    /// @return outputAmount Indicative output amount for exact input, or required input for exact output.
    function getIndicativeQuote(
        INativeBookQuoterSource source,
        PoolKey calldata key,
        bool zeroForOne,
        int256 amountSpecified
    ) external view returns (uint256 outputAmount) {
        uint160 sqrtPriceLimitX96 = zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1;
        (uint256 amountIn, uint256 amountOut) =
            _simulateSwapToPrice(source, key, zeroForOne, amountSpecified, sqrtPriceLimitX96);
        if (amountSpecified > 0 && amountOut != uint256(amountSpecified)) return 0;
        outputAmount = amountSpecified < 0 ? amountOut : amountIn;
    }

    /// @notice Simulate a swap until amount exhaustion or a target price.
    /// @param source Hook contract exposing native-book position state.
    /// @param key Pool key being quoted.
    /// @param zeroForOne Swap direction.
    /// @param amountSpecified Negative for exact input, positive for exact output.
    /// @param sqrtPriceLimitX96 Target sqrt price limit in Q64.96.
    /// @return amountIn Total input consumed, including fees.
    /// @return amountOut Total output received.
    function swapToPrice(
        INativeBookQuoterSource source,
        PoolKey calldata key,
        bool zeroForOne,
        int256 amountSpecified,
        uint160 sqrtPriceLimitX96
    ) external view returns (uint256 amountIn, uint256 amountOut) {
        return _simulateSwapToPrice(source, key, zeroForOne, amountSpecified, sqrtPriceLimitX96);
    }

    function _simulateSwapToPrice(
        INativeBookQuoterSource source,
        PoolKey calldata key,
        bool zeroForOne,
        int256 amountSpecified,
        uint160 sqrtPriceLimitX96
    ) internal view returns (uint256 amountIn, uint256 amountOut) {
        PoolId poolId = key.toId();
        if (!source.poolLive(poolId)) return (0, 0);

        (
            int128 activeLiquidityDelta,
            SwapSimulator.TickAdjustment[] memory tickAdjustments,
            uint256 tickAdjustmentCount
        ) = _quoteRetirementAdjustments(source, key);

        return SwapSimulator.simulateSwapToPriceWithAdjustments(
            SwapSimulator.SimulationParams({
                manager: poolManager,
                poolId: poolId,
                zeroForOne: zeroForOne,
                amountSpecified: amountSpecified,
                lpFeePips: key.fee,
                tickSpacing: key.tickSpacing,
                sqrtPriceLimitX96: sqrtPriceLimitX96,
                activeLiquidityDelta: activeLiquidityDelta,
                tickAdjustments: tickAdjustments,
                tickAdjustmentCount: tickAdjustmentCount,
                maxTickSteps: MAX_QUOTE_TICK_STEPS
            })
        );
    }

    function _quoteRetirementAdjustments(INativeBookQuoterSource source, PoolKey calldata key)
        internal
        view
        returns (
            int128 activeLiquidityDelta,
            SwapSimulator.TickAdjustment[] memory tickAdjustments,
            uint256 tickAdjustmentCount
        )
    {
        PoolId poolId = key.toId();
        (,,, uint8 maxRemovals,,) = source.poolConfigs(poolId);
        uint256 length = source.activePositionCount(poolId);
        tickAdjustments = new SwapSimulator.TickAdjustment[](uint256(maxRemovals) * 2);
        if (maxRemovals == 0 || length == 0) return (0, tickAdjustments, 0);

        (, int24 currentTick,,) = poolManager.getSlot0(poolId);
        uint256 checked = 0;
        uint256 removed = 0;
        uint256 cursor = source.retireCursor(poolId) % length;
        uint256[] memory overrideIndexes = new uint256[](maxRemovals);
        bytes32[] memory overrideIds = new bytes32[](maxRemovals);
        uint256 overrideCount = 0;

        while (length != 0 && checked < maxRemovals && removed < maxRemovals) {
            if (cursor >= length) cursor = 0;
            bytes32 positionId =
                _virtualActivePositionAt(source, poolId, cursor, overrideIndexes, overrideIds, overrideCount);
            unchecked {
                ++checked;
            }

            (
                ,
                PoolId positionPoolId,
                INativeBookQuoterSource.Side side,
                int24 tickLower,
                int24 tickUpper,
                uint128 liquidity,
                uint40 expiry,
                bool active
            ) = source.positions(positionId);
            if (_isRetirableAtTick(poolId, positionPoolId, side, tickLower, tickUpper, expiry, active, currentTick)) {
                int128 liquidityDelta = int128(liquidity);
                if (currentTick >= tickLower && currentTick < tickUpper) {
                    activeLiquidityDelta -= liquidityDelta;
                }
                tickAdjustmentCount = _accumulateQuoteAdjustment(
                    tickAdjustments, tickAdjustmentCount, tickLower, -liquidityDelta, liquidity
                );
                tickAdjustmentCount = _accumulateQuoteAdjustment(
                    tickAdjustments, tickAdjustmentCount, tickUpper, liquidityDelta, liquidity
                );

                unchecked {
                    ++removed;
                }
                uint256 lastIndex = length - 1;
                if (cursor != lastIndex) {
                    bytes32 lastId = _virtualActivePositionAt(
                        source, poolId, lastIndex, overrideIndexes, overrideIds, overrideCount
                    );
                    overrideIndexes[overrideCount] = cursor;
                    overrideIds[overrideCount] = lastId;
                    unchecked {
                        ++overrideCount;
                    }
                }
                unchecked {
                    --length;
                }
                if (cursor >= length && length != 0) cursor = 0;
            } else {
                unchecked {
                    ++cursor;
                }
            }
        }
    }

    function _virtualActivePositionAt(
        INativeBookQuoterSource source,
        PoolId poolId,
        uint256 index,
        uint256[] memory overrideIndexes,
        bytes32[] memory overrideIds,
        uint256 overrideCount
    ) internal view returns (bytes32 positionId) {
        positionId = source.activePositionAt(poolId, index);
        for (uint256 i = overrideCount; i != 0;) {
            unchecked {
                --i;
            }
            if (overrideIndexes[i] == index) return overrideIds[i];
        }
    }

    function _accumulateQuoteAdjustment(
        SwapSimulator.TickAdjustment[] memory tickAdjustments,
        uint256 tickAdjustmentCount,
        int24 tick,
        int128 liquidityNetDelta,
        uint128 liquidityGrossRemoved
    ) internal pure returns (uint256) {
        for (uint256 i; i < tickAdjustmentCount;) {
            if (tickAdjustments[i].tick == tick) {
                tickAdjustments[i].liquidityNetDelta += liquidityNetDelta;
                tickAdjustments[i].liquidityGrossRemoved += liquidityGrossRemoved;
                return tickAdjustmentCount;
            }
            unchecked {
                ++i;
            }
        }

        tickAdjustments[tickAdjustmentCount] = SwapSimulator.TickAdjustment({
            tick: tick, liquidityNetDelta: liquidityNetDelta, liquidityGrossRemoved: liquidityGrossRemoved
        });
        return tickAdjustmentCount + 1;
    }

    function _isRetirableAtTick(
        PoolId expectedPoolId,
        PoolId positionPoolId,
        INativeBookQuoterSource.Side side,
        int24 tickLower,
        int24 tickUpper,
        uint40 expiry,
        bool active,
        int24 currentTick
    ) internal view returns (bool) {
        if (!active || PoolId.unwrap(positionPoolId) != PoolId.unwrap(expectedPoolId)) return false;
        if (block.timestamp >= expiry) return true;
        if (side == INativeBookQuoterSource.Side.Ask) return currentTick >= tickUpper;
        return currentTick < tickLower;
    }
}
