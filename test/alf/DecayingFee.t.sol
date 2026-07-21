// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {Constants} from "@uniswap/v4-core/test/utils/Constants.sol";
import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";
import {
    DecayingFee,
    FeeConfig,
    FeeState,
    FeeConfigUpdated,
    InvalidKAndLogK,
    InvalidOptimalFeeE6,
    InvalidTargetMultiplier,
    InvalidReferenceSqrtPriceX96,
    MAX_OPTIMAL_FEE_E6,
    MAX_TARGET_MULTIPLIER,
    validateConfig,
    toPips
} from "../../src/alf/types/DecayingFee.sol";
import {FeeCalculation} from "../../src/alf/libraries/FeeCalculation.sol";

/// @notice Shared fixtures for the DecayingFee type tests. The type is a storage variable declared
///         directly in the test contract: no mocks, no harness contract, no pool.
abstract contract DecayingFeeTestBase is Test {
    uint24 constant K = 16_609_443; // 0.99 in Q24
    uint24 constant LOG_K = 9140; // -ln(0.99) >> 40
    uint24 constant OPTIMAL_FEE_E6 = 90; // 0.9 bps
    uint160 constant REFERENCE_SQRT_PRICE_X96 = uint160(Constants.SQRT_PRICE_1_1);

    DecayingFee internal fee;
    PoolId internal poolId = PoolId.wrap(bytes32(uint256(1)));

    function defaultConfig() internal pure returns (FeeConfig memory) {
        return FeeConfig({
            k: K,
            logK: LOG_K,
            optimalFeeE6: OPTIMAL_FEE_E6,
            targetMultiplier: 50,
            referenceSqrtPriceX96: REFERENCE_SQRT_PRICE_X96
        });
    }

    /// @dev Compute the sqrt price whose PRICE is `priceE6 / 1e6` of the reference price.
    function sqrtPriceAtE6(uint256 priceE6) internal pure returns (uint160) {
        uint256 ammPriceX192 =
            (uint256(REFERENCE_SQRT_PRICE_X96) * uint256(REFERENCE_SQRT_PRICE_X96) * priceE6) / 1_000_000;
        return uint160(FixedPointMathLib.sqrt(ammPriceX192));
    }
}

