// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {FeeCalculation} from "../../../src/stable/libraries/FeeCalculation.sol";
import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {FixedPoint96} from "@uniswap/v4-core/src/libraries/FixedPoint96.sol";

contract FeeCalculationTest is Test {
    uint24 constant OPTIMAL_FEE_RATE_E6 = 90; // 0.009%
    uint160 constant REFERENCE_SQRT_PRICE_X96 = uint160(FixedPoint96.Q96); // 1:1 price
    uint256 constant Q48 = 2 ** 48;

    function test_calculatePriceRatioX96_left_succeeds() public pure {
        uint160 sqrtAmmPriceX96 = (REFERENCE_SQRT_PRICE_X96 * 99) / 100; // 0.99 price
        uint256 priceRatioX96 = FeeCalculation.calculatePriceRatioX96(sqrtAmmPriceX96, REFERENCE_SQRT_PRICE_X96);

        // Ratio should be (0.99)^2 in Q96 format
        uint256 expected = ((sqrtAmmPriceX96 * Q48) / REFERENCE_SQRT_PRICE_X96) ** 2;
        assertEq(priceRatioX96, expected);

        // Ratio should be less than or equal to 2^96 (1)
        assertTrue(priceRatioX96 <= FixedPoint96.Q96);
    }

    function test_calculatePriceRatioX96_right_succeeds() public pure {
        uint160 sqrtAmmPriceX96 = (REFERENCE_SQRT_PRICE_X96 * 101) / 100; // 1.01 price
        uint256 priceRatioX96 = FeeCalculation.calculatePriceRatioX96(sqrtAmmPriceX96, REFERENCE_SQRT_PRICE_X96);

        // Ratio should be (1/1.01)^2 in Q96 format
        uint256 expected = ((REFERENCE_SQRT_PRICE_X96 * Q48) / sqrtAmmPriceX96) ** 2;
        assertEq(priceRatioX96, expected);

        // Ratio should be less than or equal to 2^96 (1)
        assertTrue(priceRatioX96 <= FixedPoint96.Q96);
    }

    function test_fuzz_calculatePriceRatioX96(uint160 sqrtAmmPriceX96, uint160 sqrtReferencePriceX96) public pure {
        sqrtAmmPriceX96 = uint160(bound(sqrtAmmPriceX96, TickMath.MIN_SQRT_PRICE, TickMath.MAX_SQRT_PRICE));
        sqrtReferencePriceX96 = uint160(bound(sqrtReferencePriceX96, TickMath.MIN_SQRT_PRICE, TickMath.MAX_SQRT_PRICE));

        uint256 priceRatioX96 = FeeCalculation.calculatePriceRatioX96(sqrtAmmPriceX96, sqrtReferencePriceX96);

        assertTrue(priceRatioX96 <= FixedPoint96.Q96);
    }

    function test_calculateCloseFee_succeeds_inside_optimal_rate() public pure {
        // Price very close to reference (should be inside optimal rate)
        uint160 priceRatioX96 = uint160(FixedPoint96.Q96); // Exactly at reference
        int256 closeFeeE12 = FeeCalculation.calculateCloseFee(priceRatioX96, OPTIMAL_FEE_RATE_E6);
        assertTrue(closeFeeE12 < 0);
    }

    function test_calculateCloseFee_succeeds_outside_optimal_rate() public pure {
        // at the boundary of the optimal range
        /// 1000000 - OPTIMAL_FEE_RATE_E6 = 999910
        uint160 priceRatioX96 = (uint160(REFERENCE_SQRT_PRICE_X96) * (1000000 - OPTIMAL_FEE_RATE_E6)) / 1000000; // the lower boundary of the optimal range
        int256 closeFeeE12 = FeeCalculation.calculateCloseFee(priceRatioX96, OPTIMAL_FEE_RATE_E6);
        assertTrue(closeFeeE12 > 0);

        // just inside the boundary of the optimal range (89)
        priceRatioX96 = (uint160(REFERENCE_SQRT_PRICE_X96) * (1000000 - (OPTIMAL_FEE_RATE_E6 - 1))) / 1000000;
        closeFeeE12 = FeeCalculation.calculateCloseFee(priceRatioX96, OPTIMAL_FEE_RATE_E6);
        assertTrue(closeFeeE12 < 0);
    }

    function test_fuzz_calculateCloseFee_succeeds(uint256 priceRatioX96, uint24 optimalFeeRateE6) public pure {
        priceRatioX96 = bound(priceRatioX96, 0, REFERENCE_SQRT_PRICE_X96);
        optimalFeeRateE6 = uint24(bound(optimalFeeRateE6, 0, 1e6 - 1));
        FeeCalculation.calculateCloseFee(priceRatioX96, optimalFeeRateE6); // should not revert
    }

    function test_fuzz_calculateInsideOptimalRateFee_succeeds(
        uint256 priceRatioX96,
        uint24 optimalFeeRateE6,
        bool ammPriceToTheLeft,
        bool userSellsZeroForOne
    ) public pure {
        optimalFeeRateE6 = uint24(bound(optimalFeeRateE6, 0, FeeCalculation.MAX_OPTIMAL_FEE_RATE_E6));

        // Calculate the minimum priceRatioX96 that's inside the optimal rate
        uint256 minPriceRatio =
            (uint256(FixedPoint96.Q96) * (FeeCalculation.ONE_E6 - optimalFeeRateE6)) / FeeCalculation.ONE_E6;

        // Bound priceRatioX96 to be inside the optimal rate
        priceRatioX96 = bound(priceRatioX96, minPriceRatio, REFERENCE_SQRT_PRICE_X96);

        uint256 totalStableFeeE12 = FeeCalculation.calculateInsideOptimalRateFee(
            priceRatioX96, optimalFeeRateE6, ammPriceToTheLeft, userSellsZeroForOne
        ); // should not revert

        assertTrue(totalStableFeeE12 <= FeeCalculation.ONE_E12);
    }
}
