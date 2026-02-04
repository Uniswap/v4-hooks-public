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

    /// @notice Sentinel: no flexible fee (inside optimal rate)
    uint256 internal constant UNDEFINED_FLEXIBLE_FEE_E12 = ONE_E12 + 1;

    /// @notice Maximum allowed optimal fee rate in pips
    /// @dev Optimal fee rate must be strictly less than ONE_E6 (100%).
    uint256 public constant MAX_OPTIMAL_FEE_RATE_E6 = ONE_E6 - 1;

    /// @notice Scale used to preserve precision in sqrt ratio math.
    uint256 internal constant Q48 = 2 ** 48;

    /// @notice Calculate the price ratio between two sqrt prices in Q96 format
    /// @dev Always returns min(price1, price2) / max(price1, price2), ensuring result <= 2^96
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

    /// @notice Calculate close fee - the fee that would place the effective price exactly at the "close" boundary.
    ///         The close boundary is whichever edge of the optimal rate is nearest to the current AMM price.
    /// @param priceRatioX96 Price ratio in Q96 format from calculatePriceRatioX96, must be >= Q96
    /// @param optimalFeeE6 Optimal fee rate in parts per million (e.g., 90 = 0.009%). Cannot be >= 1e6.
    /// @return closeFeeE12 Fee at the "close" boundary in 1e12. If <= 0, price is inside optimal rate. If > 0, price is outside.
    function calculateCloseFee(uint256 priceRatioX96, uint256 optimalFeeE6) internal pure returns (int256 closeFeeE12) {
        // Case 1: ammPrice < RP (price to the left)
        //   - priceRatio = ammPrice / RP ≤ 1
        //   - Close boundary = RP * (1 - optimalFee) [lower bound]
        //   - Target equation: ammPrice / (1 - closeFee) = RP * (1 - optimalFee)

        // Case 2: ammPrice > RP (price to the right)
        //   - priceRatio = RP / ammPrice ≤ 1
        //   - Close boundary = RP / (1 - optimalFee) [upper bound]
        //   - Target equation: ammPrice * (1 - closeFee) = RP / (1 - optimalFee)

        // Both cases use the same formula:
        //   closeFee = 1 - priceRatio / (1 - optimalFee)
        closeFeeE12 =
            int256(ONE_E12) - int256((ONE_E12 * priceRatioX96 * ONE_E6) / (ONE_E6 - optimalFeeE6) / FixedPoint96.Q96);
    }

    /// @notice Calculate fee when price is inside optimal rate
    /// @param priceRatioX96 Price ratio in Q96 format
    /// @param optimalFeeE6 Optimal fee rate in parts per million
    /// @param ammPriceToTheLeft True if AMM price < reference price
    /// @param userSellsZeroForOne True if user is selling token0 for token1
    /// @return feeE12 Calculated fee in 1e12 precision
    function calculateInsideOptimalRateFee(
        uint256 priceRatioX96,
        uint256 optimalFeeE6,
        bool ammPriceToTheLeft,
        bool userSellsZeroForOne
    ) internal pure returns (uint256 feeE12) {
        // Note: This calculation assumes the price is inside the optimal rate.
        // (i.e., priceRatioX96 >= Q96 * (ONE_E6 - optimalFee) / ONE_E6

        // if userSellsZeroForOne => sellPrice = (1 - optimalFee) * RP [lower bound]
        // ammPrice * (1 - fee) = (1 - optimalFee) * RP
        // fee = 1 - (1 - optimalFee) * RP / ammPrice

        // if !userSellsZeroForOne => buyPrice = RP / (1 - optimalFee) [upper bound]
        // ammPrice / (1 - fee) = RP / (1 - optimalFee)
        // fee = 1 - (1 - optimalFee) * ammPrice / RP

        if (ammPriceToTheLeft == userSellsZeroForOne) {
            feeE12 = ONE_E12 - (ONE_E12 * (ONE_E6 - optimalFeeE6) * FixedPoint96.Q96) / priceRatioX96 / ONE_E6;
        } else {
            feeE12 = ONE_E12 - (ONE_E12 * (ONE_E6 - optimalFeeE6) * priceRatioX96) / FixedPoint96.Q96 / ONE_E6;
        }
    }

    /// @notice Calculate far fee - the fee that would place the effective price exactly at the "far" boundary.
    ///         The far boundary is whichever edge of the optimal rate is farthest from the current AMM price.
    /// @param priceRatioX96 Price ratio in Q96 format from calculatePriceRatioX96, must be >= Q96
    /// @param optimalFeeE6 Optimal fee rate in parts per million
    /// @return farFeeE12 Fee to get to the "far" boundary in 1e12 precision
    function calculateFarFee(uint256 priceRatioX96, uint256 optimalFeeE6) internal pure returns (uint256 farFeeE12) {
        // Case 1: ammPrice < RP
        //   - priceRatio = ammPrice / RP ≤ 1
        //   - Far boundary = RP / (1 - optimalFee) [upper bound]
        //   - Target equation: ammPrice / (1 - farFee) = RP / (1 - optimalFee)

        /// Case 2: ammPrice > RP
        //   - priceRatio = RP / ammPrice ≤ 1
        //   - Far boundary = RP * (1 - optimalFee) [lower bound]
        //   - Target equation: ammPrice * (1 - farFee) = RP * (1 - optimalFee)

        // Both cases use the same formula:
        //   farFee = 1 - (1 - optimalFee) * priceRatio
        farFeeE12 = ONE_E12 - (ONE_E12 * (ONE_E6 - optimalFeeE6) * priceRatioX96) / FixedPoint96.Q96 / ONE_E6;
    }

    /// @notice Adjust previous fee for price movement
    /// @dev When price moves further from reference, adjust the previous fee to account for the movement
    /// @param previousFeeE12 Previous flexible fee in 1e12 precision
    /// @param priceRatioX96 Price ratio in Q96 format from calculatePriceRatioX96, must be >= Q96
    /// @return adjustedFeeE12 Adjusted previous fee accounting for price movement in 1e12 precision
    function adjustPreviousFeeForPriceMovement(uint256 priceRatioX96, uint256 previousFeeE12)
        internal
        pure
        returns (uint256 adjustedFeeE12)
    {
        // Adjust previous fee: adjustedFee = 1 - priceRatio * (1 - previousFee)
        adjustedFeeE12 = ONE_E12 - (priceRatioX96 * (ONE_E12 - previousFeeE12)) / FixedPoint96.Q96;
    }

    /// @notice Calculate flexible fee with exponential decay
    /// @dev Fee decays from previous fee toward target fee over time
    /// @param targetFeeE12 Target fee to decay toward in 1e12 precision
    /// @param previousFeeE12 Previous flexible fee in 1e12 precision
    /// @param k Decay constant in Q24 format (e.g., 16_609_443 for k=0.99)
    /// @param logK Natural log of k scaled appropriately
    /// @param blocksPassed Number of blocks since last fee update
    /// @return flexibleFeeE12 New flexible fee after decay in 1e12 precision
    function calculateFlexibleFee(
        uint256 targetFeeE12,
        uint256 previousFeeE12,
        uint256 k,
        uint256 logK,
        uint256 blocksPassed
    ) internal pure returns (uint256 flexibleFeeE12) {
        uint256 factorX24;
        if (blocksPassed <= 4) {
            // Fast path: Direct computation for small block counts
            factorX24 = fastPow(k, blocksPassed);
        } else {
            // Slow path: Exponential computation for large block counts
            // exp(-logK * blocksPassed) scaled to Q24
            factorX24 = (uint256(FixedPointMathLib.expWad(-int256((logK << 40) * blocksPassed))) << 24) / 1e18;
        }

        // flexibleFee = target + factor * (previous - target)
        flexibleFeeE12 = targetFeeE12 + ((factorX24 * (previousFeeE12 - targetFeeE12)) >> 24);
    }

    /// @notice Calculate the fast power of k to the power of blocksPassed
    /// @param k The base of the power
    /// @param blocksPassed The power to raise k to. Must be <= 4.
    /// @return z The result of k to the power of blocksPassed
    // @dev the split in two with this special case saves 110 gas, see factor() in (Stable)HookParams
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
