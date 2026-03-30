// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {SwapMath} from "@uniswap/v4-core/src/libraries/SwapMath.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {TickBitmap} from "@uniswap/v4-core/src/libraries/TickBitmap.sol";
import {BitMath} from "@uniswap/v4-core/src/libraries/BitMath.sol";
import {ProtocolFeeLibrary} from "@uniswap/v4-core/src/libraries/ProtocolFeeLibrary.sol";

/// @title SwapSimulator
/// @notice View-only library that replicates Pool.sol's tick-walking swap loop using
///         external state reads via StateLibrary.extsload(). Produces indicative quotes
///         that closely match actual swap execution for a given fee override.
library SwapSimulator {
    using StateLibrary for IPoolManager;
    using ProtocolFeeLibrary for uint24;
    using ProtocolFeeLibrary for uint16;


    struct SwapState {
        uint160 sqrtPriceX96;
        int24 tick;
        uint128 liquidity;
        int256 amountRemaining;
        int256 amountCalc;
        uint160 sqrtPriceLimitX96;
    }

    /// @notice Simulate a swap against a v4 pool's current state.
    /// @param manager The PoolManager contract.
    /// @param poolId The pool to simulate against.
    /// @param zeroForOne The swap direction.
    /// @param amountSpecified Negative for exact input, positive for exact output.
    /// @param lpFeePips The LP fee to apply (same as the hook's fee override).
    /// @param tickSpacing The pool's tick spacing.
    /// @return result For exact input: total output amount. For exact output: total input required.
    function simulateSwap(
        IPoolManager manager,
        PoolId poolId,
        bool zeroForOne,
        int256 amountSpecified,
        uint24 lpFeePips,
        int24 tickSpacing
    ) internal view returns (uint256 result) {
        uint160 sqrtPriceLimitX96 = zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1;
        (uint256 amountIn, uint256 amountOut) =
            simulateSwapToPrice(manager, poolId, zeroForOne, amountSpecified, lpFeePips, tickSpacing, sqrtPriceLimitX96);
        result = amountSpecified < 0 ? amountOut : amountIn;
    }

    /// @notice Simulate a swap up to a target price, returning both amounts.
    /// @dev Walks ticks until the price limit is reached or the specified amount is exhausted.
    ///      Mirrors Pool.sol's swap loop with protocol fee handling.
    /// @param manager The PoolManager contract.
    /// @param poolId The pool to simulate against.
    /// @param zeroForOne The swap direction.
    /// @param amountSpecified Negative for exact input, positive for exact output.
    /// @param lpFeePips The LP fee to apply (same as the hook's fee override).
    /// @param tickSpacing The pool's tick spacing.
    /// @param sqrtPriceLimitX96 The target price. Swap terminates when this price is reached
    ///        or the specified amount is exhausted, whichever comes first.
    /// @return amountIn Total input consumed (including fees).
    /// @return amountOut Total output received.
    function simulateSwapToPrice(
        IPoolManager manager,
        PoolId poolId,
        bool zeroForOne,
        int256 amountSpecified,
        uint24 lpFeePips,
        int24 tickSpacing,
        uint160 sqrtPriceLimitX96
    ) internal view returns (uint256 amountIn, uint256 amountOut) {
        SwapState memory s;
        {
            int24 tick;
            uint24 protocolFee;
            (s.sqrtPriceX96, tick, protocolFee,) = manager.getSlot0(poolId);
            s.tick = tick;
            s.sqrtPriceLimitX96 = sqrtPriceLimitX96;

            // Combine protocol fee with LP fee override, mirroring Pool.sol's fee calculation.
            uint16 directionalProtocolFee = zeroForOne ? protocolFee.getZeroForOneFee() : protocolFee.getOneForZeroFee();
            if (directionalProtocolFee != 0) {
                lpFeePips = directionalProtocolFee.calculateSwapFee(lpFeePips);
            }
        }
        s.liquidity = manager.getLiquidity(poolId);

        if (s.sqrtPriceX96 == 0 || amountSpecified == 0) return (0, 0);

        s.amountRemaining = amountSpecified;

        _walkTicks(manager, poolId, s, zeroForOne, lpFeePips, tickSpacing, amountSpecified < 0);

        if (amountSpecified < 0) {
            amountIn = uint256(s.amountRemaining - amountSpecified);
            amountOut = uint256(s.amountCalc);
        } else {
            amountIn = uint256(-s.amountCalc);
            amountOut = uint256(amountSpecified - s.amountRemaining);
        }
    }

    /// @dev Core tick-walking loop — mirrors Pool.sol. Modifies `s` in place.
    ///      Extracted from the main function to stay within stack depth limits.
    ///
    ///      Gas hotspots by impact:
    ///      - Highest: per-iteration next-tick lookup and bitmap masking.
    ///      - Medium: step accumulation and tick-cross liquidity updates.
    ///      - Lower: per-iteration bounds checks and branch bookkeeping.
    function _walkTicks(
        IPoolManager manager,
        PoolId poolId,
        SwapState memory s,
        bool zeroForOne,
        uint24 feePips,
        int24 tickSpacing,
        bool exactInput
    ) private view {
        while (s.amountRemaining != 0 && s.sqrtPriceX96 != s.sqrtPriceLimitX96) {
            (int24 tickNext, bool initialized) = _nextInitializedTick(manager, poolId, s.tick, tickSpacing, zeroForOne);

            // Clamp tickNext to valid range (MIN_TICK, MAX_TICK)
            assembly ("memory-safe") {
                tickNext := signextend(2, tickNext)
                if slt(tickNext, sub(0, 887272)) { tickNext := sub(0, 887272) }
                if sgt(tickNext, 887272) { tickNext := 887272 }
            }

            // Cache tick→price: avoids computing getSqrtPriceAtTick(tickNext) twice
            // per step (swap target + boundary check). ~600-1200 gas saved per tick step.
            uint160 sqrtPriceNextX96 = TickMath.getSqrtPriceAtTick(tickNext);

            // Execute step + handle the non-boundary tick update inside a scoped block so
            // that sqrtPriceStartX96 dies before the tick crossing code below, keeping the
            // stack within the 16-slot limit for the getTickLiquidity call.
            {
                uint160 sqrtPriceStartX96 = _stepAndAccumulate(
                    s,
                    SwapMath.getSqrtPriceTarget(zeroForOne, sqrtPriceNextX96, s.sqrtPriceLimitX96),
                    feePips,
                    exactInput
                );

                // Price moved mid-tick (didn't reach boundary) — recompute tick
                if (s.sqrtPriceX96 != sqrtPriceNextX96 && s.sqrtPriceX96 != sqrtPriceStartX96) {
                    s.tick = TickMath.getTickAtSqrtPrice(s.sqrtPriceX96);
                }
            }
            // sqrtPriceStartX96 is now dead — stack freed for tick crossing

            // Cross tick boundary — uses cached sqrtPriceNextX96
            if (s.sqrtPriceX96 == sqrtPriceNextX96) {
                if (initialized) {
                    (, int128 liquidityNet) = manager.getTickLiquidity(poolId, tickNext);
                    unchecked {
                        if (zeroForOne) liquidityNet = -liquidityNet;
                    }
                    s.liquidity = _addLiquidityDelta(s.liquidity, liquidityNet);
                }
                unchecked {
                    s.tick = zeroForOne ? tickNext - 1 : tickNext;
                }
            }
        }
    }

    /// @dev Execute one swap step: compute amounts via SwapMath and accumulate into state.
    ///      Separated from the main loop to stay within stack depth limits while allowing
    ///      the caller to cache sqrtPriceNextX96.
    /// @return sqrtPriceStartX96 The price before the step (for boundary detection).
    function _stepAndAccumulate(SwapState memory s, uint160 sqrtPriceTargetX96, uint24 feePips, bool exactInput)
        private
        pure
        returns (uint160 sqrtPriceStartX96)
    {
        sqrtPriceStartX96 = s.sqrtPriceX96;

        (uint160 sqrtPriceAfter, uint256 amountIn, uint256 amountOut, uint256 feeAmount) =
            SwapMath.computeSwapStep(sqrtPriceStartX96, sqrtPriceTargetX96, s.liquidity, s.amountRemaining, feePips);

        // Assembly accumulation: swap amounts are bounded by pool liquidity (< 2^128),
        // well within int256 range, so SafeCast.toInt256() checks are redundant.
        // Saves ~80 gas per step by skipping 3-4 SafeCast calls.
        assembly ("memory-safe") {
            let sAmountRemaining := add(s, 0x60)
            let sAmountCalc := add(s, 0x80)
            mstore(s, sqrtPriceAfter)
            let rem := mload(sAmountRemaining)
            let calc := mload(sAmountCalc)
            let inputPlusFee := add(amountIn, feeAmount)
            switch exactInput
            case 1 {
                mstore(sAmountRemaining, add(rem, inputPlusFee))
                mstore(sAmountCalc, add(calc, amountOut))
            }
            default {
                mstore(sAmountRemaining, sub(rem, amountOut))
                mstore(sAmountCalc, sub(calc, inputPlusFee))
            }
        }
    }

    /// @dev Equivalent overflow semantics to v4-core LiquidityMath.addDelta.
    function _addLiquidityDelta(uint128 x, int128 y) private pure returns (uint128 z) {
        assembly ("memory-safe") {
            z := add(and(x, 0xffffffffffffffffffffffffffffffff), signextend(15, y))
            if shr(128, z) {
                mstore(0, 0x93dafdf1) // SafeCastOverflow()
                revert(0x1c, 0x04)
            }
        }
    }

    /// @dev Find the next initialized tick using external bitmap reads.
    function _nextInitializedTick(IPoolManager manager, PoolId poolId, int24 tick, int24 tickSpacing, bool lte)
        private
        view
        returns (int24 next, bool initialized)
    {
        unchecked {
            int24 compressed;
            assembly ("memory-safe") {
                tick := signextend(2, tick)
                tickSpacing := signextend(2, tickSpacing)
                compressed := sub(sdiv(tick, tickSpacing), slt(smod(tick, tickSpacing), 0))
            }

            if (lte) {
                int16 wordPos;
                uint8 bitPos;
                assembly ("memory-safe") {
                    compressed := signextend(2, compressed)
                    wordPos := sar(8, compressed)
                    bitPos := and(compressed, 0xff)
                }
                uint256 masked =
                    manager.getTickBitmap(poolId, wordPos) & (type(uint256).max >> (uint256(type(uint8).max) - bitPos));

                initialized = masked != 0;
                next = initialized
                    ? (compressed - int24(uint24(bitPos - BitMath.mostSignificantBit(masked)))) * tickSpacing
                    : (compressed - int24(uint24(bitPos))) * tickSpacing;
            } else {
                ++compressed;
                int16 wordPos;
                uint8 bitPos;
                assembly ("memory-safe") {
                    compressed := signextend(2, compressed)
                    wordPos := sar(8, compressed)
                    bitPos := and(compressed, 0xff)
                }
                uint256 masked = manager.getTickBitmap(poolId, wordPos) & ~((1 << bitPos) - 1);

                initialized = masked != 0;
                next = initialized
                    ? (compressed + int24(uint24(BitMath.leastSignificantBit(masked) - bitPos))) * tickSpacing
                    : (compressed + int24(uint24(type(uint8).max - bitPos))) * tickSpacing;
            }

        }
    }

    // ═══════════════════════════════════════════════════════════════════════════
    //                        VIRTUAL TICK SIMULATION
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice An initialized tick with its net liquidity delta, for virtual simulation.
    /// @dev    Must be sorted by tick ascending. Each entry represents a tick boundary where
    ///         liquidity changes — identical to how v4's tick bitmap works, but provided by
    ///         the caller instead of read from pool state.
    /// @param tick         The tick value (must be aligned to the pool's tick spacing).
    /// @param liquidityNet Net liquidity change when crossing this tick left-to-right.
    ///                     Negated when crossing right-to-left (zeroForOne).
    struct TickDelta {
        int24 tick;
        int128 liquidityNet;
    }

    /// @notice Simulate a swap against virtual (caller-provided) liquidity, returning both amounts.
    /// @dev    Used by JIT hooks that deploy liquidity ephemerally — the positions don't exist
    ///         onchain between swaps, so the standard simulator can't read them. The caller
    ///         constructs the tick→liquidity schedule from its bucket configuration and passes
    ///         it here for accurate multi-step simulation.
    ///
    ///         The tick-walking loop is identical to `simulateSwapToPrice` except tick lookups
    ///         come from the sorted `ticks` array instead of the PoolManager's bitmap.
    ///
    /// @param sqrtPriceX96      Current pool sqrt price (Q64.96).
    /// @param currentTick       Current pool tick.
    /// @param initialLiquidity  Liquidity at the current tick (sum of all buckets active at this tick).
    /// @param zeroForOne        Swap direction.
    /// @param amountSpecified   Swap amount (negative = exact input, positive = exact output).
    /// @param feePips           Fee to apply (LP fee, possibly combined with protocol fee).
    /// @param sqrtPriceLimitX96 Price limit — swap terminates when reached.
    /// @param ticks             Sorted array of tick boundaries with their liquidity deltas.
    ///                          Must be sorted ascending by tick. Empty array = single-step sim.
    /// @return amountIn         Total input consumed (including fees).
    /// @return amountOut        Total output received.
    function simulateSwapVirtual(
        uint160 sqrtPriceX96,
        int24 currentTick,
        uint128 initialLiquidity,
        bool zeroForOne,
        int256 amountSpecified,
        uint24 feePips,
        uint160 sqrtPriceLimitX96,
        TickDelta[] memory ticks
    ) internal pure returns (uint256 amountIn, uint256 amountOut) {
        if (sqrtPriceX96 == 0 || amountSpecified == 0) return (0, 0);

        SwapState memory s;
        s.sqrtPriceX96 = sqrtPriceX96;
        s.tick = currentTick;
        s.liquidity = initialLiquidity;
        s.amountRemaining = amountSpecified;
        s.sqrtPriceLimitX96 = sqrtPriceLimitX96;

        _walkTicksVirtual(s, zeroForOne, feePips, amountSpecified < 0, ticks);

        if (amountSpecified < 0) {
            amountIn = uint256(s.amountRemaining - amountSpecified);
            amountOut = uint256(s.amountCalc);
        } else {
            amountIn = uint256(-s.amountCalc);
            amountOut = uint256(amountSpecified - s.amountRemaining);
        }
    }

    /// @dev Tick-walking loop against a caller-provided tick schedule. Mirrors `_walkTicks`
    ///      but finds the next initialized tick by scanning the sorted `ticks` array instead
    ///      of reading the PoolManager's bitmap.
    /// @param s          Swap state (modified in place).
    /// @param zeroForOne Swap direction.
    /// @param feePips    Fee in pips.
    /// @param exactInput Whether the swap is exact-input.
    /// @param ticks      Sorted tick boundaries (ascending by tick).
    function _walkTicksVirtual(
        SwapState memory s,
        bool zeroForOne,
        uint24 feePips,
        bool exactInput,
        TickDelta[] memory ticks
    ) private pure {
        uint256 n = ticks.length;

        // Find starting index. Array is sorted ascending.
        // zeroForOne: start from highest tick <= s.tick (scan from right).
        // oneForZero: start from lowest tick > s.tick (scan from left).
        uint256 idx = n; // n = "exhausted" sentinel
        if (zeroForOne) {
            // Scan from the right — first match is the highest tick <= s.tick.
            for (uint256 i = n; i > 0;) {
                --i;
                if (ticks[i].tick <= s.tick) { idx = i; break; }
            }
        } else {
            for (uint256 i; i < n; ++i) {
                if (ticks[i].tick > s.tick) { idx = i; break; }
            }
        }

        while (s.amountRemaining != 0 && s.sqrtPriceX96 != s.sqrtPriceLimitX96) {
            // Next tick boundary, or extreme if no more ticks in this direction.
            bool initialized = idx < n;
            int24 tickNext = initialized
                ? ticks[idx].tick
                : (zeroForOne ? TickMath.MIN_TICK : TickMath.MAX_TICK);

            uint160 sqrtPriceNextX96 = TickMath.getSqrtPriceAtTick(tickNext);

            {
                uint160 sqrtPriceStartX96 = _stepAndAccumulate(
                    s,
                    SwapMath.getSqrtPriceTarget(zeroForOne, sqrtPriceNextX96, s.sqrtPriceLimitX96),
                    feePips,
                    exactInput
                );

                if (s.sqrtPriceX96 != sqrtPriceNextX96 && s.sqrtPriceX96 != sqrtPriceStartX96) {
                    s.tick = TickMath.getTickAtSqrtPrice(s.sqrtPriceX96);
                }
            }

            // Cross tick boundary — apply liquidity delta and advance index.
            if (s.sqrtPriceX96 == sqrtPriceNextX96) {
                if (initialized) {
                    int128 liquidityNet = ticks[idx].liquidityNet;
                    unchecked {
                        if (zeroForOne) liquidityNet = -liquidityNet;
                    }
                    s.liquidity = _addLiquidityDelta(s.liquidity, liquidityNet);
                }
                unchecked {
                    s.tick = zeroForOne ? tickNext - 1 : tickNext;
                }
                // Advance: zeroForOne scans left (decreasing), oneForZero scans right (increasing).
                idx = zeroForOne ? (idx == 0 ? n : idx - 1) : idx + 1;
            }
        }
    }

}
