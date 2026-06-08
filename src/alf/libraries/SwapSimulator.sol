// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {SwapMath} from "@uniswap/v4-core/src/libraries/SwapMath.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {BitMath} from "@uniswap/v4-core/src/libraries/BitMath.sol";
import {ProtocolFeeLibrary} from "@uniswap/v4-core/src/libraries/ProtocolFeeLibrary.sol";

/// @title SwapSimulator
/// @author Uniswap Labs
/// @notice View-only library that replicates Pool.sol's tick-walking swap loop using
///         external state reads via StateLibrary.extsload(). Produces indicative quotes
///         that closely match actual swap execution for a given fee override.
/// @custom:security-contact security@uniswap.org
library SwapSimulator {
    using StateLibrary for IPoolManager;
    using ProtocolFeeLibrary for uint24;
    using ProtocolFeeLibrary for uint16;

    /// @dev Hard cap on `_walkTicks` iterations. Bounds the worst-case gas for pathological
    ///      scenarios (unseeded pool, oversized swap walking past LP into empty tick space,
    ///      sparse-bitmap walks) regardless of whether the caller honors `BaseALFHook.maxGas`.
    ///      The loop exits early on `amountRemaining == 0` or hitting the price limit; this
    ///      cap only fires for runaway walks.
    ///
    ///      4_096 covers every legitimate use of the library:
    ///        - SpreadQuoter single-band: <10 steps
    ///        - SmartPoolHook 8-bucket distributions at typical spacings: <100 steps
    ///        - Extreme wide-bucket configs spanning many bitmap words: still well under
    ///      while still bounding the worst case to ~20M gas at ~5K gas/iter (well under one
    ///      block, so an on-chain caller without a `{gas:}` envelope OOGs the call, not the
    ///      block). Hitting the cap returns the partial output computed so far; for a quote
    ///      consumer this surfaces as a smaller-than-expected output, which the caller can
    ///      detect via slippage bounds.
    uint256 internal constant MAX_WALK_STEPS = 4_096;

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
    ///
    ///      Soft-fail contract: returns `(0, 0)` -- never reverts -- for every input shape
    ///      `Pool.swap` would reject with `PriceLimitAlreadyExceeded` or `PriceLimitOutOfBounds`.
    ///      Routers and aggregators that take the output at face value can rely on the
    ///      invariant `(amountIn, amountOut) == (0, 0)` ⇔ "untradable at these parameters".
    ///      Pre-loop rejection cases:
    ///        - uninitialized pool (`slot0.sqrtPriceX96 == 0`)
    ///        - `amountSpecified == 0`
    ///        - `sqrtPriceLimitX96` on the wrong side of the current price for the chosen
    ///          direction (no swap can move price toward the limit)
    ///        - `sqrtPriceLimitX96` at or past `MIN_SQRT_PRICE` / `MAX_SQRT_PRICE`
    ///          (`Pool.swap` rejects the boundary value strictly)
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

        // Mirror `Pool.swap`'s `sqrtPriceLimitX96` guards but soft-fail to `(0, 0)` instead
        // of reverting. Without these, three regimes silently diverge from execution:
        //   - Wrong-side limit: `SwapMath.computeSwapStep` re-derives direction from the
        //     price ordering, so the loop computes a single opposite-direction step from
        //     `current` to `limit` and returns a numerically valid but fictional non-zero
        //     tuple whenever current-tick liquidity > 0. Pool.swap reverts.
        //   - Limit at MIN/MAX_SQRT_PRICE: simulator walks the entire bitmap to the
        //     boundary; Pool.swap reverts strictly at equality.
        //   - Limit past boundary: walk's exit conditions (`amountRemaining == 0` or
        //     `sqrtPriceX96 == sqrtPriceLimitX96`) can never fire -- previously infinite,
        //     now bounded by `MAX_WALK_STEPS` but still yields a non-zero tuple.
        if (zeroForOne) {
            if (sqrtPriceLimitX96 >= s.sqrtPriceX96) return (0, 0);
            if (sqrtPriceLimitX96 <= TickMath.MIN_SQRT_PRICE) return (0, 0);
        } else {
            if (sqrtPriceLimitX96 <= s.sqrtPriceX96) return (0, 0);
            if (sqrtPriceLimitX96 >= TickMath.MAX_SQRT_PRICE) return (0, 0);
        }

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
        uint256 steps = 0;
        while (s.amountRemaining != 0 && s.sqrtPriceX96 != s.sqrtPriceLimitX96) {
            // Defense against pathological bitmap walks (empty pools, oversized swaps past
            // LP, sparse bitmaps); see `MAX_WALK_STEPS` for rationale. Hitting the cap is a
            // graceful exit -- the caller receives the partial output accumulated so far.
            if (steps == MAX_WALK_STEPS) break;
            unchecked {
                ++steps;
            }
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
}
