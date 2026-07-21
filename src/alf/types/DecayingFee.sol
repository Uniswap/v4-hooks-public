// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";
import {FeeCalculation} from "../libraries/FeeCalculation.sol";

/// @dev The maximum optimal fee in 1e6 precision: 1% (1e4 out of 1e6).
uint256 constant MAX_OPTIMAL_FEE_E6 = 1e4;

/// @dev The maximum target multiplier (100 = 100%, full closeBoundaryFee subtraction).
uint256 constant MAX_TARGET_MULTIPLIER = 100;

/// @notice Per-pool fee engine parameters. Packs into a single storage slot (240 bits).
/// @param k                     Decay factor per block in Q24 format (e.g., 0.99 in Q24 means the
///                              fee retains 99% of its value each block).
/// @param logK                  Precomputed -ln(k) >> 40; used for > 4 blocks decay: k^n = exp(-logK * n).
/// @param optimalFeeE6          Fee rate defining the optimal range width in PRICE space (not sqrt
///                              price), 1e6 precision.
/// @param targetMultiplier      Multiplier for the target fee:
///                              targetFee = farBoundaryFee - closeBoundaryFee * targetMultiplier / 100.
///                              Must be 0-100.
/// @param referenceSqrtPriceX96 Reference center point in sqrt Q64.96 format.
struct FeeConfig {
    uint24 k;
    uint24 logK;
    uint24 optimalFeeE6;
    uint8 targetMultiplier;
    uint160 referenceSqrtPriceX96;
}

/// @notice Per-pool fee state snapshot, written once per block on the first swap. Packs into a
///         single storage slot (240 bits).
/// @param decayingFeeE12   Decaying fee in 1e12 precision, or `UNDEFINED_DECAYING_FEE_E12` when the
///                         cached price is inside the optimal range. The sentinel (1e12 + 1) fits
///                         uint40, as do all real fees (<= 1e12).
/// @param sqrtAmmPriceX96  AMM sqrt price at the start of the most recently swapped block; used as
///                         the cached price for same-block swaps and for cross-block price-movement
///                         detection (0 when the pool is initialized or reset, forcing the next
///                         swap to read a fresh slot0 price).
/// @param blockNumber      Block number of the most recent checkpoint on the `BlockNumberish`
///                         clock; used to detect same-block swaps and compute blocks elapsed for
///                         decay.
struct FeeState {
    uint40 decayingFeeE12;
    uint160 sqrtAmmPriceX96;
    uint40 blockNumber;
}

/// @notice Emitted when a pool's fee config is replaced via {setConfig}.
/// @param poolId The pool whose fee config was updated.
/// @param config The new fee config.
event FeeConfigUpdated(PoolId indexed poolId, FeeConfig config);

/// @dev `k` and `logK` are individually zero or mutually inconsistent. `k == 0` causes instant
///      decay; `logK == 0` coincides with k values so close to Q24 (1.0) that -ln(k) >> 40 rounds
///      to 0, which would make the decay factor always 1.0 (fee never decays); and any pair where
///      `logK != -ln(k) >> 40` would make the fast (<= 4 blocks) and slow decay paths disagree.
/// @param k    The invalid k value.
/// @param logK The invalid logK value.
error InvalidKAndLogK(uint256 k, uint256 logK);

/// @dev `optimalFeeE6` exceeds {MAX_OPTIMAL_FEE_E6}.
/// @param optimalFeeE6 The invalid optimal fee.
error InvalidOptimalFeeE6(uint256 optimalFeeE6);

/// @dev `targetMultiplier` exceeds {MAX_TARGET_MULTIPLIER}.
/// @param targetMultiplier The invalid target multiplier.
error InvalidTargetMultiplier(uint256 targetMultiplier);

/// @dev `referenceSqrtPriceX96` sits so close to a v4 sqrt-price limit that the optimal range
///      around it would leave the valid price range.
/// @param invalidSqrtPrice The invalid reference sqrt price.
error InvalidReferenceSqrtPriceX96(uint256 invalidSqrtPrice);

