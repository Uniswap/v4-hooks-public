// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {FeeCalculation} from "../../../src/stable/libraries/FeeCalculation.sol";
import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {FixedPoint96} from "@uniswap/v4-core/src/libraries/FixedPoint96.sol";

contract FeeCalculationTest is Test {
    uint40 constant ONE = 1e12;
    uint24 constant OPTIMAL_FEE_RATE = 90; // 0.009%
    uint160 constant REFERENCE_SQRT_PRICE_X96 = uint160(FixedPoint96.Q96); // 1:1 price
    uint256 constant Q48 = 2 ** 48;

    function test_calculatePriceRatioX96_left_succeeds() public pure {
        uint160 sqrtAmmPriceX96 = (REFERENCE_SQRT_PRICE_X96 * 99) / 100; // 0.99 price
        uint160 priceRatioX96 = FeeCalculation.calculatePriceRatioX96(sqrtAmmPriceX96, REFERENCE_SQRT_PRICE_X96);

        // Ratio should be (0.99)^2 in Q96 format
        uint160 expected = uint160((uint256(sqrtAmmPriceX96) * Q48) / REFERENCE_SQRT_PRICE_X96) ** 2;
        assertEq(priceRatioX96, expected);

        // Ratio should be less than or equal to 2^96 (1)
        assertTrue(priceRatioX96 <= FixedPoint96.Q96);
    }

    function test_calculatePriceRatioX96_right_succeeds() public pure {
        uint160 sqrtAmmPriceX96 = (REFERENCE_SQRT_PRICE_X96 * 101) / 100; // 1.01 price
        uint160 priceRatioX96 = FeeCalculation.calculatePriceRatioX96(sqrtAmmPriceX96, REFERENCE_SQRT_PRICE_X96);

        // Ratio should be (1/1.01)^2 in Q96 format
        uint160 expected = uint160((uint256(REFERENCE_SQRT_PRICE_X96) * Q48) / sqrtAmmPriceX96) ** 2;
        assertEq(priceRatioX96, expected);

        // Ratio should be less than or equal to 2^96 (1)
        assertTrue(priceRatioX96 <= FixedPoint96.Q96);
    }

    function test_fuzz_calculatePriceRatioX96(uint160 sqrtAmmPriceX96, uint160 sqrtReferencePriceX96) public pure {
        sqrtAmmPriceX96 = uint160(bound(sqrtAmmPriceX96, TickMath.MIN_SQRT_PRICE, TickMath.MAX_SQRT_PRICE));
        sqrtReferencePriceX96 = uint160(bound(sqrtReferencePriceX96, TickMath.MIN_SQRT_PRICE, TickMath.MAX_SQRT_PRICE));

        uint160 priceRatioX96 = FeeCalculation.calculatePriceRatioX96(sqrtAmmPriceX96, sqrtReferencePriceX96);

        assertTrue(priceRatioX96 <= FixedPoint96.Q96);
    }

    function test_calculateCloseFee_succeeds_inside_optimal_rate() public pure {
        // Price very close to reference (should be inside optimal rate)
        uint160 priceRatioX96 = uint160(FixedPoint96.Q96); // Exactly at reference
        int40 closeFee = FeeCalculation.calculateCloseFee(priceRatioX96, OPTIMAL_FEE_RATE);
        assertTrue(closeFee < 0);
    }

    function test_calculateCloseFee_succeeds_outside_optimal_rate() public pure {
        // at the boundary of the optimal range
        /// 1000000 - OPTIMAL_FEE_RATE = 999910
        uint160 priceRatioX96 = (uint160(REFERENCE_SQRT_PRICE_X96) * (1000000 - OPTIMAL_FEE_RATE)) / 1000000; // the lower boundary of the optimal range
        int40 closeFee = FeeCalculation.calculateCloseFee(priceRatioX96, OPTIMAL_FEE_RATE);
        assertTrue(closeFee > 0);

        // just inside the boundary of the optimal range (89)
        priceRatioX96 = (uint160(REFERENCE_SQRT_PRICE_X96) * (1000000 - (OPTIMAL_FEE_RATE - 1))) / 1000000;
        closeFee = FeeCalculation.calculateCloseFee(priceRatioX96, OPTIMAL_FEE_RATE);
        assertTrue(closeFee < 0);
    }

    function test_fuzz_calculateCloseFee_succeeds(uint160 priceRatioX96, uint24 optimalFeeRate) public pure {
        priceRatioX96 = uint160(bound(priceRatioX96, 0, REFERENCE_SQRT_PRICE_X96));
        optimalFeeRate = uint24(bound(optimalFeeRate, 0, 1e6 - 1));
        FeeCalculation.calculateCloseFee(priceRatioX96, optimalFeeRate); // should not revert
    }

    function test_fuzz_calculateInsideOptimalRateFee_succeeds(
        uint160 priceRatioX96,
        uint24 optimalFeeRate,
        bool ammPriceToTheLeft,
        bool userSellsZeroForOne
    ) public pure {
        optimalFeeRate = uint24(bound(optimalFeeRate, 0, FeeCalculation.MAX_OPTIMAL_FEE_RATE));

        // Calculate the minimum priceRatioX96 that's inside the optimal rate
        uint256 minPriceRatio = (uint256(FixedPoint96.Q96) * (FeeCalculation.PPM - optimalFeeRate)) / FeeCalculation.PPM;

        // Bound priceRatioX96 to be inside the optimal rate
        priceRatioX96 = uint160(bound(priceRatioX96, minPriceRatio, REFERENCE_SQRT_PRICE_X96));

        uint40 totalStableFee = FeeCalculation.calculateInsideOptimalRateFee(
            priceRatioX96, optimalFeeRate, ammPriceToTheLeft, userSellsZeroForOne
        ); // should not revert

        assertTrue(totalStableFee <= ONE);
    }

    function test_calculateFarFee_succeeds_left_of_reference() public pure {
        uint160 priceRatioX96 =
            uint160(uint256(REFERENCE_SQRT_PRICE_X96) * (1000000 - (OPTIMAL_FEE_RATE + 1))) / 1000000; // lower than the lower boundary
        uint40 farFee = FeeCalculation.calculateFarFee(priceRatioX96, OPTIMAL_FEE_RATE);
        assertTrue(farFee > OPTIMAL_FEE_RATE * 2);
    }

    function test_fuzz_calculateFarFee_succeeds(uint160 priceRatioX96, uint24 optimalFeeRate) public pure {
        priceRatioX96 = uint160(bound(priceRatioX96, 0, REFERENCE_SQRT_PRICE_X96));
        optimalFeeRate = uint24(bound(optimalFeeRate, 0, 1e6 - 1));
        uint40 farFee = FeeCalculation.calculateFarFee(priceRatioX96, optimalFeeRate);
        assertTrue(farFee > OPTIMAL_FEE_RATE * 2);
    }

    function test_fastPow_succeeds() public pure {
        uint256 k = 16_609_443; // 0.99

        uint256 z;
        uint256 blocksPassed;

        blocksPassed = 0;
        z = FeeCalculation.fastPow(k, blocksPassed);
        assertEq(z, 1 << 24);

        blocksPassed = 1;
        z = FeeCalculation.fastPow(k, blocksPassed);
        assertEq(z, k);

        blocksPassed = 2;
        z = FeeCalculation.fastPow(k, blocksPassed);
        assertEq(z, k * k >> 24);

        blocksPassed = 3;
        z = FeeCalculation.fastPow(k, blocksPassed);
        assertEq(z, k * k * k >> 48);

        blocksPassed = 4;
        z = FeeCalculation.fastPow(k, blocksPassed);
        assertEq(z, k * k * k * k >> 72);
    }
}
