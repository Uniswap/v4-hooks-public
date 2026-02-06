// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {FeeCalculation} from "../../../src/stable/libraries/FeeCalculation.sol";
import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {FixedPoint96} from "@uniswap/v4-core/src/libraries/FixedPoint96.sol";

contract FeeCalculationTest is Test {
    uint24 constant OPTIMAL_FEE_E6 = 90; // 0.009%
    uint256 constant MAX_OPTIMAL_FEE_E6 = 1e4;
    uint160 constant REFERENCE_SQRT_PRICE_X96 = uint160(FixedPoint96.Q96); // 1:1 price
    uint256 constant Q48 = 2 ** 48;

    // =============================================================================
    // INVARIANT: priceRatioX96 <= Q96 (always normalized to <= 1)
    // =============================================================================

    function test_calculatePriceRatioX96_left_succeeds() public pure {
        uint160 sqrtAmmPriceX96 = (REFERENCE_SQRT_PRICE_X96 * 99) / 100; // 0.99 price
        uint256 priceRatioX96 = FeeCalculation.calculatePriceRatioX96(sqrtAmmPriceX96, REFERENCE_SQRT_PRICE_X96);

        // Ratio should be (0.99)^2 in Q96 format
        uint256 expected = ((sqrtAmmPriceX96 * Q48) / REFERENCE_SQRT_PRICE_X96) ** 2;
        assertEq(priceRatioX96, expected);

        // Ratio should be less than or equal to 2^96 (1)
        assertLe(priceRatioX96, FixedPoint96.Q96);
    }

    function test_calculatePriceRatioX96_right_succeeds() public pure {
        uint160 sqrtAmmPriceX96 = (REFERENCE_SQRT_PRICE_X96 * 101) / 100; // 1.01 price
        uint256 priceRatioX96 = FeeCalculation.calculatePriceRatioX96(sqrtAmmPriceX96, REFERENCE_SQRT_PRICE_X96);

        // Ratio should be (1/1.01)^2 in Q96 format
        uint256 expected = ((REFERENCE_SQRT_PRICE_X96 * Q48) / sqrtAmmPriceX96) ** 2;
        assertEq(priceRatioX96, expected);

        // Ratio should be less than or equal to 2^96 (1)
        assertLe(priceRatioX96, FixedPoint96.Q96);
    }

    function test_fuzz_calculatePriceRatioX96(uint160 sqrtAmmPriceX96, uint160 sqrtReferencePriceX96) public pure {
        sqrtAmmPriceX96 = uint160(bound(sqrtAmmPriceX96, TickMath.MIN_SQRT_PRICE, TickMath.MAX_SQRT_PRICE));
        sqrtReferencePriceX96 = uint160(bound(sqrtReferencePriceX96, TickMath.MIN_SQRT_PRICE, TickMath.MAX_SQRT_PRICE));

        uint256 priceRatioX96 = FeeCalculation.calculatePriceRatioX96(sqrtAmmPriceX96, sqrtReferencePriceX96);

        assertLe(priceRatioX96, FixedPoint96.Q96);
    }

    // =============================================================================
    // INVARIANT: closeFee never reverts for valid inputs
    // closeFee <= 0 means inside optimal range, > 0 means outside
    // =============================================================================

    function test_calculateCloseBoundaryFee_succeeds_inside_optimal_range() public pure {
        uint160 priceRatioX96 = uint160(FixedPoint96.Q96); // Exactly at reference
        int256 closeBoundaryFeeE12 = FeeCalculation.calculateCloseBoundaryFee(priceRatioX96, OPTIMAL_FEE_E6);
        assertLt(closeBoundaryFeeE12, 0); // should be negative since the price is inside the optimal range

        // just inside the boundary of the optimal range (89)
        priceRatioX96 = uint160(
            (uint256(REFERENCE_SQRT_PRICE_X96) * (FeeCalculation.ONE_E6 - (OPTIMAL_FEE_E6 - 1))) / FeeCalculation.ONE_E6
        );
        closeBoundaryFeeE12 = FeeCalculation.calculateCloseBoundaryFee(priceRatioX96, OPTIMAL_FEE_E6);
        assertLt(closeBoundaryFeeE12, 0);
    }

    function test_calculateCloseBoundaryFee_succeeds_outside_optimal_range() public pure {
        // at the boundary of the optimal range
        /// 1000000 - OPTIMAL_FEE_E6 = 999910
        uint160 priceRatioX96 = uint160(
            (uint256(REFERENCE_SQRT_PRICE_X96) * (FeeCalculation.ONE_E6 - OPTIMAL_FEE_E6)) / FeeCalculation.ONE_E6
        ); // the lower boundary of the optimal range
        int256 closeBoundaryFeeE12 = FeeCalculation.calculateCloseBoundaryFee(priceRatioX96, OPTIMAL_FEE_E6);
        assertGt(closeBoundaryFeeE12, 0);
    }

    function test_fuzz_calculateCloseBoundaryFee_succeeds(uint256 priceRatioX96, uint24 optimalFeeE6) public pure {
        priceRatioX96 = bound(priceRatioX96, 0, REFERENCE_SQRT_PRICE_X96);
        optimalFeeE6 = uint24(bound(optimalFeeE6, 0, FeeCalculation.ONE_E6 - 1));
        FeeCalculation.calculateCloseBoundaryFee(priceRatioX96, optimalFeeE6); // should not revert
    }

    // =============================================================================
    // INVARIANT: insideOptimalRangeFee <= ONE_E12 (fee never exceeds 100%)
    // =============================================================================

    function test_fuzz_calculateInsideOptimalRangeFee_succeeds(
        uint256 priceRatioX96,
        uint24 optimalFeeE6,
        bool ammPriceBelowRP,
        bool userSellsZeroForOne
    ) public pure {
        optimalFeeE6 = uint24(bound(optimalFeeE6, 0, FeeCalculation.ONE_E6 - 1));

        // Calculate the minimum priceRatioX96 that's inside the optimal range
        uint256 minPriceRatio =
            (uint256(FixedPoint96.Q96) * (FeeCalculation.ONE_E6 - optimalFeeE6)) / FeeCalculation.ONE_E6;

        // Bound priceRatioX96 to be inside the optimal range
        priceRatioX96 = bound(priceRatioX96, minPriceRatio, REFERENCE_SQRT_PRICE_X96);

        uint256 swapperFeeE12 = FeeCalculation.calculateInsideOptimalRangeFee(
            priceRatioX96, optimalFeeE6, ammPriceBelowRP, userSellsZeroForOne
        ); // should not revert

        assertLe(swapperFeeE12, FeeCalculation.ONE_E12);
    }

    // =============================================================================
    // INVARIANT: farFee >= 2 * optimalFee, farFee <= ONE_E12
    // INVARIANT: farFee >= closeFee when outside optimal range
    // INVARIANT: targetFee > 0 and targetFee <= farFee when outside optimal range
    // =============================================================================

    function test_calculateFarBoundaryFee_succeeds_left_of_reference() public pure {
        uint160 priceRatioX96 = uint160(
            (uint256(REFERENCE_SQRT_PRICE_X96) * (FeeCalculation.ONE_E6 - (OPTIMAL_FEE_E6 + 1))) / FeeCalculation.ONE_E6
        ); // lower than the lower boundary
        uint256 farBoundaryFeeE12 = FeeCalculation.calculateFarBoundaryFee(priceRatioX96, OPTIMAL_FEE_E6);
        assertGt(farBoundaryFeeE12, OPTIMAL_FEE_E6 * 2); // greater than 2 times the optimal fee
    }

    function test_fuzz_calculateFarBoundaryFee_succeeds(uint256 priceRatioX96, uint24 optimalFeeE6) public pure {
        priceRatioX96 = bound(priceRatioX96, 0, FixedPoint96.Q96);
        optimalFeeE6 = uint24(bound(optimalFeeE6, 0, MAX_OPTIMAL_FEE_E6));
        uint256 farBoundaryFeeE12 = FeeCalculation.calculateFarBoundaryFee(priceRatioX96, optimalFeeE6);
        assertGe(farBoundaryFeeE12, optimalFeeE6 * 2); // >= 2 times the optimal fee
        assertLe(farBoundaryFeeE12, FeeCalculation.ONE_E12); // <= 100%
        int256 closeBoundaryFeeE12 = FeeCalculation.calculateCloseBoundaryFee(priceRatioX96, optimalFeeE6);
        if (closeBoundaryFeeE12 > 0) {
            assertGe(farBoundaryFeeE12, uint256(closeBoundaryFeeE12));
            uint256 targetFeeE12 = farBoundaryFeeE12 - uint256(closeBoundaryFeeE12) / 2;
            assertLe(targetFeeE12, farBoundaryFeeE12);
            assertGt(targetFeeE12, 0);
        }
    }

    // =============================================================================
    // INVARIANT: fastPow returns correct k^n for n <= 4
    // =============================================================================

    function test_fastPow_succeeds() public pure {
        uint256 k = 16_609_443; // 0.99

        uint256 z;
        uint40 blocksPassed;

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

    // =============================================================================
    // INVARIANT: adjustedFee >= previousFee and adjustedFee <= ONE_E12
    // (price movement further from reference can only increase the fee)
    // =============================================================================

    function test_fuzz_adjustPreviousFeeForPriceMovement_succeeds(uint256 priceRatioX96, uint256 previousDecayingFeeE12)
        public
        pure
    {
        priceRatioX96 = bound(priceRatioX96, 0, FixedPoint96.Q96); // price impact
        previousDecayingFeeE12 = bound(previousDecayingFeeE12, 0, FeeCalculation.ONE_E12);
        uint256 adjustedFeeE12 = FeeCalculation.adjustPreviousFeeForPriceMovement(priceRatioX96, previousDecayingFeeE12);
        assertGe(adjustedFeeE12, previousDecayingFeeE12);
        assertLe(adjustedFeeE12, FeeCalculation.ONE_E12);
    }

    // =============================================================================
    // INVARIANT: decayingFee >= targetFee and decayingFee <= ONE_E12
    // (decay keeps fee between target and previous, never exceeds 100%)
    // =============================================================================

    function test_fuzz_calculateDecayingFee_succeeds(
        uint256 targetFeeE12,
        uint256 previousDecayingFeeE12,
        uint24 k,
        uint40 blocksPassed
    ) public pure {
        targetFeeE12 = bound(targetFeeE12, 0, FeeCalculation.ONE_E12 - 1);
        previousDecayingFeeE12 = bound(previousDecayingFeeE12, targetFeeE12, FeeCalculation.ONE_E12);
        k = uint24(bound(k, 1, 2 ** 24 - 1));
        uint256 kWad = (uint256(k) * 1e18) >> 24;
        uint24 logK = uint24(uint256(-FixedPointMathLib.lnWad(int256(kWad))) >> 40);
        vm.assume(logK > 0);
        uint256 decayingFeeE12 =
            FeeCalculation.calculateDecayingFee(targetFeeE12, previousDecayingFeeE12, k, logK, blocksPassed);
        assertGe(decayingFeeE12, targetFeeE12);
        assertLe(decayingFeeE12, FeeCalculation.ONE_E12);
    }

    // =============================================================================
    // INVARIANT: decayingFee == targetFee when previousFee == targetFee
    // (no gap to decay means fee stays exactly at target regardless of k or blocks)
    // =============================================================================

    function test_fuzz_calculateDecayingFee_eqTarget_whenPreviousEqTarget(
        uint256 targetFeeE12,
        uint24 k,
        uint40 blocksPassed
    ) public pure {
        targetFeeE12 = bound(targetFeeE12, 0, FeeCalculation.ONE_E12 - 1);
        k = uint24(bound(k, 1, 2 ** 24 - 1));
        uint256 kWad = (uint256(k) * 1e18) >> 24;
        uint24 logK = uint24(uint256(-FixedPointMathLib.lnWad(int256(kWad))) >> 40);
        vm.assume(logK > 0);

        uint256 decayingFeeE12 = FeeCalculation.calculateDecayingFee(targetFeeE12, targetFeeE12, k, logK, blocksPassed);
        assertEq(decayingFeeE12, targetFeeE12);
    }

    // =============================================================================
    // INVARIANT: with extreme blocksPassed, decayingFee converges to targetFee
    // (decay factor approaches 0, so fee = target + 0 * (previous - target) = target)
    // =============================================================================

    function test_calculateDecayingFee_convergesWithLargeBlocksPassed() public pure {
        uint256 targetFeeE12 = 100_000_000; // some target
        uint256 previousDecayingFeeE12 = 500_000_000; // much higher than target
        uint24 k = 16_609_443; // 0.99 in Q24
        uint24 logK = 9140;

        // With a very large number of blocks, fee should converge to target
        uint256 decayingFeeE12 =
            FeeCalculation.calculateDecayingFee(targetFeeE12, previousDecayingFeeE12, k, logK, 1_000_000);
        assertEq(decayingFeeE12, targetFeeE12);

        // Even with uint40 max blocks
        decayingFeeE12 =
            FeeCalculation.calculateDecayingFee(targetFeeE12, previousDecayingFeeE12, k, logK, type(uint40).max);
        assertEq(decayingFeeE12, targetFeeE12);
    }

    // =============================================================================
    // INVARIANT: adjustedFee >= newTargetFee after price moves further from reference
    // When price moves further from reference while outside optimal range:
    //   - The old fee (which may have decayed to old target) gets adjusted upward
    //     to preserve the same effective price at the new AMM price
    //   - The new target is higher because price is further from reference
    //   - The adjusted fee must still be >= the new target for decay math to work
    // =============================================================================

    function test_fuzz_adjustedFee_geq_newTarget(
        uint256 oldPriceRatioX96,
        uint256 newPriceRatioX96,
        uint24 optimalFeeE6
    ) public pure {
        optimalFeeE6 = uint24(bound(optimalFeeE6, 1, MAX_OPTIMAL_FEE_E6));

        // Old price must be outside optimal range: priceRatio < (1 - optimalFee)
        uint256 outsideBoundary = (FixedPoint96.Q96 * (FeeCalculation.ONE_E6 - optimalFeeE6)) / FeeCalculation.ONE_E6;
        oldPriceRatioX96 = bound(oldPriceRatioX96, FixedPoint96.Q96 / 2, outsideBoundary);

        // New price moved further from reference (smaller priceRatio)
        newPriceRatioX96 = bound(newPriceRatioX96, FixedPoint96.Q96 / 2, oldPriceRatioX96);

        // Compute old fees at old price
        int256 oldCloseFeeE12 = FeeCalculation.calculateCloseBoundaryFee(oldPriceRatioX96, optimalFeeE6);
        uint256 oldFarFeeE12 = FeeCalculation.calculateFarBoundaryFee(oldPriceRatioX96, optimalFeeE6);
        uint256 oldTargetFeeE12 = oldFarFeeE12 - uint256(oldCloseFeeE12) / 2;

        // Previous fee has fully decayed to old target
        uint256 previousDecayingFeeE12 = oldTargetFeeE12;

        // Price impact ratio between old and new position
        // priceImpactRatio = newPriceRatio / oldPriceRatio (how much price moved)
        // Since both are relative to reference, the impact ratio is newRatio/oldRatio
        // But adjustPreviousFeeForPriceMovement takes calculatePriceRatioX96(newAmm, oldAmm)
        // which equals newPriceRatioX96 * Q96 / oldPriceRatioX96 (scaled)
        // We can compute it directly: smaller/larger
        uint256 priceImpactX96 = (newPriceRatioX96 * FixedPoint96.Q96) / oldPriceRatioX96;

        uint256 adjustedFeeE12 =
            FeeCalculation.adjustPreviousFeeForPriceMovement(priceImpactX96, previousDecayingFeeE12);

        // Compute new target at new price
        int256 newCloseFeeE12 = FeeCalculation.calculateCloseBoundaryFee(newPriceRatioX96, optimalFeeE6);
        uint256 newFarFeeE12 = FeeCalculation.calculateFarBoundaryFee(newPriceRatioX96, optimalFeeE6);
        uint256 newTargetFeeE12 = newFarFeeE12 - uint256(newCloseFeeE12) / 2;

        assertGe(adjustedFeeE12, newTargetFeeE12);
    }
}