/// @title DecayingFee
/// @author Uniswap Labs
/// @notice Peg-anchored dynamic LP fee engine for stable/stable pools, as a type-driven value.
///         Ported from `StableStableHook` / `FeeConfiguration` so ALF hooks can compose it.
///
///         The fee is anchored to an owner-configured reference price (RP). The `optimalFeeE6`
///         parameter defines an optimal range in PRICE space around RP:
///         `[RP * (1 - optimalFee), RP / (1 - optimalFee)]`.
///
///         - **Inside the range**, the fee is set so every swapper sees a consistent pre-impact
///           price at the range boundary (sells at the lower bound, buys at the upper bound).
///         - **Outside the range**, the fee decays exponentially per block from a starting fee
///           toward a target fee, and flow that pushes the price further from RP pays zero.
///
///         State is checkpointed once per block: the first swap of a block caches the
///         start-of-block price and the computed decaying fee, and every subsequent swap in the
///         block prices off that cache. This makes same-block swaps (including a multiplexer's
///         split fills) price-consistent and removes any swap-splitting advantage.
///
///         The engine is split into {previewFee} (view, zero writes) and {commitFee} (persists the
///         checkpoint) sharing one computation, so a hook's indicative-quote paths charge exactly
///         the fee its `beforeSwap` will. Consumers pass the current slot0 sqrt price and the
///         `BlockNumberish` block number; the type holds no clock of its own.
/// @custom:security-contact security@uniswap.org
struct DecayingFee {
    mapping(PoolId poolId => FeeConfig) _config;
    mapping(PoolId poolId => FeeState) _state;
}

using {setConfig, getConfig, getState, resetState, previewFee, commitFee} for DecayingFee global;

/// @notice Validate `config` without touching storage. Reverts on the first violated constraint.
/// @dev Standalone (not bound to the type) so the validation matrix is fuzzable in isolation.
///      Constraints, ported from `FeeConfiguration`:
///        1. `k`/`logK` non-zero and mutually consistent (`logK == -lnWad(k) >> 40` after Q24 to
///           wad conversion), so the fast and slow decay paths agree.
///        2. `optimalFeeE6 <= MAX_OPTIMAL_FEE_E6`.
///        3. `targetMultiplier <= MAX_TARGET_MULTIPLIER`.
///        4. `referenceSqrtPriceX96` far enough inside the v4 sqrt-price limits that the optimal
///           range around it stays valid. The range is defined in PRICE space, so the sqrt-price
///           bounds use `sqrt(1 - maxOptimalFee)`. MIN_SQRT_PRICE is valid (inclusive) but
///           MAX_SQRT_PRICE is invalid (exclusive) in v4.
/// @param config The fee config to validate.
function validateConfig(FeeConfig memory config) pure {
    if (config.k == 0 || config.logK == 0) {
        revert InvalidKAndLogK(config.k, config.logK);
    }
    // Convert k from Q24 to wad format (1e18 scale). lnWad computes ln(k) * 1e18; since k < 1,
    // ln(k) is negative. expectedLogK = -lnK / 2^40.
    uint256 kWad = (uint256(config.k) * 1e18) >> 24;
    int256 lnK = FixedPointMathLib.lnWad(int256(kWad));
    uint256 expectedLogK = uint256(-lnK) >> 40;
    if (config.logK != expectedLogK) revert InvalidKAndLogK(config.k, config.logK);

    if (config.optimalFeeE6 > MAX_OPTIMAL_FEE_E6) revert InvalidOptimalFeeE6(config.optimalFeeE6);
    if (config.targetMultiplier > MAX_TARGET_MULTIPLIER) revert InvalidTargetMultiplier(config.targetMultiplier);

    // minBound: referenceSqrtPrice * sqrt(1 - maxOptimalFee) >= MIN_SQRT_PRICE
    //           => referenceSqrtPrice >= MIN_SQRT_PRICE / sqrt(1 - maxOptimalFee)
    // maxBound: referenceSqrtPrice / sqrt(1 - maxOptimalFee) < MAX_SQRT_PRICE  (strictly less than!)
    //           => referenceSqrtPrice < MAX_SQRT_PRICE * sqrt(1 - maxOptimalFee)
    uint256 oneMinusMaxFee = FeeCalculation.ONE_E6 - MAX_OPTIMAL_FEE_E6;
    uint256 sqrtOneMinusMaxFeeE6 = FixedPointMathLib.sqrt(oneMinusMaxFee * FeeCalculation.ONE_E6);
    uint256 minBoundedReferenceSqrtPrice =
        (uint256(TickMath.MIN_SQRT_PRICE) * FeeCalculation.ONE_E6 + sqrtOneMinusMaxFeeE6 - 1) / sqrtOneMinusMaxFeeE6;
    uint256 maxBoundedReferenceSqrtPrice =
        uint256(TickMath.MAX_SQRT_PRICE) * sqrtOneMinusMaxFeeE6 / FeeCalculation.ONE_E6;

    if (
        config.referenceSqrtPriceX96 < minBoundedReferenceSqrtPrice
            || config.referenceSqrtPriceX96 >= maxBoundedReferenceSqrtPrice
    ) {
        revert InvalidReferenceSqrtPriceX96(config.referenceSqrtPriceX96);
    }
}

