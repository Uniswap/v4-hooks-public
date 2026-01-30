// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import {FixedPoint96} from "@uniswap/v4-core/src/libraries/FixedPoint96.sol";
import {StableLibrary} from "../libraries/StableLibrary.sol";
import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";

/// @title FeeCalculation
/// @notice Library providing core mathematical functions for calculating dynamic swap fees
library FeeCalculation {
    /// @notice Maximum supported fee in Uniswap format (990_000 = 99%)
    uint24 public constant MAX_FEE = 990_000;

    /// @notice Maximum allowed optimal fee rate
    /// @dev Optimal fee rate must be strictly less than PPM (100%).
    uint24 public constant MAX_OPTIMAL_FEE_RATE = PPM - 1;

    /// @notice Fixed-point scalar used for precision where 1e12 == 100%.
    uint40 internal constant ONE = 1e12;

    /// @notice Sentinel: no flexible fee (inside optimal rate).
    uint40 internal constant UNDEFINED_FLEXIBLE_FEE = ONE + 1;

    /// @notice Parts-per-million scalar (1e6 = 100%).
    uint24 internal constant PPM = 1e6;

    /// @notice Scale used to preserve precision in sqrt ratio math.
    uint64 internal constant Q48 = 2 ** 48;

    /// @notice Calculate the price ratio between AMM price and reference price in Q96 format
    /// @param sqrtAmmPriceX96 Current AMM sqrt price in Q96 format
    /// @param sqrtReferencePriceX96 Reference sqrt price in Q96 format
    /// @return priceRatioX96 Price ratio in Q96 format, always <= 2^96
    function calculatePriceRatioX96(uint160 sqrtAmmPriceX96, uint160 sqrtReferencePriceX96)
        internal
        pure
        returns (uint160 priceRatioX96)
    {
        // If AMM price < reference: sqrtPriceRatioX96 = (ammPrice/refPrice)
        // If AMM price >= reference: sqrtPriceRatioX96 = (refPrice/ammPrice)
        /// Multiply by Q48 to preserve precision
        uint160 sqrtPriceRatioX96 = sqrtAmmPriceX96 < sqrtReferencePriceX96
            ? uint160(uint256(sqrtAmmPriceX96) * Q48 / sqrtReferencePriceX96)
            : uint160(uint256(sqrtReferencePriceX96) * Q48 / sqrtAmmPriceX96);

        // Square to get full price ratio in Q96 format
        priceRatioX96 = sqrtPriceRatioX96 * sqrtPriceRatioX96;
    }

    /// @notice Calculate close fee - the fee that would place the effective price exactly at the "close" boundary.
    ///         The close boundary is whichever edge of the optimal rate is nearest to the current AMM price.
    /// @param priceRatioX96 Price ratio in Q96 format from calculatePriceRatioX96
    /// @param optimalFeeRate Optimal fee rate in parts per million (e.g., 90 = 0.009%). Cannot be >= 1e6.
    /// @return closeFee Fee at the "close" boundary. If <= 0, price is inside optimal rate. If > 0, price is outside.
    function calculateCloseFee(uint160 priceRatioX96, uint24 optimalFeeRate) internal pure returns (int40 closeFee) {
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
        closeFee = int40(
            int256(uint256(ONE)) - (int256(uint256(ONE)) * int256(uint256(priceRatioX96)) * int256(uint256(PPM)))
                / int256(uint256(PPM - optimalFeeRate)) / int256(uint256(FixedPoint96.Q96))
        );
    }

    /// @notice Calculate fee when price is inside optimal rate
    /// @param priceRatioX96 Price ratio in Q96 format
    /// @param optimalFeeRate Optimal fee rate in parts per million
    /// @param ammPriceToTheLeft True if AMM price < reference price
    /// @param userSellsZeroForOne True if user is selling token0 for token1
    /// @return fee Calculated fee in 1e12 precision
    function calculateInsideOptimalRateFee(
        uint160 priceRatioX96,
        uint24 optimalFeeRate,
        bool ammPriceToTheLeft,
        bool userSellsZeroForOne
    ) internal pure returns (uint40 fee) {
        // Note: This calculation assumes the price is inside the optimal rate.
        // (i.e., priceRatioX96 >= Q96 * (PPM - optimalFeeRate) / PPM

        // if userSellsZeroForOne => sellPrice = (1 - optimalFeeRate) * RP [lower bound]
        // ammPrice * (1 - fee) = (1 - optimalFeeRate) * RP
        // fee = 1 - (1 - optimalFeeRate) * RP / ammPrice

        // if !userSellsZeroForOne => buyPrice = RP / (1 - optimalFeeRate) [upper bound]
        // ammPrice / (1 - fee) = RP / (1 - optimalFeeRate)
        // fee = 1 - (1 - optimalFeeRate) * ammPrice / RP

        if (ammPriceToTheLeft == userSellsZeroForOne) {
            fee = uint40(ONE - (uint256(ONE) * (PPM - optimalFeeRate) * FixedPoint96.Q96) / priceRatioX96 / PPM);
        } else {
            fee = uint40(ONE - (uint256(ONE) * (PPM - optimalFeeRate) * priceRatioX96) / FixedPoint96.Q96 / PPM);
        }
    }

    /// @notice Calculate far fee - the fee that would place the effective price exactly at the "far" boundary.
    ///         The far boundary is whichever edge of the optimal rate is farthest from the current AMM price.
    /// @param priceRatioX96 Price ratio in Q96 format from calculatePriceRatioX96
    /// @param optimalFeeRate Optimal fee rate in parts per million
    /// @return farFee Fee to get to the "far" boundary
    function calculateFarFee(uint160 priceRatioX96, uint24 optimalFeeRate) internal pure returns (uint40 farFee) {
        // Case 1: ammPrice < RP
        //   - priceRatio = ammPrice / RP ≤ 1
        //   - Far boundary = RP / (1 - optimalFeeRate) [upper bound]
        //   - Target equation: ammPrice / (1 - farFee) = RP / (1 - optimalFeeRate)

        /// Case 2: ammPrice > RP
        //   - priceRatio = RP / ammPrice ≤ 1
        //   - Far boundary = RP * (1 - optimalFeeRate) [lower bound]
        //   - Target equation: ammPrice * (1 - farFee) = RP * (1 - optimalFeeRate)

        // Both cases use the same formula:
        //   farFee = 1 - (1 - optimalFeeRate) * priceRatio
        farFee = uint40(ONE - (uint256(ONE) * (PPM - optimalFeeRate) * priceRatioX96) / FixedPoint96.Q96 / PPM);
    }

    /// @notice Adjust previous fee for price movement
    /// @dev When price moves further from reference, adjust the previous fee to account for the movement
    /// @param previousFee Previous flexible fee
    /// @param sqrtAmmPriceX96 Current AMM sqrt price
    /// @param previousSqrtAmmPriceX96 Previous AMM sqrt price
    /// @param ammPriceToTheLeft True if current AMM price < reference price
    /// @return adjustedFee Adjusted previous fee accounting for price movement
    function adjustPreviousFeeForPriceMovement(
        uint40 previousFee,
        uint160 sqrtAmmPriceX96,
        uint160 previousSqrtAmmPriceX96,
        bool ammPriceToTheLeft
    ) internal pure returns (uint40 adjustedFee) {
        // Calculate ratio of price change (Q96 format)
        // IMPORTANT: Use uint256 to avoid truncation when squaring
        uint256 sqrtPriceRatio = ammPriceToTheLeft
            ? (uint256(sqrtAmmPriceX96) * Q48) / previousSqrtAmmPriceX96
            : (uint256(previousSqrtAmmPriceX96) * Q48) / sqrtAmmPriceX96;

        uint256 priceRatioX96 = sqrtPriceRatio * sqrtPriceRatio;

        // Adjust previous fee: adjustedFee = 1 - ratio * (1 - previousFee)
        adjustedFee = uint40(ONE - (priceRatioX96 * (ONE - previousFee)) / FixedPoint96.Q96);
    }

    /// @notice Calculate exponential decay factor for fee reduction over time
    /// @dev Uses fast computation for small block counts, exponential for large
    /// @param k Decay constant in Q24 format (e.g., 16_609_443 for k=0.99)
    /// @param logK Natural log of k scaled appropriately
    /// @param blocksPassed Number of blocks since last fee update
    /// @return factorX24 Decay factor in Q24 format (2^24 = no decay, 0 = full decay)
    function calculateDecayFactor(uint256 k, uint256 logK, uint256 blocksPassed)
        internal
        pure
        returns (uint256 factorX24)
    {
        if (blocksPassed <= 4) {
            // Fast path: Direct computation for small block counts
            factorX24 = StableLibrary.fastPow(k, blocksPassed);
        } else {
            // Slow path: Exponential computation for large block counts
            // exp(-logK * blocksPassed) scaled to Q24
            factorX24 = (uint256(FixedPointMathLib.expWad(-int256((logK << 40) * blocksPassed))) << 24) / 1e18;
        }
    }

    /// @notice Calculate flexible fee with exponential decay
    /// @dev Fee decays from previous fee toward target fee over time
    /// @param targetFee Target fee to decay toward
    /// @param previousFee Previous flexible fee
    /// @param factorX24 Decay factor in Q24 format from calculateDecayFactor
    /// @return flexibleFee New flexible fee after decay
    function calculateFlexibleFeeWithDecay(uint40 targetFee, uint40 previousFee, uint256 factorX24)
        internal
        pure
        returns (uint40 flexibleFee)
    {
        // flexibleFee = target + factor * (previous - target)
        flexibleFee = uint40(targetFee + ((uint256(factorX24) * (previousFee - targetFee)) >> 24));
    }

    /// @notice Convert internal fee format to Uniswap fee format
    /// @param internalFee Fee in internal format (1e12 = 100%)
    /// @return uniswapFee Fee in Uniswap format (1_000_000 = 100%, max 990_000)
    function convertToUniswapFee(uint40 internalFee) internal pure returns (uint24 uniswapFee) {
        // Convert from 1e12 to parts per million (1e12 / 1e6 = 1e6)
        uniswapFee = uint24(internalFee / PPM);

        // Cap at 99% (990_000 ppm)
        if (uniswapFee > MAX_FEE) {
            uniswapFee = MAX_FEE;
        }
    }
}
