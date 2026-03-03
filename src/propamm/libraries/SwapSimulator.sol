// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {SwapMath} from "@uniswap/v4-core/src/libraries/SwapMath.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {TickBitmap} from "@uniswap/v4-core/src/libraries/TickBitmap.sol";
import {BitMath} from "@uniswap/v4-core/src/libraries/BitMath.sol";
import {LiquidityMath} from "@uniswap/v4-core/src/libraries/LiquidityMath.sol";
import {SafeCast} from "@uniswap/v4-core/src/libraries/SafeCast.sol";

/// @title SwapSimulator
/// @notice View-only library that replicates Pool.sol's tick-walking swap loop using
///         external state reads via StateLibrary.extsload(). Produces indicative quotes
///         that closely match actual swap execution for a given fee override.
library SwapSimulator {
    using StateLibrary for IPoolManager;
    using SafeCast for uint256;

    struct SwapState {
        uint160 sqrtPriceX96;
        int24 tick;
        uint128 liquidity;
        int256 amountSpecifiedRemaining;
        int256 amountCalculated;
    }

    /// @notice Simulate a swap against a v4 pool's current state.
    /// @param manager The PoolManager contract.
    /// @param poolId The pool to simulate against.
    /// @param zeroForOne The swap direction.
    /// @param amountSpecified Negative for exact input, positive for exact output.
    /// @param feePips The fee to apply (same as the hook's fee override).
    /// @param tickSpacing The pool's tick spacing.
    /// @return result For exact input: total output amount. For exact output: total input required.
    function simulateSwap(
        IPoolManager manager,
        PoolId poolId,
        bool zeroForOne,
        int256 amountSpecified,
        uint24 feePips,
        int24 tickSpacing
    ) internal view returns (uint256 result) {
        SwapState memory state;
        {
            int24 tick;
            (state.sqrtPriceX96, tick,,) = manager.getSlot0(poolId);
            state.tick = tick;
        }
        state.liquidity = manager.getLiquidity(poolId);

        if (state.sqrtPriceX96 == 0 || amountSpecified == 0) return 0;

        uint160 sqrtPriceLimitX96 = zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1;

        state.amountSpecifiedRemaining = amountSpecified;

        // Tick-walking loop — mirrors Pool.sol lines 343–437
        while (!(state.amountSpecifiedRemaining == 0 || state.sqrtPriceX96 == sqrtPriceLimitX96)) {
            uint160 sqrtPriceStartX96 = state.sqrtPriceX96;

            (int24 tickNext, bool initialized) =
                _nextInitializedTick(manager, poolId, state.tick, tickSpacing, zeroForOne);

            if (tickNext <= TickMath.MIN_TICK) tickNext = TickMath.MIN_TICK;
            if (tickNext >= TickMath.MAX_TICK) tickNext = TickMath.MAX_TICK;

            // Compute swap step
            {
                uint256 amountIn;
                uint256 amountOut;
                uint256 feeAmount;
                (state.sqrtPriceX96, amountIn, amountOut, feeAmount) = SwapMath.computeSwapStep(
                    state.sqrtPriceX96,
                    SwapMath.getSqrtPriceTarget(zeroForOne, TickMath.getSqrtPriceAtTick(tickNext), sqrtPriceLimitX96),
                    state.liquidity,
                    state.amountSpecifiedRemaining,
                    feePips
                );

                if (amountSpecified > 0) {
                    unchecked {
                        state.amountSpecifiedRemaining -= amountOut.toInt256();
                    }
                    state.amountCalculated -= (amountIn + feeAmount).toInt256();
                } else {
                    unchecked {
                        state.amountSpecifiedRemaining += (amountIn + feeAmount).toInt256();
                    }
                    state.amountCalculated += amountOut.toInt256();
                }
            }

            // Cross tick if we reached the boundary
            if (state.sqrtPriceX96 == TickMath.getSqrtPriceAtTick(tickNext)) {
                if (initialized) {
                    (, int128 liquidityNet) = manager.getTickLiquidity(poolId, tickNext);
                    unchecked {
                        if (zeroForOne) liquidityNet = -liquidityNet;
                    }
                    state.liquidity = LiquidityMath.addDelta(state.liquidity, liquidityNet);
                }
                unchecked {
                    state.tick = zeroForOne ? tickNext - 1 : tickNext;
                }
            } else if (state.sqrtPriceX96 != sqrtPriceStartX96) {
                state.tick = TickMath.getTickAtSqrtPrice(state.sqrtPriceX96);
            }
        }

        // Return the appropriate result based on swap type
        if (amountSpecified < 0) {
            result = uint256(state.amountCalculated);
        } else {
            result = uint256(-state.amountCalculated);
        }
    }

    /// @dev Find the next initialized tick using external bitmap reads.
    function _nextInitializedTick(IPoolManager manager, PoolId poolId, int24 tick, int24 tickSpacing, bool lte)
        private
        view
        returns (int24 next, bool initialized)
    {
        unchecked {
            int24 compressed = TickBitmap.compress(tick, tickSpacing);

            if (lte) {
                (int16 wordPos, uint8 bitPos) = TickBitmap.position(compressed);
                uint256 masked =
                    manager.getTickBitmap(poolId, wordPos) & (type(uint256).max >> (uint256(type(uint8).max) - bitPos));

                initialized = masked != 0;
                next = initialized
                    ? (compressed - int24(uint24(bitPos - BitMath.mostSignificantBit(masked)))) * tickSpacing
                    : (compressed - int24(uint24(bitPos))) * tickSpacing;
            } else {
                ++compressed;
                (int16 wordPos, uint8 bitPos) = TickBitmap.position(compressed);
                uint256 masked = manager.getTickBitmap(poolId, wordPos) & ~((1 << bitPos) - 1);

                initialized = masked != 0;
                next = initialized
                    ? (compressed + int24(uint24(BitMath.leastSignificantBit(masked) - bitPos))) * tickSpacing
                    : (compressed + int24(uint24(type(uint8).max - bitPos))) * tickSpacing;
            }
        }
    }
}