/// @notice Convert a 1e12-precision fee to v4 pips (1e6). Floors at 1-pip granularity, matching
///         how the fee is charged; quote paths MUST use the same conversion so quotes and
///         execution truncate identically.
/// @param feeE12 The fee in 1e12 precision.
/// @return The fee in pips.
function toPips(uint256 feeE12) pure returns (uint24) {
    return uint24(feeE12 / FeeCalculation.ONE_E6);
}

/// @notice Validate and store `config` for `poolId`, resetting the pool's fee state, and emit
///         {FeeConfigUpdated}.
/// @dev The state reset is part of the config write by design: stale cached prices or decaying
///      fees computed under the old parameters must not leak into the new schedule. The reset
///      zeroes the cached price, so the next fee computation reads a fresh slot0 price.
/// @param self        DecayingFee storage.
/// @param poolId      The pool to configure.
/// @param config      The new fee config.
/// @param blockNumber The current `BlockNumberish` block number.
function setConfig(DecayingFee storage self, PoolId poolId, FeeConfig memory config, uint256 blockNumber)
    returns (DecayingFee storage)
{
    validateConfig(config);
    self.resetState(poolId, blockNumber);
    self._config[poolId] = config;
    emit FeeConfigUpdated(poolId, config);
    return self;
}

/// @notice Read `poolId`'s fee config.
/// @param self   DecayingFee storage.
/// @param poolId The pool to read.
/// @return The pool's fee config.
function getConfig(DecayingFee storage self, PoolId poolId) view returns (FeeConfig memory) {
    return self._config[poolId];
}

/// @notice Read `poolId`'s fee state snapshot.
/// @param self   DecayingFee storage.
/// @param poolId The pool to read.
/// @return The pool's fee state.
function getState(DecayingFee storage self, PoolId poolId) view returns (FeeState memory) {
    return self._state[poolId];
}

/// @notice Reset `poolId`'s fee state: sentinel decaying fee, current block, and a zeroed cached
///         price so the next swap reads a fresh slot0 price instead of a stale cache.
/// @param self        DecayingFee storage.
/// @param poolId      The pool to reset.
/// @param blockNumber The current `BlockNumberish` block number.
function resetState(DecayingFee storage self, PoolId poolId, uint256 blockNumber) returns (DecayingFee storage) {
    FeeState storage state = self._state[poolId];
    state.decayingFeeE12 = uint40(FeeCalculation.UNDEFINED_DECAYING_FEE_E12);
    state.blockNumber = uint40(blockNumber);
    state.sqrtAmmPriceX96 = 0;
    return self;
}