/// @notice Config validation and lifecycle: the `validateConfig` matrix ported from
///         `FeeConfigurationImplementation.t.sol` (minus the dropped configManager role) plus
///         setConfig's atomic state reset.
contract DecayingFeeConfigTest is DecayingFeeTestBase {
    function test_validateConfig_succeeds() public pure {
        validateConfig(
            FeeConfig({
                k: K,
                logK: LOG_K,
                optimalFeeE6: OPTIMAL_FEE_E6,
                targetMultiplier: 50,
                referenceSqrtPriceX96: REFERENCE_SQRT_PRICE_X96
            })
        );
    }

    function test_setConfig_revertsWithInvalidReferenceSqrtPriceX96_belowMin() public {
        FeeConfig memory config = defaultConfig();
        config.referenceSqrtPriceX96 = uint160(TickMath.MIN_SQRT_PRICE - 1);

        vm.expectRevert(abi.encodeWithSelector(InvalidReferenceSqrtPriceX96.selector, TickMath.MIN_SQRT_PRICE - 1));
        this.externalSetConfig(config);
    }

    function test_setConfig_revertsWithInvalidReferenceSqrtPriceX96_atMin() public {
        // MIN_SQRT_PRICE is invalid because the optimal range would extend below it:
        // minBoundedRef = MIN_SQRT_PRICE * 1e6 / sqrt((1e6 - MAX_OPTIMAL_FEE_E6) * 1e6) > MIN_SQRT_PRICE
        FeeConfig memory config = defaultConfig();
        config.referenceSqrtPriceX96 = uint160(TickMath.MIN_SQRT_PRICE);

        vm.expectRevert(abi.encodeWithSelector(InvalidReferenceSqrtPriceX96.selector, TickMath.MIN_SQRT_PRICE));
        this.externalSetConfig(config);
    }

    function test_setConfig_revertsWithInvalidReferenceSqrtPriceX96_atMax() public {
        // MAX_SQRT_PRICE - 1 is invalid because the optimal range would extend above MAX_SQRT_PRICE
        FeeConfig memory config = defaultConfig();
        config.referenceSqrtPriceX96 = uint160(TickMath.MAX_SQRT_PRICE - 1);

        vm.expectRevert(abi.encodeWithSelector(InvalidReferenceSqrtPriceX96.selector, TickMath.MAX_SQRT_PRICE - 1));
        this.externalSetConfig(config);
    }

    function test_setConfig_succeedsWithBoundedReferencePrices() public {
        // The optimal range is price-based, so the sqrt price bounds use sqrt(1 - maxOptimalFee)
        uint256 oneMinusMaxFee = FeeCalculation.ONE_E6 - MAX_OPTIMAL_FEE_E6;
        uint256 sqrtOneMinusMaxFeeE6 = FixedPointMathLib.sqrt(oneMinusMaxFee * FeeCalculation.ONE_E6);
        uint256 minBoundedRef = (uint256(TickMath.MIN_SQRT_PRICE) * FeeCalculation.ONE_E6 + sqrtOneMinusMaxFeeE6 - 1)
            / sqrtOneMinusMaxFeeE6;
        uint256 maxBoundedRef = uint256(TickMath.MAX_SQRT_PRICE) * sqrtOneMinusMaxFeeE6 / FeeCalculation.ONE_E6;

        // Minimum bounded reference price (inclusive: MIN_SQRT_PRICE is valid in v4)
        FeeConfig memory config = defaultConfig();
        config.referenceSqrtPriceX96 = uint160(minBoundedRef);
        fee.setConfig(poolId, config, block.number);

        // Maximum bounded reference price - 1 (exclusive: MAX_SQRT_PRICE is invalid in v4)
        config.referenceSqrtPriceX96 = uint160(maxBoundedRef - 1);
        fee.setConfig(poolId, config, block.number);

        // The optimal range at both boundaries stays within v4 limits
        uint256 lowerOptimalAtMin = minBoundedRef * sqrtOneMinusMaxFeeE6 / FeeCalculation.ONE_E6;
        assertGe(lowerOptimalAtMin, TickMath.MIN_SQRT_PRICE);
        uint256 upperOptimalAtMax = (maxBoundedRef - 1) * FeeCalculation.ONE_E6 / sqrtOneMinusMaxFeeE6;
        assertLt(upperOptimalAtMax, TickMath.MAX_SQRT_PRICE);
    }

    function test_setConfig_revertsWithInvalidReferenceSqrtPriceX96_atMaxBounded() public {
        // maxBoundedRef is exactly at the exclusive boundary, so it should fail
        uint256 oneMinusMaxFee = FeeCalculation.ONE_E6 - MAX_OPTIMAL_FEE_E6;
        uint256 sqrtOneMinusMaxFeeE6 = FixedPointMathLib.sqrt(oneMinusMaxFee * FeeCalculation.ONE_E6);
        uint256 maxBoundedRef = uint256(TickMath.MAX_SQRT_PRICE) * sqrtOneMinusMaxFeeE6 / FeeCalculation.ONE_E6;

        FeeConfig memory config = defaultConfig();
        config.referenceSqrtPriceX96 = uint160(maxBoundedRef);

        vm.expectRevert(abi.encodeWithSelector(InvalidReferenceSqrtPriceX96.selector, maxBoundedRef));
        this.externalSetConfig(config);
    }

    function test_setConfig_revertsWithInvalidTargetMultiplier_above100() public {
        FeeConfig memory config = defaultConfig();
        config.targetMultiplier = 101;

        vm.expectRevert(abi.encodeWithSelector(InvalidTargetMultiplier.selector, 101));
        this.externalSetConfig(config);
    }

    function test_setConfig_revertsWithInvalidOptimalFeeE6() public {
        FeeConfig memory config = defaultConfig();
        config.optimalFeeE6 = uint24(MAX_OPTIMAL_FEE_E6 + 1);

        vm.expectRevert(abi.encodeWithSelector(InvalidOptimalFeeE6.selector, MAX_OPTIMAL_FEE_E6 + 1));
        this.externalSetConfig(config);
    }

    function test_setConfig_revertsWithInvalidKAndLogK_bothZero() public {
        FeeConfig memory config = defaultConfig();
        config.k = 0;
        config.logK = 0;

        vm.expectRevert(abi.encodeWithSelector(InvalidKAndLogK.selector, 0, 0));
        this.externalSetConfig(config);
    }

    function test_setConfig_revertsWithInvalidKAndLogK_mismatchedLogK() public {
        FeeConfig memory config = defaultConfig();
        config.logK = LOG_K + 1;

        vm.expectRevert(abi.encodeWithSelector(InvalidKAndLogK.selector, K, LOG_K + 1));
        this.externalSetConfig(config);
    }

    function test_setConfig_revertsWithInvalidKAndLogK_kMaxUint24() public {
        // uint24 max = 2^24 - 1, just below Q24 (1.0). This represents k ≈ 0.99999994, which
        // barely decays; logK from lnWad rounds to 0, so no valid logK exists for this k.
        FeeConfig memory config = defaultConfig();
        config.k = type(uint24).max;
        config.logK = 1;

        vm.expectRevert(abi.encodeWithSelector(InvalidKAndLogK.selector, type(uint24).max, 1));
        this.externalSetConfig(config);
    }

    /// @notice Any k in (0, Q24) paired with its lnWad-derived logK validates; the same k with
    ///         logK + 1 is rejected. Pins the fast/slow decay-path consistency requirement.
    function test_fuzz_validateConfig_kAndLogKConsistency(uint24 k) public {
        k = uint24(bound(k, 1, type(uint24).max));
        uint256 kWad = (uint256(k) * 1e18) >> 24;
        uint24 logK = uint24(uint256(-FixedPointMathLib.lnWad(int256(kWad))) >> 40);
        vm.assume(logK > 0);

        FeeConfig memory config = defaultConfig();
        config.k = k;
        config.logK = logK;
        validateConfig(config);

        config.logK = logK + 1;
        vm.expectRevert(abi.encodeWithSelector(InvalidKAndLogK.selector, k, logK + 1));
        this.externalValidate(config);
    }

    /// @dev `vm.expectRevert` needs a call boundary; `validateConfig` is a free function, so wrap it.
    function externalValidate(FeeConfig memory config) external pure {
        validateConfig(config);
    }

    /// @dev Same call-boundary requirement for the revert tests of the (inlined) `setConfig`.
    function externalSetConfig(FeeConfig memory config) external {
        fee.setConfig(poolId, config, block.number);
    }

    function test_setConfig_succeeds_emitsAndResetsState() public {
        FeeConfig memory stored = fee.getConfig(poolId);
        assertEq(stored.k, 0);
        assertEq(stored.referenceSqrtPriceX96, 0);

        FeeConfig memory config = defaultConfig();
        vm.expectEmit(true, false, false, true);
        emit FeeConfigUpdated(poolId, config);
        fee.setConfig(poolId, config, block.number);

        stored = fee.getConfig(poolId);
        assertEq(stored.k, K);
        assertEq(stored.logK, LOG_K);
        assertEq(stored.optimalFeeE6, OPTIMAL_FEE_E6);
        assertEq(stored.targetMultiplier, 50);
        assertEq(stored.referenceSqrtPriceX96, REFERENCE_SQRT_PRICE_X96);

        FeeState memory state = fee.getState(poolId);
        assertEq(state.decayingFeeE12, FeeCalculation.UNDEFINED_DECAYING_FEE_E12);
        assertEq(state.sqrtAmmPriceX96, 0);
        assertEq(state.blockNumber, block.number);
    }

    /// @notice A config write resets accumulated swap history atomically (invariant 4).
    function test_setConfig_resetsStateWithExistingSwapHistory() public {
        fee.setConfig(poolId, defaultConfig(), 1);

        // Build real history: an outside-range commit checkpoints a decaying fee and a price.
        fee.commitFee(poolId, sqrtPriceAtE6(1_000_130), true, 10);
        FeeState memory state = fee.getState(poolId);
        assertTrue(state.sqrtAmmPriceX96 != 0);
        assertTrue(state.decayingFeeE12 != FeeCalculation.UNDEFINED_DECAYING_FEE_E12);

        // Re-set the config: state must be fully reset
        fee.setConfig(poolId, defaultConfig(), 110);
        state = fee.getState(poolId);
        assertEq(state.decayingFeeE12, FeeCalculation.UNDEFINED_DECAYING_FEE_E12);
        assertEq(state.sqrtAmmPriceX96, 0);
        assertEq(state.blockNumber, 110);
    }

    /// @notice The UNDEFINED sentinel and every real fee (<= 1e12) fit uint40 (invariant 5).
    function test_feeStatePacking_sentinelFitsUint40() public pure {
        assertEq(uint256(uint40(FeeCalculation.UNDEFINED_DECAYING_FEE_E12)), FeeCalculation.UNDEFINED_DECAYING_FEE_E12);
        assertEq(uint256(uint40(FeeCalculation.ONE_E12)), FeeCalculation.ONE_E12);
    }
}

