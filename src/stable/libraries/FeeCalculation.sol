// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import {FixedPoint96} from "@uniswap/v4-core/src/libraries/FixedPoint96.sol";
import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";

/// @title FeeCalculation
/// @notice Library providing core mathematical functions for calculating dynamic swap fees
library FeeCalculation {
    /// @notice Scalar for pips precision (1e6 = 100%)
    uint256 internal constant ONE_E6 = 1e6;

    /// @notice Scalar for scaled precision (1e12 = 100%)
    uint256 internal constant ONE_E12 = 1e12;

    /// @notice Sentinel: no decaying fee (inside optimal range).
    uint256 internal constant UNDEFINED_DECAYING_FEE_E12 = ONE_E12 + 1;

    /// @notice Scale used to preserve precision in sqrt ratio math.
    uint256 internal constant Q48 = 2 ** 48;

    /// @notice Calculate the price ratio between two sqrt prices in Q96 format, ensuring result <= 2^96
    /// @param sqrtPrice1X96 First sqrt price in Q96 format
    /// @param sqrtPrice2X96 Second sqrt price in Q96 format
    /// @return priceRatioX96 Price ratio in Q96 format, always <= 2^96
    function calculatePriceRatioX96(uint256 sqrtPrice1X96, uint256 sqrtPrice2X96)
        internal
        pure
        returns (uint256 priceRatioX96)
    {
        /// Multiply by Q48 to preserve precision
        uint256 sqrtPriceRatioX96 =
            sqrtPrice1X96 < sqrtPrice2X96 ? sqrtPrice1X96 * Q48 / sqrtPrice2X96 : sqrtPrice2X96 * Q48 / sqrtPrice1X96;

        // Square to get full price ratio in Q96 format
        priceRatioX96 = sqrtPriceRatioX96 * sqrtPriceRatioX96;
    }

    /// @notice Calculate close boundary fee
    /// @dev Returns negative if price is inside optimal range (negative fee), positive if outside
    ///      The numeric value represents the fee to reach the close boundary:
    ///      - Negative: Inside range, fee to nearest boundary (already crossed it)
    ///      - Positive: Outside range, fee to nearest boundary (not yet reached)
    /// @param ammToRPRatioX96 Price ratio to reference price in Q96 format
    /// @param optimalFeeE6 Optimal fee rate in parts per million
    /// @return fee Close boundary fee in 1e12 precision, can be negative
    function _calculateCloseBoundaryFee(uint160 ammToRPRatioX96, uint24 optimalFeeE6)
        private
        pure
        returns (int256 fee)
    {
        // Formula: fee = 1 - priceRatio / (1 - optimalFeeE6)
        // Step-by-step breakdown:
        //   1. numerator = ammToRPRatioX96 * ONE_E6 (scale ratio to ONE_E6-compatible units)
        //   2. denominator = (ONE_E6 - optimalFeeE6) * Q96 (scale optimal rate complement to Q96)
        //   3. fraction = numerator / denominator (compute priceRatio / (1 - optimalRate))
        //   4. fee = ONE_E12 - fraction (complete the formula)
        //
        // All calculations use int256 to preserve sign for potentially negative results
        fee = int256(uint256(ONE_E12))
            - (int256(uint256(ONE_E12)) * int256(uint256(ammToRPRatioX96)) * int256(uint256(ONE_E6)))
            / int256(uint256(ONE_E6 - optimalFeeE6)) / int256(uint256(FixedPoint96.Q96));
    }

    /// @notice Calculate fee to reach an optimal range boundary
    /// @dev Used for both far boundary and inside optimal range fee calculations
    /// @param ammToRPRatioX96 Price ratio to reference price in Q96 format
    /// @param optimalFeeE6 Optimal fee rate in parts per million
    /// @param invertRatio If true, use inverted ratio (Q96 / priceRatio instead of priceRatio)
    /// @return fee Calculated fee in 1e12 precision, always non-negative
    function _calculateFeeToOptimalBoundary(uint256 ammToRPRatioX96, uint256 optimalFeeE6, bool invertRatio)
        private
        pure
        returns (uint40 fee)
    {
        // Formula: fee = 1 - (1 - optimalFeeE6) * ratio
        // Where ratio is either:
        //   - ammToRPRatioX96 (direct, when invertRatio = false)
        //   - Q96^2 / ammToRPRatioX96 (inverted, when invertRatio = true)
        //
        // WHY INVERT THE RATIO?
        // ammToRPRatioX96 is always normalized as min(ammPrice, RP) / max(ammPrice, RP) to ensure it's ≤ 1.
        // However, the fee formula needs the ratio in a specific orientation (ammPrice/RP or RP/ammPrice)
        // depending on which boundary we're targeting:
        //   - If swap direction moves price toward the boundary, use RP/ammPrice (inverted)
        //   - If swap direction moves price away from boundary, use ammPrice/RP (direct)
        // This ensures the fee calculation references the correct optimal range edge (upper or lower bound)
        // based on the trade direction relative to the reference price.
        uint256 adjustedRate = ONE_E6 - optimalFeeE6;

        uint256 scaledValue;
        if (invertRatio) {
            // Inverted ratio case: use Q96 / priceRatio
            scaledValue = (uint256(ONE_E12) * adjustedRate * FixedPoint96.Q96) / ammToRPRatioX96 / ONE_E6;
        } else {
            // Direct ratio case: use priceRatio
            scaledValue = (uint256(ONE_E12) * adjustedRate * ammToRPRatioX96) / FixedPoint96.Q96 / ONE_E6;
        }

        fee = uint40(ONE_E12 - scaledValue);
    }

    /// @notice Calculate close boundary fee - measures the fee to reach the close boundary of the optimal range.
    ///         Returns a fee metric where negative values mean inside the range, positive means outside.
    /// @param ammToRPRatioX96 Price ratio to reference price in Q96 format from calculatePriceRatioX96
    /// @param optimalFeeE6 Optimal fee in parts per million (e.g., 90 = 0.009%). Cannot be >= 1e6.
    /// @return closeBoundaryFeeE12 Close boundary fee. If <= 0, price is inside optimal range. If > 0, price is outside.
    function calculateCloseBoundaryFee(uint256 ammToRPRatioX96, uint256 optimalFeeE6)
        internal
        pure
        returns (int256 closeBoundaryFeeE12)
    {
        // Case 1: ammPrice < RP (price to the left)
        //   - priceRatio = ammPrice / RP ≤ 1
        //   - Close boundary = RP * (1 - optimalFee) [lower bound]
        //   - Target equation: ammPrice / (1 - closeBoundaryFeeE12) = RP * (1 - optimalFee)

        // Case 2: ammPrice > RP (price to the right)
        //   - priceRatio = RP / ammPrice ≤ 1
        //   - Close boundary = RP / (1 - optimalFee) [upper bound]
        //   - Target equation: ammPrice * (1 - closeBoundaryFeeE12) = RP / (1 - optimalFee)

        // Both cases use the same formula:
        //   closeBoundaryFeeE12 = 1 - priceRatio / (1 - optimalFee)
        closeBoundaryFeeE12 =
            int256(ONE_E12) - int256((ONE_E12 * ammToRPRatioX96 * ONE_E6) / (ONE_E6 - optimalFeeE6) / FixedPoint96.Q96);
    }

    /// @notice Calculate fee when price is inside optimal range
    /// @param ammToRPRatioX96 Price ratio in Q96 format
    /// @param optimalFeeE6 Optimal fee in parts per million
    /// @param ammPriceToTheLeft True if AMM price < reference price
    /// @param userSellsZeroForOne True if user is selling token0 for token1
    /// @return feeE12 Calculated fee in 1e12 precision
    function calculateInsideOptimalRangeFee(
        uint256 ammToRPRatioX96,
        uint256 optimalFeeE6,
        bool ammPriceToTheLeft,
        bool userSellsZeroForOne
    ) internal pure returns (uint256 feeE12) {
        // Note: This calculation assumes the price is inside the optimal range.
        // (i.e., ammToRPRatioX96 >= Q96 * (ONE_E6 - optimalFee) / ONE_E6

        // if userSellsZeroForOne => sellPrice = (1 - optimalFee) * RP [lower bound]
        // ammPrice * (1 - fee) = (1 - optimalFee) * RP
        // fee = 1 - (1 - optimalFee) * RP / ammPrice

        // if !userSellsZeroForOne => buyPrice = RP / (1 - optimalFee) [upper bound]
        // ammPrice / (1 - fee) = RP / (1 - optimalFee)
        // fee = 1 - (1 - optimalFee) * ammPrice / RP

        // When ammPriceToTheLeft == userSellsZeroForOne, we need the inverted ratio
        bool invertRatio = (ammPriceToTheLeft == userSellsZeroForOne);
        feeE12 = _calculateFeeToOptimalBoundary(ammToRPRatioX96, optimalFeeE6, invertRatio);
    }

    /// @notice Calculate far boundary fee - the fee that would place the effective price exactly at the "far" boundary.
    ///         The far boundary is whichever edge of the optimal range is farthest from the current AMM price.
    /// @param ammToRPRatioX96 Price ratio in Q96 format from calculatePriceRatioX96, must be <= Q96
    /// @param optimalFeeE6 Optimal fee in parts per million
    /// @return farBoundaryFeeE12 Fee to get to the "far" boundary in 1e12 precision
    function calculateFarBoundaryFee(uint256 ammToRPRatioX96, uint256 optimalFeeE6)
        internal
        pure
        returns (uint256 farBoundaryFeeE12)
    {
        // Case 1: ammPrice < RP
        //   - priceRatio = ammPrice / RP ≤ 1
        //   - Far boundary = RP / (1 - optimalFee) [upper bound]
        //   - Target equation: ammPrice / (1 - farBoundaryFee) = RP / (1 - optimalFee)

        /// Case 2: ammPrice > RP
        //   - priceRatio = RP / ammPrice ≤ 1
        //   - Far boundary = RP * (1 - optimalFee) [lower bound]
        //   - Target equation: ammPrice * (1 - farBoundaryFee) = RP * (1 - optimalFee)

        // Both cases use the same formula:
        //   farBoundaryFee = 1 - (1 - optimalFeeE6) * priceRatio
        farBoundaryFeeE12 = _calculateFeeToOptimalBoundary(ammToRPRatioX96, optimalFeeE6, false);
    }

    /// @notice Adjust previous fee to preserve the same effective price when AMM price moves further from reference
    /// @param ammToRPRatioX96 Price ratio in Q96 format from calculatePriceRatioX96 (always <= Q96 since it's min/max)
    /// @param previousFeeE12 Previous flexible fee in 1e12 precision
    /// @return adjustedFeeE12 Adjusted previous fee accounting for price movement in 1e12 precision
    function adjustPreviousFeeForPriceMovement(uint256 ammToRPRatioX96, uint256 previousFeeE12)
        internal
        pure
        returns (uint256 adjustedFeeE12)
    {
        // Adjust previous fee: adjustedFee = 1 - priceRatio * (1 - previousFee)
        adjustedFeeE12 = ONE_E12 - (ammToRPRatioX96 * (ONE_E12 - previousFeeE12)) / FixedPoint96.Q96;
    }

    /// @notice Calculate flexible fee with exponential decay. Fee decays from previous fee toward target fee over time.
    /// @param targetFeeE12 Target fee to decay toward in 1e12 precision
    /// @param previousFeeE12 Previous flexible fee in 1e12 precision, previousFee >= targetFee
    /// @param k Decay constant in Q24 format (e.g., 16_609_443 for k=0.99), <= Q24
    /// @param logK Natural log of k scaled appropriately
    /// @param blocksPassed Number of blocks since last fee update, <= type(uint40).max
    /// @return decayingFeeE12 New flexible fee after decay in 1e12 precision
    function calculateDecayingFee(
        uint256 targetFeeE12,
        uint256 previousFeeE12,
        uint256 k,
        uint256 logK,
        uint256 blocksPassed
    ) internal pure returns (uint256 decayingFeeE12) {
        uint256 factorX24;
        if (blocksPassed <= 4) {
            // Fast path: Direct computation for small block counts
            factorX24 = fastPow(k, blocksPassed);
        } else {
            // Slow path: Exponential computation for large block counts
            // exp(-logK * blocksPassed) scaled to Q24
            factorX24 = (uint256(FixedPointMathLib.expWad(-int256((logK << 40) * blocksPassed))) << 24) / 1e18;
        }

        // decayingFee = target + factor * (previous - target)
        decayingFeeE12 = targetFeeE12 + ((factorX24 * (previousFeeE12 - targetFeeE12)) >> 24);
    }

    /// @notice Calculate the fast power of k to the power of blocksPassed
    /// @param k The base of the power
    /// @param blocksPassed The power to raise k to. Must be <= 4.
    /// @return z The result of k to the power of blocksPassed
    function fastPow(uint256 k, uint256 blocksPassed) internal pure returns (uint256 z) {
        assembly {
            switch blocksPassed
            case 1 { z := k }
            case 2 { z := shr(24, mul(k, k)) }
            case 3 {
                let zz := mul(k, k)
                z := shr(48, mul(k, zz))
            }
            case 4 {
                let zz := mul(k, k)
                z := shr(72, mul(zz, zz))
            }
            case 0 { z := shl(24, 1) }
        }
    }
}