/// @notice Compute the LP fee the next swap on `poolId` would be charged, plus the state snapshot
///         that swap would checkpoint. Zero writes: this is the indicative-quote path.
/// @dev The computation, unchanged from `StableStableHook._beforeSwap`:
///
///        1. New-block detection: a block number different from the checkpoint, or a zeroed
///           cached price (fresh init / post-config reset), selects the fresh `slot0SqrtPriceX96`;
///           otherwise the cached start-of-block price is used. The cached price prevents any
///           swap-splitting advantage; staleness within a block is minimal for stable pools.
///        2. `closeBoundaryFeeE12` measures the fee that places the pre-impact price at whichever
///           optimal-range edge is closer. `<= 0` means the price is inside the range.
///        3. Inside the range, the fee gives all swappers consistent pre-impact prices:
///           sells at `RP * (1 - optimalFee)`, buys at `RP / (1 - optimalFee)`. No decaying fee.
///        4. Outside the range, the first swap of the block computes the decaying fee (see
///           {computeOutsideRangeDecayingFee}); same-block swaps reuse the checkpointed one.
///           Flow moving the price further from RP is charged zero.
///
///      Same-block calls always price off the same cached price, so they take the same
///      inside/outside branch as the block's first swap. Corollary: the sentinel stored by an
///      inside-range checkpoint is never consumed as a decay start, because a same-block call
///      cannot reach the outside branch (and a new block that reaches it treats the sentinel as
///      the "start from far boundary" case).
/// @param self              DecayingFee storage.
/// @param poolId            The pool to price.
/// @param slot0SqrtPriceX96 The pool's current sqrt price. Used only when the cached
///                          start-of-block price is absent.
/// @param zeroForOne        The swap direction (user sells token0 for token1).
/// @param blockNumber       The current `BlockNumberish` block number.
/// @return lpFeeE12 The LP fee for this swap in 1e12 precision.
/// @return next     The snapshot to persist if `dirty` (zero-valued otherwise).
/// @return dirty    True on the first swap of a block: a committing caller must persist `next`.
function previewFee(
    DecayingFee storage self,
    PoolId poolId,
    uint160 slot0SqrtPriceX96,
    bool zeroForOne,
    uint256 blockNumber
) view returns (uint256 lpFeeE12, FeeState memory next, bool dirty) {
    FeeConfig storage config = self._config[poolId];
    FeeState storage state = self._state[poolId];

    // Use the start-of-block price for fee calculation to prevent swap-splitting advantage, or
    // read the fresh price if this is the first swap after pool init/reset.
    bool isNewBlock = (blockNumber != state.blockNumber) || state.sqrtAmmPriceX96 == 0;
    uint256 sqrtAmmPriceX96 = isNewBlock ? slot0SqrtPriceX96 : state.sqrtAmmPriceX96;

    uint256 sqrtReferencePriceX96 = config.referenceSqrtPriceX96;
    uint256 optimalFeeE6 = config.optimalFeeE6;

    uint256 priceRatioX96 = FeeCalculation.calculatePriceRatioX96(sqrtAmmPriceX96, sqrtReferencePriceX96);

    // closeBoundaryFeeE12 <= 0: the price is inside the optimal range (past the close boundary).
    // closeBoundaryFeeE12 > 0: the price is outside (hasn't reached the close boundary).
    int256 closeBoundaryFeeE12 = FeeCalculation.calculateCloseBoundaryFee(priceRatioX96, optimalFeeE6);

    bool ammPriceBelowRP = sqrtAmmPriceX96 < sqrtReferencePriceX96;
    uint256 decayingFeeE12;

    if (closeBoundaryFeeE12 <= 0) {
        // Inside optimal range: consistent pre-impact prices for all swappers.
        lpFeeE12 =
            FeeCalculation.calculateInsideOptimalRangeFee(priceRatioX96, optimalFeeE6, ammPriceBelowRP, zeroForOne);
        decayingFeeE12 = FeeCalculation.UNDEFINED_DECAYING_FEE_E12;
    } else {
        // Outside optimal range: the fee decays exponentially toward a target fee.
        if (isNewBlock) {
            uint256 farBoundaryFeeE12 = FeeCalculation.calculateFarBoundaryFee(priceRatioX96, optimalFeeE6);
            decayingFeeE12 = computeOutsideRangeDecayingFee(
                config,
                state,
                sqrtAmmPriceX96,
                sqrtReferencePriceX96,
                uint256(closeBoundaryFeeE12),
                farBoundaryFeeE12,
                ammPriceBelowRP,
                blockNumber
            );
        } else {
            // Same block: reuse the decaying fee checkpointed by the block's first swap.
            decayingFeeE12 = state.decayingFeeE12;
        }

        // Price moving further from reference: charge 0. Otherwise, charge the decaying fee.
        lpFeeE12 = (ammPriceBelowRP == zeroForOne) ? 0 : decayingFeeE12;
    }

    dirty = isNewBlock;
    if (dirty) {
        next = FeeState({
            decayingFeeE12: uint40(decayingFeeE12),
            sqrtAmmPriceX96: uint160(sqrtAmmPriceX96),
            blockNumber: uint40(blockNumber)
        });
    }
}

/// @notice {previewFee}, then persist the checkpoint when `dirty`. The `beforeSwap` path.
/// @param self              DecayingFee storage.
/// @param poolId            The pool to price.
/// @param slot0SqrtPriceX96 The pool's current sqrt price.
/// @param zeroForOne        The swap direction.
/// @param blockNumber       The current `BlockNumberish` block number.
/// @return lpFeeE12 The LP fee for this swap in 1e12 precision, exactly {previewFee}'s.
function commitFee(
    DecayingFee storage self,
    PoolId poolId,
    uint160 slot0SqrtPriceX96,
    bool zeroForOne,
    uint256 blockNumber
) returns (uint256 lpFeeE12) {
    (uint256 fee, FeeState memory next, bool dirty) =
        self.previewFee(poolId, slot0SqrtPriceX96, zeroForOne, blockNumber);
    if (dirty) self._state[poolId] = next;
    return fee;
}