/// @notice The fee state machine, tested directly on the type with explicit prices and block
///         numbers: the transition matrix ported from `StableStableHook.beforeSwap.t.sol`
///         (including its exact numeric pins) plus the preview/commit invariants that the
///         extraction adds.
contract DecayingFeeStateMachineTest is DecayingFeeTestBase {
    uint160 internal sqrtAmmPriceX96 = REFERENCE_SQRT_PRICE_X96;
    uint256 internal blockNumber = 1;

    function setUp() public {
        fee.setConfig(poolId, defaultConfig(), blockNumber);
    }

    /// @dev The `beforeSwap` path: commit at the current fixture price/block, in pips.
    function commit(bool zeroForOne) internal returns (uint24) {
        return toPips(fee.commitFee(poolId, sqrtAmmPriceX96, zeroForOne, blockNumber));
    }

    // ──── Inside optimal range ────

    function test_previewFee_insideOptimalRange_exactReferencePrice() public {
        sqrtAmmPriceX96 = REFERENCE_SQRT_PRICE_X96;

        assertEq(commit(true), OPTIMAL_FEE_E6);
        assertEq(commit(false), OPTIMAL_FEE_E6);
    }

    function test_previewFee_insideOptimalRange_lowerBoundary() public {
        // Slightly inside the lower boundary: RP * (1 - (optimalFee - 1))
        sqrtAmmPriceX96 = sqrtPriceAtE6(1_000_000 - (OPTIMAL_FEE_E6 - 1));

        // Sell token0 (pushing price down, away from boundary): minimal fee
        assertLt(commit(true), OPTIMAL_FEE_E6);
        // Buy token0 (pushing price up, toward reference): higher fee to reach the buy price
        assertGt(commit(false), OPTIMAL_FEE_E6);
    }

    function test_previewFee_insideOptimalRange_upperBoundary() public {
        // Upper boundary ≈ RP * 1.000090009
        sqrtAmmPriceX96 = sqrtPriceAtE6(1_000_090);

        assertLt(commit(false), OPTIMAL_FEE_E6);
        assertGt(commit(true), OPTIMAL_FEE_E6);
    }

    function test_fuzz_previewFee_insideOptimalRange_leftOfReference(uint24 priceBps) public {
        priceBps = uint24(bound(priceBps, 999_911, 1_000_000));
        sqrtAmmPriceX96 = sqrtPriceAtE6(priceBps);

        assertLe(commit(true), OPTIMAL_FEE_E6);
        assertGe(commit(false), OPTIMAL_FEE_E6);
    }

    function test_fuzz_previewFee_insideOptimalRange_rightOfReference(uint24 priceBps) public {
        priceBps = uint24(bound(priceBps, 1_000_000, 1_000_090));
        sqrtAmmPriceX96 = sqrtPriceAtE6(priceBps);

        assertLe(commit(false), OPTIMAL_FEE_E6);
        assertGe(commit(true), OPTIMAL_FEE_E6);
    }

    /// @notice Inside the optimal range, all swappers see consistent pre-impact prices:
    ///         sells at RP * (1 - optimalFee), buys at RP / (1 - optimalFee).
    function test_fuzz_previewFee_insideOptimalRange_consistentEffectivePrices(uint24 priceBps) public {
        priceBps = uint24(bound(priceBps, 999_911, 1_000_090));
        sqrtAmmPriceX96 = sqrtPriceAtE6(priceBps);
        uint256 ammPriceX192 =
            (uint256(REFERENCE_SQRT_PRICE_X96) * uint256(REFERENCE_SQRT_PRICE_X96) * priceBps) / 1_000_000;

        uint24 sellFee = commit(true);
        uint24 buyFee = commit(false);

        uint256 effectiveSellPrice = (ammPriceX192 * (1_000_000 - sellFee)) / 1_000_000;
        uint256 effectiveBuyPrice = (ammPriceX192 * 1_000_000) / (1_000_000 - buyFee);

        uint256 targetSellPrice =
            (uint256(REFERENCE_SQRT_PRICE_X96) * REFERENCE_SQRT_PRICE_X96 * (1_000_000 - OPTIMAL_FEE_E6)) / 1_000_000;
        uint256 targetBuyPrice =
            (uint256(REFERENCE_SQRT_PRICE_X96) * REFERENCE_SQRT_PRICE_X96 * 1_000_000) / (1_000_000 - OPTIMAL_FEE_E6);

        assertApproxEqRel(effectiveSellPrice, targetSellPrice, 0.000001e18);
        assertApproxEqRel(effectiveBuyPrice, targetBuyPrice, 0.000001e18);
    }

    // ──── Outside optimal range: decay, adjustment, directional zero fee ────

    /// @notice Price above reference, moving further out, then decaying. Exact pins ported from
    ///         the original hook test (`test_beforeSwap_unitSwapAmmPriceBiggerThanOptimalSpreadTarget`).
    function test_commitFee_outsideRange_aboveReference_adjustAndDecay() public {
        sqrtAmmPriceX96 = sqrtPriceAtE6(1_000_130);
        blockNumber += 750;

        // Buying token0 pushes the price further from reference: zero fee
        assertEq(commit(false), 0);

        // New block; price moved further right (1.00013 -> 1.00014)
        blockNumber += 1;
        sqrtAmmPriceX96 = sqrtPriceAtE6(1_000_140);

        // Fee adjusted upward to preserve the pre-impact price, negligible decay after 1 block
        assertEq(commit(true), 209); // 90 (optimal) + 119 (adjusted decaying fee)

        // After 750 blocks the adjusted fee decays toward the target
        blockNumber += 750;
        assertEq(commit(true), 204); // 90 (optimal) + 114 (decayed toward target)
    }

    /// @notice Mirror case below the reference. Exact pins ported from the original hook test.
    function test_commitFee_outsideRange_belowReference_adjustAndDecay() public {
        sqrtAmmPriceX96 = sqrtPriceAtE6(999_870);
        blockNumber += 750;

        // Selling token0 pushes the price further from reference: zero fee
        assertEq(commit(true), 0);

        blockNumber += 1;
        sqrtAmmPriceX96 = sqrtPriceAtE6(999_860);

        assertEq(commit(false), 209);

        blockNumber += 750;
        assertEq(commit(false), 204);
    }

    /// @notice With targetMultiplier = 0 the target fee equals farBoundaryFee, so after full decay
    ///         the fee equals farBoundaryFee, and a price shock re-anchors with no transient spike.
    function test_commitFee_zeroTargetMultiplier_feeEqualsFarBoundaryFee() public {
        FeeConfig memory config = defaultConfig();
        config.targetMultiplier = 0;
        fee.setConfig(poolId, config, blockNumber);

        sqrtAmmPriceX96 = sqrtPriceAtE6(1_000_130);
        blockNumber += 1;
        commit(true);

        // Slightly move the price so the equal-price edge case is avoided, wait for full decay
        sqrtAmmPriceX96 = sqrtPriceAtE6(1_000_131);
        blockNumber += 750;
        uint24 fee1 = commit(true);

        uint256 priceRatioX96 = FeeCalculation.calculatePriceRatioX96(sqrtAmmPriceX96, REFERENCE_SQRT_PRICE_X96);
        uint256 farBoundaryFeeE12 = FeeCalculation.calculateFarBoundaryFee(priceRatioX96, OPTIMAL_FEE_E6);
        assertEq(fee1, toPips(farBoundaryFeeE12));

        // Large price shock with 1 block elapsed: fee immediately equals the new farBoundaryFee
        blockNumber += 1;
        sqrtAmmPriceX96 = sqrtPriceAtE6(1_002_000);
        uint24 fee2 = commit(true);

        priceRatioX96 = FeeCalculation.calculatePriceRatioX96(sqrtAmmPriceX96, REFERENCE_SQRT_PRICE_X96);
        farBoundaryFeeE12 = FeeCalculation.calculateFarBoundaryFee(priceRatioX96, OPTIMAL_FEE_E6);
        assertEq(fee2, toPips(farBoundaryFeeE12));
        assertGt(fee2, fee1);
    }

    /// @notice With targetMultiplier = 100 and an aggressive k, the spread closes to
    ///         ~2 * optimalFee within a couple of blocks.
    function test_commitFee_spreadClosesQuickly_withFullTargetMultiplier() public {
        uint24 testK = 167_772; // floor(0.01 * 2^24): 99% decay per block
        uint256 kWad = (uint256(testK) * 1e18) >> 24;
        uint24 testLogK = uint24(uint256(-FixedPointMathLib.lnWad(int256(kWad))) >> 40);

        FeeConfig memory config = defaultConfig();
        config.k = testK;
        config.logK = testLogK;
        config.optimalFeeE6 = 10; // 0.1 bps
        config.targetMultiplier = 100;
        fee.setConfig(poolId, config, blockNumber);

        // 10bps above reference; first commit establishes the outside-range state
        sqrtAmmPriceX96 = sqrtPriceAtE6(1_000_100);
        blockNumber += 1;
        commit(true);

        // Slightly different price (avoid the equal-price edge case), 2 blocks of decay
        sqrtAmmPriceX96 = sqrtPriceAtE6(1_000_099);
        blockNumber += 2;

        uint24 sellFee = commit(true); // toward reference: decaying fee
        uint24 buyFee = commit(false); // away from reference: zero

        assertEq(buyFee, 0);
        // targetFee = farBoundaryFee - closeBoundaryFee ≈ 2 * optimalFee = 20 in E6
        assertLe(sellFee, 21);
        assertGe(sellFee, 19);
    }

    /// @notice Higher targetMultiplier gives a lower fee after full decay at the same price.
    function test_fuzz_commitFee_higherTargetMultiplier_lowerFeeAfterDecay(uint8 multiplierA, uint8 multiplierB)
        public
    {
        multiplierA = uint8(bound(multiplierA, 0, 100));
        multiplierB = uint8(bound(multiplierB, 0, 100));

        uint24[2] memory fees;
        uint8[2] memory multipliers = [multiplierA, multiplierB];

        for (uint256 i = 0; i < 2; i++) {
            FeeConfig memory config = defaultConfig();
            config.targetMultiplier = multipliers[i];
            fee.setConfig(poolId, config, blockNumber);

            sqrtAmmPriceX96 = sqrtPriceAtE6(1_000_130);
            blockNumber += 1;
            commit(true);

            sqrtAmmPriceX96 = sqrtPriceAtE6(1_000_131);
            blockNumber += 750;
            fees[i] = commit(true);
        }

        if (multiplierA > multiplierB) {
            assertLe(fees[0], fees[1]);
        } else if (multiplierA < multiplierB) {
            assertGe(fees[0], fees[1]);
        } else {
            assertEq(fees[0], fees[1]);
        }
    }

    // ──── Block-scoped checkpoint semantics ────

    /// @notice Same-block calls price off the cached start-of-block price: a moved slot0 price is
    ///         ignored, so the fee is identical.
    function test_commitFee_sameBlock_feeIsCached() public {
        sqrtAmmPriceX96 = sqrtPriceAtE6(999_950);
        blockNumber += 1;

        uint24 fee1 = commit(true);

        // Simulate the first swap's price impact: slot0 moved to reference
        sqrtAmmPriceX96 = REFERENCE_SQRT_PRICE_X96;
        uint24 fee2 = commit(true);

        assertEq(fee1, fee2);
    }

    /// @notice A new block reads the fresh slot0 price, not the previous block's cache.
    function test_commitFee_newBlock_usesFreshPrice() public {
        sqrtAmmPriceX96 = sqrtPriceAtE6(999_950);
        blockNumber += 1;
        uint24 fee1 = commit(true);

        sqrtAmmPriceX96 = REFERENCE_SQRT_PRICE_X96;
        blockNumber += 1;
        uint24 fee2 = commit(true);

        assertTrue(fee1 != fee2);
    }

    /// @notice The checkpoint is written only by the first commit of a block (invariant 2).
    function test_commitFee_sameBlock_stateNotUpdated() public {
        sqrtAmmPriceX96 = REFERENCE_SQRT_PRICE_X96;
        blockNumber += 1;

        commit(true);
        FeeState memory state1 = fee.getState(poolId);

        sqrtAmmPriceX96 = sqrtPriceAtE6(999_950);
        commit(true);
        FeeState memory state2 = fee.getState(poolId);

        assertEq(state1.decayingFeeE12, state2.decayingFeeE12);
        assertEq(state1.sqrtAmmPriceX96, state2.sqrtAmmPriceX96);
        assertEq(state1.blockNumber, state2.blockNumber);
    }

    /// @notice After a config reset, the next commit reads the fresh slot0 price instead of the
    ///         pre-reset cache, even in the same block.
    function test_commitFee_configReset_usesFreshPrice() public {
        sqrtAmmPriceX96 = REFERENCE_SQRT_PRICE_X96;
        assertEq(commit(true), OPTIMAL_FEE_E6);

        // Reset the config in the same block, then move the price
        fee.setConfig(poolId, defaultConfig(), blockNumber);
        sqrtAmmPriceX96 = sqrtPriceAtE6(999_950);

        // Below reference and selling token0 pushes further from reference: fee < optimalFee.
        // A stale cached reference price would produce exactly optimalFee.
        assertLt(commit(true), OPTIMAL_FEE_E6);
    }

    /// @notice Same-block calls take the same inside/outside branch as the block's first swap
    ///         (invariant 3): an inside-range checkpoint followed by a same-block call with slot0
    ///         far outside the range still prices inside the range off the cache, and the
    ///         UNDEFINED sentinel is never consumed as a decay start.
    function test_commitFee_sameBlock_branchStability() public {
        sqrtAmmPriceX96 = REFERENCE_SQRT_PRICE_X96;
        blockNumber += 1;
        assertEq(commit(true), OPTIMAL_FEE_E6);

        // slot0 jumps far outside the optimal range within the block; the cache wins
        sqrtAmmPriceX96 = sqrtPriceAtE6(1_005_000);
        assertEq(commit(true), OPTIMAL_FEE_E6);
        assertEq(commit(false), OPTIMAL_FEE_E6);
    }

    // ──── Preview/commit equivalence (invariant 1) ────

    /// @notice previewFee is commitFee without the write: same fee, and a preview after the
    ///         commit (same block) returns the same fee with `dirty == false`.
    function test_fuzz_previewCommitEquivalence(uint160 price1, uint160 price2, uint16 gap, bool zeroForOne) public {
        price1 = uint160(bound(price1, TickMath.MIN_SQRT_PRICE, TickMath.MAX_SQRT_PRICE - 1));
        price2 = uint160(bound(price2, TickMath.MIN_SQRT_PRICE, TickMath.MAX_SQRT_PRICE - 1));

        // Build history so the second step exercises non-trivial state
        blockNumber += 1;
        fee.commitFee(poolId, price1, zeroForOne, blockNumber);

        blockNumber += gap;
        (uint256 previewed, FeeState memory next, bool dirty) = fee.previewFee(poolId, price2, zeroForOne, blockNumber);
        uint256 committed = fee.commitFee(poolId, price2, zeroForOne, blockNumber);
        assertEq(previewed, committed, "preview != commit");

        // dirty iff first call of the block (gap == 0 means same block as the history commit)
        assertEq(dirty, gap != 0, "dirty flag");
        if (dirty) {
            FeeState memory stored = fee.getState(poolId);
            assertEq(stored.decayingFeeE12, next.decayingFeeE12);
            assertEq(stored.sqrtAmmPriceX96, next.sqrtAmmPriceX96);
            assertEq(stored.blockNumber, next.blockNumber);
        }

        // Post-commit preview in the same block: identical fee, nothing further to write
        (uint256 previewedAfter,, bool dirtyAfter) = fee.previewFee(poolId, price2, zeroForOne, blockNumber);
        assertEq(previewedAfter, committed, "post-commit preview != commit");
        assertFalse(dirtyAfter, "post-commit preview still dirty");
    }

    // ──── Never-revert sweep across the full state space ────

    /// @notice commitFee never reverts across 5 sequential swaps with arbitrary prices (full v4
    ///         range), fuzzed reference prices, directions, and block gaps, and the fee is always
    ///         <= 100%. Port of the original hook's `test_fuzz_beforeSwap_neverReverts`.
    function test_fuzz_commitFee_neverReverts(
        uint160 fuzzedRefSqrtPrice,
        uint160[5] memory sqrtPrices,
        uint256 directions,
        uint256 blockGaps,
        uint8 fuzzedTargetMultiplier
    ) public {
        // Reference price bounds ensuring the optimal range stays within v4 limits
        uint256 sqrtOneMinusMaxFeeE6 =
            FixedPointMathLib.sqrt((FeeCalculation.ONE_E6 - MAX_OPTIMAL_FEE_E6) * FeeCalculation.ONE_E6);
        uint256 minRef = (uint256(TickMath.MIN_SQRT_PRICE) * FeeCalculation.ONE_E6 + sqrtOneMinusMaxFeeE6 - 1)
            / sqrtOneMinusMaxFeeE6;
        uint256 maxRef = uint256(TickMath.MAX_SQRT_PRICE) * sqrtOneMinusMaxFeeE6 / FeeCalculation.ONE_E6;

        FeeConfig memory config = defaultConfig();
        config.referenceSqrtPriceX96 = uint160(bound(fuzzedRefSqrtPrice, minRef, maxRef - 1));
        config.targetMultiplier = uint8(bound(fuzzedTargetMultiplier, 0, 100));
        fee.setConfig(poolId, config, blockNumber);

        for (uint256 i = 0; i < 5; i++) {
            sqrtAmmPriceX96 = uint160(bound(sqrtPrices[i], TickMath.MIN_SQRT_PRICE, TickMath.MAX_SQRT_PRICE - 1));
            if (i > 0) blockNumber += bound((blockGaps >> (i * 16)) & 0xFFFF, 0, 10_000);

            uint24 pips = commit((directions >> i) & 1 == 1);
            assertLe(pips, 1_000_000, "fee must be <= 100%");
        }
    }
}

