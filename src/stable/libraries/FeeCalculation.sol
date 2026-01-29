// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

/// @title FeeCalculation
/// @notice Library providing core mathematical functions for calculating dynamic swap fees
library FeeCalculation {
    /// @notice Maximum supported fee in Uniswap format (990_000 = 99%)
    uint24 public constant MAX_FEE = 990_000;

    /// @notice Fixed-point scalar where 1e12 == 100%.
    uint40 internal constant ONE = 1e12;

    /// @notice Sentinel: no flexible fee (inside optimal spread).
    uint40 internal constant UNDEFINED_FLEXIBLE_FEE = ONE + 1;

    /// @notice Parts-per-million scalar (1e6).
    uint40 internal constant PPM = 1e6;

    /// @notice Scale used to preserve precision in sqrt ratio math.
    uint64 internal constant Q48 = 2 ** 48;

    /// @notice Fixed-point scalar used for price ratios (Q96).
    uint128 internal constant Q96 = 2 ** 96;

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
        uint160 sqrtPriceRatioX96 = sqrtAmmPriceX96 < sqrtReferencePriceX96
            ? uint160(uint256(sqrtAmmPriceX96) * Q48 / sqrtReferencePriceX96)
            : uint160(uint256(sqrtReferencePriceX96) * Q48 / sqrtAmmPriceX96);

        // Square to get full price ratio in Q96 format
        priceRatioX96 = sqrtPriceRatioX96 * sqrtPriceRatioX96;
    }

    /// @notice Calculate close fee
    /// @param priceRatioX96 Price ratio in Q96 format from calculatePriceRatioX96
    /// @param optimalFeeRate Optimal fee rate in parts per million (e.g., 90 = 0.009%)
    /// @return closeFee Fee at the close boundary (negative if inside optimal range)
    function calculateCloseFee(uint160 priceRatioX96, uint24 optimalFeeRate) internal pure returns (int40 closeFee) {
        // We derive closeFee such that after applying fees, the effective price equals
        // the boundary price defined by optimalFeeRate.

        // Case 1: ammPriceToTheLeft (user buys token0, pushing price UP toward reference)
        //   - priceRatio = ammPrice / referencePrice ≤ 1
        //   - Target: ammPrice / (1 - closeFee) = referencePrice * (1 - optimalFeeRate)

        // Case 2: !ammPriceToTheLeft (user sells token0, pushing price DOWN toward reference)
        //   - priceRatio = referencePrice / ammPrice ≤ 1
        //   - Target: ammPrice * (1 - closeFee) = referencePrice / (1 - optimalFeeRate)

        // Both cases simplify to the same formula:
        //   closeFee = 1 - priceRatio / (1 - optimalFeeRate)
        closeFee = int40(
            int256(uint256(ONE)) - (int256(uint256(ONE)) * int256(uint256(priceRatioX96)) * int256(uint256(PPM)))
                / int256(uint256(PPM - optimalFeeRate)) / int256(uint256(Q96))
        );
    }

    /// @notice Calculate fee when price is inside optimal spread
    /// @param priceRatioX96 Price ratio in Q96 format
    /// @param optimalFeeRate Optimal fee rate in parts per million
    /// @param ammPriceToTheLeft True if AMM price < reference price
    /// @param userSellsZeroForOne True if user is selling token0 for token1
    /// @return fee Calculated fee in 1e12 precision
    function calculateInsideOptimalSpreadFee(
        uint160 priceRatioX96,
        uint24 optimalFeeRate,
        bool ammPriceToTheLeft,
        bool userSellsZeroForOne
    ) internal pure returns (uint40 fee) {
        // Note: This calculation assumes the price is inside the optimal spread.
        // (i.e., priceRatioX96 >= Q96 * (PPM - optimalFeeRate) / PPM, or closeFee <= 0)

        // if userSellsZeroForOne => sellPrice = (1 - optimalFeeSpread) * RP
        // ammPrice * (1 - fee) = (1 - optimalFeeSpread) * RP
        // fee = 1 - (1 - optimalFeeSpread) * RP / ammPrice

        // if !userSellsZeroForOne => buyPrice = RP / (1 - optimalFeeSpread)
        // ammPrice / (1 - fee) = RP / (1 - optimalFeeSpread)
        // fee = 1 - (1 - optimalFeeSpread) * ammPrice / RP

        if (ammPriceToTheLeft == userSellsZeroForOne) {
            fee = uint40(ONE - (uint256(ONE) * (PPM - optimalFeeRate) * Q96) / priceRatioX96 / PPM);
        } else {
            fee = uint40(ONE - (uint256(ONE) * (PPM - optimalFeeRate) * priceRatioX96) / Q96 / PPM);
        }
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