/// @notice Compute the decaying fee for a new block whose (cached) price sits outside the optimal
///         range. Ported unchanged from `StableStableHook._calculateDecayingFee`.
/// @dev The decay start is selected from how the price moved since the previous checkpoint:
///        - Price just left the optimal range (sentinel) or jumped across the reference: start
///          from the far boundary.
///        - Price moved further from the reference: adjust the previous fee upward to preserve
///          the same pre-impact price, then decay from the adjusted fee.
///        - Price moved toward the reference, dropping the far boundary below the previous fee:
///          cap the start at the new far boundary.
///        - Otherwise: decay from the previous fee unchanged.
///      The start then decays exponentially toward the target fee.
/// @param config               The pool's fee config.
/// @param state                The pool's previous fee state checkpoint.
/// @param sqrtAmmPriceX96      The current AMM sqrt price (start-of-block).
/// @param sqrtReferencePriceX96 The reference sqrt price.
/// @param closeBoundaryFeeE12  The fee to reach the close boundary (positive: outside the range).
/// @param farBoundaryFeeE12    The fee to reach the far boundary.
/// @param ammPriceBelowRP      True if the current AMM price < reference price.
/// @param blockNumber          The current `BlockNumberish` block number.
/// @return decayingFeeE12 The decayed fee in 1e12 precision.
function computeOutsideRangeDecayingFee(
    FeeConfig storage config,
    FeeState storage state,
    uint256 sqrtAmmPriceX96,
    uint256 sqrtReferencePriceX96,
    uint256 closeBoundaryFeeE12,
    uint256 farBoundaryFeeE12,
    bool ammPriceBelowRP,
    uint256 blockNumber
) view returns (uint256 decayingFeeE12) {
    // Load the state checkpointed by the previous swapped block on this pool.
    uint256 previousSqrtAmmPriceX96 = state.sqrtAmmPriceX96;
    uint256 previousDecayingFeeE12 = state.decayingFeeE12;
    uint256 previousBlockNumber = state.blockNumber;

    // Determine the starting fee for exponential decay based on how the price moved since the
    // last swap.
    uint256 decayStartFeeE12;
    if (
        previousDecayingFeeE12 == FeeCalculation.UNDEFINED_DECAYING_FEE_E12
            || (previousSqrtAmmPriceX96 < sqrtReferencePriceX96) != ammPriceBelowRP
    ) {
        // Price just left the optimal range or jumped across the reference: start from the far
        // boundary.
        decayStartFeeE12 = farBoundaryFeeE12;
    } else if (ammPriceBelowRP == (sqrtAmmPriceX96 < previousSqrtAmmPriceX96)) {
        // Price moved further from the reference (left of ref and moved more left, OR right of
        // ref and moved more right). Adjust the fee upward to preserve the same pre-impact price,
        // then decay starts from the adjusted fee.
        uint256 priceMovementRatioX96 = FeeCalculation.calculatePriceRatioX96(sqrtAmmPriceX96, previousSqrtAmmPriceX96);
        decayStartFeeE12 =
            FeeCalculation.adjustPreviousFeeForPriceMovement(priceMovementRatioX96, previousDecayingFeeE12);
    } else if (previousDecayingFeeE12 > farBoundaryFeeE12) {
        // Price moved toward the reference, lowering farBoundaryFee below previousFee: cap at the
        // new far boundary.
        decayStartFeeE12 = farBoundaryFeeE12;
    } else {
        // Price moved toward the reference but previousFee is still within bounds: no adjustment.
        decayStartFeeE12 = previousDecayingFeeE12;
    }

    // Apply exponential decay toward the target. targetMultiplier (0-100) controls how
    // aggressively the target fee drops below farBoundaryFee as the price moves further from the
    // optimal range: 100 = full subtraction (tightest spread), 50 = half, 0 = no reduction.
    decayingFeeE12 = FeeCalculation.calculateDecayingFee(
        farBoundaryFeeE12 - closeBoundaryFeeE12 * config.targetMultiplier / MAX_TARGET_MULTIPLIER,
        decayStartFeeE12,
        config.k,
        config.logK,
        blockNumber - previousBlockNumber
    );
}
