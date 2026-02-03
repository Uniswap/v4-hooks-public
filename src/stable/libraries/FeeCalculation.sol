// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import {FixedPoint96} from "@uniswap/v4-core/src/libraries/FixedPoint96.sol";

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

    /// @notice Calculate the price ratio between AMM price and reference price in Q96 format
    /// @param sqrtAmmPriceX96 Current AMM sqrt price in Q96 format
    /// @param sqrtReferencePriceX96 Reference sqrt price in Q96 format
    /// @return priceRatioX96 Price ratio in Q96 format, always <= 2^96
    function calculatePriceRatioX96(uint256 sqrtAmmPriceX96, uint256 sqrtReferencePriceX96)
        internal
        pure
        returns (uint256 priceRatioX96)
    {
        // If AMM price < reference: sqrtPriceRatioX96 = (ammPrice/refPrice)
        // If AMM price >= reference: sqrtPriceRatioX96 = (refPrice/ammPrice)
        /// Multiply by Q48 to preserve precision
        uint256 sqrtPriceRatioX96 = sqrtAmmPriceX96 < sqrtReferencePriceX96
            ? sqrtAmmPriceX96 * Q48 / sqrtReferencePriceX96
            : sqrtReferencePriceX96 * Q48 / sqrtAmmPriceX96;

        // Square to get full price ratio in Q96 format
        priceRatioX96 = sqrtPriceRatioX96 * sqrtPriceRatioX96;
    }

    /// @notice Calculate close fee - the fee that would place the effective price exactly at the "close" boundary.
    ///         The close boundary is whichever edge of the optimal rate is nearest to the current AMM price.
    /// @param priceRatioX96 Price ratio in Q96 format from calculatePriceRatioX96
    /// @param optimalFeeRateE6 Optimal fee rate in parts per million (e.g., 90 = 0.009%). Cannot be >= 1e6.
    /// @return closeFeeE12 Fee at the "close" boundary in 1e12. If <= 0, price is inside optimal rate. If > 0, price is outside.
    function calculateCloseFee(uint256 priceRatioX96, uint256 optimalFeeRateE6)
        internal
        pure
        returns (int256 closeFeeE12)
    {
        // Case 1: ammPrice < RP (price to the left)
        //   - priceRatio = ammPrice / RP ≤ 1
        //   - Close boundary = RP * (1 - optimalFeeRate) [lower bound]
        //   - Target equation: ammPrice / (1 - closeFee) = RP * (1 - optimalFeeRate)

        // Case 2: ammPrice > RP (price to the right)
        //   - priceRatio = RP / ammPrice ≤ 1
        //   - Close boundary = RP / (1 - optimalFeeRate) [upper bound]
        //   - Target equation: ammPrice * (1 - closeFee) = RP / (1 - optimalFeeRate)

        // Both cases use the same formula:
        //   closeFee = 1 - priceRatio / (1 - optimalFeeRate)
        closeFeeE12 = int256(ONE_E12)
            - int256((ONE_E12 * priceRatioX96 * ONE_E6) / (ONE_E6 - optimalFeeRateE6) / FixedPoint96.Q96);
    }

    /// @notice Calculate fee when price is inside optimal rate
    /// @param priceRatioX96 Price ratio in Q96 format
    /// @param optimalFeeRateE6 Optimal fee rate in parts per million
    /// @param ammPriceToTheLeft True if AMM price < reference price
    /// @param userSellsZeroForOne True if user is selling token0 for token1
    /// @return feeE12 Calculated fee in 1e12 precision
    function calculateInsideOptimalRateFee(
        uint256 priceRatioX96,
        uint256 optimalFeeRateE6,
        bool ammPriceToTheLeft,
        bool userSellsZeroForOne
    ) internal pure returns (uint256 feeE12) {
        // Note: This calculation assumes the price is inside the optimal rate.
        // (i.e., priceRatioX96 >= Q96 * (ONE_E6 - optimalFeeRateE6) / ONE_E6

        // if userSellsZeroForOne => sellPrice = (1 - optimalFeeRate) * RP [lower bound]
        // ammPrice * (1 - fee) = (1 - optimalFeeRate) * RP
        // fee = 1 - (1 - optimalFeeRate) * RP / ammPrice

        // if !userSellsZeroForOne => buyPrice = RP / (1 - optimalFeeRate) [upper bound]
        // ammPrice / (1 - fee) = RP / (1 - optimalFeeRate)
        // fee = 1 - (1 - optimalFeeRate) * ammPrice / RP

        if (ammPriceToTheLeft == userSellsZeroForOne) {
            feeE12 = ONE_E12 - (ONE_E12 * (ONE_E6 - optimalFeeRateE6) * FixedPoint96.Q96) / priceRatioX96 / ONE_E6;
        } else {
            feeE12 = ONE_E12 - (ONE_E12 * (ONE_E6 - optimalFeeRateE6) * priceRatioX96) / FixedPoint96.Q96 / ONE_E6;
        }
    }
}
