// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {console2} from "forge-std/console2.sol";
import {StableStableHook} from "../../src/stable/StableStableHook.sol";
import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {CustomRevert} from "@uniswap/v4-core/src/libraries/CustomRevert.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Constants} from "@uniswap/v4-core/test/utils/Constants.sol";
import {IStableStableHook} from "../../src/stable/interfaces/IStableStableHook.sol";
import {FeeConfig, IFeeConfiguration} from "../../src/stable/interfaces/IFeeConfiguration.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";
import {FeeCalculation} from "../../src/stable/libraries/FeeCalculation.sol";

contract StableStableHookBeforeSwapTest is Test, Deployers {
    using StateLibrary for IPoolManager;

    event PoolInitialized(PoolKey indexed poolKey, uint160 sqrtPriceX96, FeeConfig feeConfig);

    uint24 public constant LOG_K = 9140;
    uint24 public constant K = 16_609_443;
    uint24 public constant OPTIMAL_FEE_E6 = 90; // 0.9 bps
    uint160 public constant REFERENCE_SQRT_PRICE_X96 = Constants.SQRT_PRICE_1_1;
    int24 constant TICK_SPACING = 60;
    uint160 internal sqrtAmmPriceX96 = Constants.SQRT_PRICE_1_1;

    StableStableHook public hook;

    address owner = makeAddr("owner");
    address configManager = makeAddr("configManager");

    FeeConfig public feeConfig = FeeConfig({
        k: K,
        logK: LOG_K,
        optimalFeeE6: OPTIMAL_FEE_E6, // 0.9 bps
        referenceSqrtPriceX96: REFERENCE_SQRT_PRICE_X96
    });

    PoolKey public testPoolKey;

    function setUp() public {
        hook = StableStableHook(
            address(
                uint160(
                    uint256(type(uint160).max) & clearAllHookPermissionsMask | Hooks.BEFORE_INITIALIZE_FLAG
                        | Hooks.BEFORE_SWAP_FLAG
                )
            )
        );

        // Deploy hook with address(this) as the pool manager so we can mock extsload
        deployCodeTo("StableStableHook", abi.encode(IPoolManager(address(this)), owner, configManager), address(hook));

        testPoolKey = PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(address(1)),
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(address(hook))
        });

        // Mock the initialize call - we need to manually set the fee config since we're not using a real pool manager
        vm.prank(owner);
        // Call initializePool but we'll need to mock the manager.initialize call
        // Since address(this) is the manager, we need to implement the initialize function
        hook.initializePool(testPoolKey, Constants.SQRT_PRICE_1_1, feeConfig);
    }

    // Mock the pool manager's initialize function
    function initialize(PoolKey calldata, uint160) external pure returns (int24) {
        return 0; // Return some default tick
    }

    function callBeforeSwap(bool zeroForOne, int256 amountSpecified, uint160 sqrtPriceLimitX96)
        internal
        returns (uint24)
    {
        (uint256 beforeK, uint256 beforeLogK, uint24 beforeOptimalFeeE6, uint160 beforeReferenceSqrtPriceX96) =
            hook.feeConfig(testPoolKey.toId());
        SwapParams memory swapParams = SwapParams(zeroForOne, amountSpecified, sqrtPriceLimitX96);
        (bytes4 selector, BeforeSwapDelta delta, uint24 fee) =
            hook.beforeSwap(address(this), testPoolKey, swapParams, Constants.ZERO_BYTES);
        (uint256 afterK, uint256 afterLogK, uint24 afterOptimalFeeE6, uint160 afterReferenceSqrtPriceX96) =
            hook.feeConfig(testPoolKey.toId());

        assertEq(beforeK, afterK);
        assertEq(beforeLogK, afterLogK);
        assertEq(beforeOptimalFeeE6, afterOptimalFeeE6);
        assertEq(beforeReferenceSqrtPriceX96, afterReferenceSqrtPriceX96);

        assertEq(selector, IHooks.beforeSwap.selector);
        assertEq(BeforeSwapDelta.unwrap(delta), BeforeSwapDelta.unwrap(BeforeSwapDeltaLibrary.ZERO_DELTA));

        assert(LPFeeLibrary.isOverride(fee));
        fee = LPFeeLibrary.removeOverrideFlag(fee);

        return fee;
    }

    function extsload(bytes32 slot) external view returns (bytes32) {
        assertEq(slot, StateLibrary._getPoolStateSlot(testPoolKey.toId()));
        return bytes32(uint256(sqrtAmmPriceX96) | ((0x000000_000bb8_000000_ffff75) << 160));
    }

    function test_beforeSwap_insideOptimalRange_exactReferencePrice() public {
        // Set AMM price exactly at reference price
        sqrtAmmPriceX96 = REFERENCE_SQRT_PRICE_X96;
        uint24 fee;

        // Sell token0 at reference price - should charge optimal fee
        fee = callBeforeSwap(true, 50_000 * 1e18, (Constants.SQRT_PRICE_1_1 * 99) / 100);
        assertEq(fee, OPTIMAL_FEE_E6);

        // Buy token0 at reference price - should charge optimal fee
        fee = callBeforeSwap(false, 50_000 * 1e18, (Constants.SQRT_PRICE_1_1 * 101) / 100);
        assertEq(fee, OPTIMAL_FEE_E6);
    }

    function test_beforeSwap_insideOptimalRange_lowerBoundary() public {
        // Lower boundary = RP * (1 - optimalFeeE6) = RP * 0.999910
        // Compute boundary in price-space (Q192), then convert back to sqrtPriceX96 (Q96) via sqrt.
        uint256 ammPriceX192 =
            (uint256(REFERENCE_SQRT_PRICE_X96) * uint256(REFERENCE_SQRT_PRICE_X96) * (1_000_000 - (OPTIMAL_FEE_E6 - 1)))
                / 1_000_000; // slightly inside the lower boundary
        sqrtAmmPriceX96 = uint160(FixedPointMathLib.sqrt(ammPriceX192));

        // Sell token0 (pushing price down, away from boundary) - should have minimal fee
        uint24 sellFee = callBeforeSwap(true, 50_000 * 1e18, (Constants.SQRT_PRICE_1_1 * 99) / 100);
        assertLt(sellFee, OPTIMAL_FEE_E6);

        // Buy token0 (pushing price up, toward reference) - should charge higher fee to reach buy price
        uint24 buyFee = callBeforeSwap(false, 50_000 * 1e18, (Constants.SQRT_PRICE_1_1 * 101) / 100);
        assertGt(buyFee, OPTIMAL_FEE_E6);
    }

    function test_beforeSwap_insideOptimalRange_upperBoundary() public {
        // Upper boundary = RP / (1 - optimalFeeE6) = RP / 0.999910 ≈ RP * 1.000090009
        uint256 ammPriceX192 = (uint256(REFERENCE_SQRT_PRICE_X96) * REFERENCE_SQRT_PRICE_X96 * 1_000_090) / 1_000_000;
        sqrtAmmPriceX96 = uint160(FixedPointMathLib.sqrt(ammPriceX192));

        // Buy token0 (pushing price up, away from boundary) - should have minimal fee
        uint24 buyFee = callBeforeSwap(false, 50_000 * 1e18, (Constants.SQRT_PRICE_1_1 * 101) / 100);
        assertLt(buyFee, OPTIMAL_FEE_E6);

        // Sell token0 (pushing price down, toward reference) - should charge higher fee to reach sell price
        uint24 sellFee = callBeforeSwap(true, 50_000 * 1e18, (Constants.SQRT_PRICE_1_1 * 99) / 100);
        assertGt(sellFee, OPTIMAL_FEE_E6);
    }

    function test_fuzz_beforeSwap_insideOptimalRange_leftOfReference(uint24 priceBps) public {
        // Bound to inside optimal range: 999.91% to 100% of reference price
        priceBps = uint24(bound(priceBps, 999_911, 1_000_000));

        // Calculate AMM price
        uint256 ammPriceX192 = (uint256(REFERENCE_SQRT_PRICE_X96) * REFERENCE_SQRT_PRICE_X96 * priceBps) / 1_000_000;
        sqrtAmmPriceX96 = uint160(FixedPointMathLib.sqrt(ammPriceX192));

        uint24 sellFee = callBeforeSwap(true, 50_000 * 1e18, (Constants.SQRT_PRICE_1_1 * 99) / 100);
        uint24 buyFee = callBeforeSwap(false, 50_000 * 1e18, (Constants.SQRT_PRICE_1_1 * 101) / 100);

        assertLe(sellFee, OPTIMAL_FEE_E6);
        assertGe(buyFee, OPTIMAL_FEE_E6);
    }

    function test_fuzz_beforeSwap_insideOptimalRange_rightOfReference(uint24 priceBps) public {
        // Bound to inside optimal range: 100% to 100.009% of reference price
        priceBps = uint24(bound(priceBps, 1_000_000, 1_000_090));

        // Calculate AMM price
        uint256 ammPriceX192 = (uint256(REFERENCE_SQRT_PRICE_X96) * REFERENCE_SQRT_PRICE_X96 * priceBps) / 1_000_000;
        sqrtAmmPriceX96 = uint160(FixedPointMathLib.sqrt(ammPriceX192));

        uint24 sellFee = callBeforeSwap(true, 50_000 * 1e18, (Constants.SQRT_PRICE_1_1 * 99) / 100);
        uint24 buyFee = callBeforeSwap(false, 50_000 * 1e18, (Constants.SQRT_PRICE_1_1 * 101) / 100);

        assertLe(buyFee, OPTIMAL_FEE_E6);
        assertGe(sellFee, OPTIMAL_FEE_E6);
    }

    function test_fuzz_beforeSwap_insideOptimalRange_consistentEffectivePrices(uint24 priceBps) public {
        // Bound to inside optimal range: 999.91% to 100.009% of reference price
        priceBps = uint24(bound(priceBps, 999_911, 1_000_090));

        // Calculate AMM price
        uint256 ammPriceX192 = (uint256(REFERENCE_SQRT_PRICE_X96) * REFERENCE_SQRT_PRICE_X96 * priceBps) / 1_000_000;
        sqrtAmmPriceX96 = uint160(FixedPointMathLib.sqrt(ammPriceX192));

        uint24 sellFee = callBeforeSwap(true, 50_000 * 1e18, (Constants.SQRT_PRICE_1_1 * 99) / 100);
        uint24 buyFee = callBeforeSwap(false, 50_000 * 1e18, (Constants.SQRT_PRICE_1_1 * 101) / 100);

        // Calculate effective prices after fees
        // Sell: effectivePrice = ammPrice * (1 - fee)
        // Buy: effectivePrice = ammPrice / (1 - fee)
        uint256 effectiveSellPrice = (ammPriceX192 * (1_000_000 - sellFee)) / 1_000_000;
        uint256 effectiveBuyPrice = (ammPriceX192 * 1_000_000) / (1_000_000 - buyFee);

        // Target prices (from optimal range boundaries)
        // Sell boundary: RP * (1 - optimalFee)
        uint256 targetSellPrice =
            (uint256(REFERENCE_SQRT_PRICE_X96) * REFERENCE_SQRT_PRICE_X96 * (1_000_000 - OPTIMAL_FEE_E6)) / 1_000_000;
        // Buy boundary: RP / (1 - optimalFee)
        uint256 targetBuyPrice =
            (uint256(REFERENCE_SQRT_PRICE_X96) * REFERENCE_SQRT_PRICE_X96 * 1_000_000) / (1_000_000 - OPTIMAL_FEE_E6);

        // Effective prices should be close to target prices within 0.0001% tolerance
        assertApproxEqRel(effectiveSellPrice, targetSellPrice, 0.000001e18);
        assertApproxEqRel(effectiveBuyPrice, targetBuyPrice, 0.000001e18);
    }

    /// @notice Tests fee adjustment when price moves further from reference
    /// @dev When price moves further from reference, previousFee is adjusted upward via
    /// adjustPreviousFeeForPriceMovement() to maintain the same effective price. The adjusted
    /// fee then decays toward targetFee over time.
    ///
    /// NOTE: Do not set previousSqrtAmmPriceX96 = sqrtAmmPriceX96 (equal prices). In reality,
    /// swaps always move the price. Equal prices bypass adjustPreviousFeeForPriceMovement(),
    /// causing the test to use a stale fee that doesn't reflect actual price movement.
    function test_beforeSwap_unitSwapAmmPriceBiggerThanOptimalSpreadTarget() public {
        uint24 fee;
        uint160 ammPrice = uint160(1_000_130 * 2 ** 96) / 1_000_000;
        sqrtAmmPriceX96 = uint160(FixedPointMathLib.sqrt(uint256(ammPrice) * 2 ** 96));

        vm.roll(block.number + 750);

        fee = callBeforeSwap(false, 50_000 * 1e18, (Constants.SQRT_PRICE_1_1 * 101) / 100);
        assertEq(fee, 0);

        // Move price further right (from 1.00013 to 1.00014)
        ammPrice = uint160(1_000_140 * 2 ** 96) / 1_000_000;
        sqrtAmmPriceX96 = uint160(FixedPointMathLib.sqrt(uint256(ammPrice) * 2 ** 96));

        // With 0 blocks passed: fee is adjusted upward to maintain effective price, no decay yet
        fee = callBeforeSwap(true, 50_000 * 1e18, (Constants.SQRT_PRICE_1_1 * 99) / 100);
        assertEq(fee, 209); // 90 (optimal) + 119 (adjusted decaying fee, no decay)

        // With 750 blocks passed: adjusted fee decays toward targetFee
        vm.roll(block.number + 750);

        fee = callBeforeSwap(true, 50_000 * 1e18, (Constants.SQRT_PRICE_1_1 * 99) / 100);
        assertEq(fee, 204); // 90 (optimal) + 114 (decayed toward targetFee)
    }

    /// @notice Tests fee adjustment when price moves further from reference (price below reference)
    /// @dev When price moves further from reference, previousFee is adjusted upward via
    /// adjustPreviousFeeForPriceMovement() to maintain the same effective price. The adjusted
    /// fee then decays toward targetFee over time.
    ///
    /// NOTE: Do not set previousSqrtAmmPriceX96 = sqrtAmmPriceX96 (equal prices). In reality,
    /// swaps always move the price. Equal prices bypass adjustPreviousFeeForPriceMovement(),
    /// causing the test to use a stale fee that doesn't reflect actual price movement.
    function test_beforeSwap_unitSwapAmmPriceLessThanOptimalSpreadTarget() public {
        uint24 fee;
        uint160 ammPrice = uint160(999_870 * 2 ** 96) / 1_000_000;
        sqrtAmmPriceX96 = uint160(FixedPointMathLib.sqrt(uint256(ammPrice) * 2 ** 96));

        vm.roll(block.number + 750);

        fee = callBeforeSwap(true, 50_000 * 1e18, (Constants.SQRT_PRICE_1_1 * 99) / 100);
        assertEq(fee, 0);

        // Move price further left (from 0.99987 to 0.99986)
        ammPrice = uint160(999_860 * 2 ** 96) / 1_000_000;
        sqrtAmmPriceX96 = uint160(FixedPointMathLib.sqrt(uint256(ammPrice) * 2 ** 96));

        // With 0 blocks passed: fee is adjusted upward to maintain effective price, no decay yet
        fee = callBeforeSwap(false, 50_000 * 1e18, (Constants.SQRT_PRICE_1_1 * 101) / 100);
        assertEq(fee, 209); // 90 (optimal) + 119 (adjusted decaying fee, no decay)

        // With 750 blocks passed: adjusted fee decays toward targetFee
        vm.roll(block.number + 750);

        fee = callBeforeSwap(false, 50_000 * 1e18, (Constants.SQRT_PRICE_1_1 * 101) / 100);
        assertEq(fee, 204); // 90 (optimal) + 114 (decayed toward targetFee)
    }

    function test_beforeSwap_insideOptimalRange_gas() public {
        sqrtAmmPriceX96 = REFERENCE_SQRT_PRICE_X96;

        // construct swap params, and call beforeSwap
        SwapParams memory swapParams = SwapParams(true, 50_000 * 1e18, (Constants.SQRT_PRICE_1_1 * 99) / 100);
        hook.beforeSwap(address(this), testPoolKey, swapParams, Constants.ZERO_BYTES);
        vm.snapshotGasLastCall("beforeSwap_insideOptimalRange");
    }

    function test_beforeSwap_outsideOptimalRange_gas() public {
        uint160 ammPrice = uint160(1_000_130 * 2 ** 96) / 1_000_000;
        sqrtAmmPriceX96 = uint160(FixedPointMathLib.sqrt(uint256(ammPrice) * 2 ** 96));
        vm.roll(block.number + 750);

        SwapParams memory swapParams = SwapParams(true, 50_000 * 1e18, (Constants.SQRT_PRICE_1_1 * 99) / 100);
        hook.beforeSwap(address(this), testPoolKey, swapParams, Constants.ZERO_BYTES);
        vm.snapshotGasLastCall("beforeSwap_outsideOptimalRange");
    }

    // =============================================================================
    // INVARIANT: beforeSwap never reverts for any valid price, direction, and block gap
    // Exercises all state transitions in _calculateDecayingFee:
    //   - Inside/outside optimal range
    //   - Price moving toward/away from reference
    //   - Price crossing reference
    //   - Fee state reset, adjustment, cap, and pass-through
    //   - Decay over varying block gaps
    //   - Reference price at any valid position in the v4 range
    // =============================================================================

    /// @notice Fuzz test: beforeSwap never reverts across 5 sequential swaps with arbitrary
    /// AMM prices (full v4 range), fuzzed reference prices, directions, and block gaps.
    /// Fee is always <= 1_000_000 (100%).
    function test_fuzz_beforeSwap_neverReverts(
        uint160 fuzzedRefSqrtPrice,
        uint160 sqrtPrice1,
        uint160 sqrtPrice2,
        uint160 sqrtPrice3,
        uint160 sqrtPrice4,
        uint160 sqrtPrice5,
        uint256 directions,
        uint256 blockGaps
    ) public {
        // Calculate reference price bounds ensuring optimal range stays within v4 limits
        // Uses sqrt(1 - maxOptimalFee) since the optimal range is price-based (PR #18)
        uint256 sqrtOneMinusMaxFeeE6 = FixedPointMathLib.sqrt((FeeCalculation.ONE_E6 - 1e4) * FeeCalculation.ONE_E6);
        uint256 minRef = (uint256(TickMath.MIN_SQRT_PRICE) * FeeCalculation.ONE_E6 + sqrtOneMinusMaxFeeE6 - 1)
            / sqrtOneMinusMaxFeeE6;
        uint256 maxRef = uint256(TickMath.MAX_SQRT_PRICE) * sqrtOneMinusMaxFeeE6 / FeeCalculation.ONE_E6;

        // Fuzz reference price within valid bounds
        fuzzedRefSqrtPrice = uint160(bound(fuzzedRefSqrtPrice, minRef, maxRef - 1));

        // Update fee config with fuzzed reference price
        FeeConfig memory newFeeConfig =
            FeeConfig({k: K, logK: LOG_K, optimalFeeE6: OPTIMAL_FEE_E6, referenceSqrtPriceX96: fuzzedRefSqrtPrice});
        vm.prank(configManager);
        hook.updateFeeConfig(testPoolKey.toId(), newFeeConfig);

        // Decode directions and block gaps from single fuzzed values
        bool[5] memory zeroForOne;
        for (uint256 i = 0; i < 5; i++) {
            zeroForOne[i] = (directions >> i) & 1 == 1;
        }

        uint256[4] memory gaps;
        gaps[0] = bound(blockGaps & 0xFFFF, 0, 10_000);
        gaps[1] = bound((blockGaps >> 16) & 0xFFFF, 0, 10_000);
        gaps[2] = bound((blockGaps >> 32) & 0xFFFF, 0, 10_000);
        gaps[3] = bound((blockGaps >> 48) & 0xFFFF, 0, 10_000);

        // Fuzz AMM prices across the full valid v4 range
        uint160[5] memory prices;
        prices[0] = uint160(bound(sqrtPrice1, TickMath.MIN_SQRT_PRICE, TickMath.MAX_SQRT_PRICE - 1));
        prices[1] = uint160(bound(sqrtPrice2, TickMath.MIN_SQRT_PRICE, TickMath.MAX_SQRT_PRICE - 1));
        prices[2] = uint160(bound(sqrtPrice3, TickMath.MIN_SQRT_PRICE, TickMath.MAX_SQRT_PRICE - 1));
        prices[3] = uint160(bound(sqrtPrice4, TickMath.MIN_SQRT_PRICE, TickMath.MAX_SQRT_PRICE - 1));
        prices[4] = uint160(bound(sqrtPrice5, TickMath.MIN_SQRT_PRICE, TickMath.MAX_SQRT_PRICE - 1));

        for (uint256 i = 0; i < 5; i++) {
            sqrtAmmPriceX96 = prices[i];
            if (i > 0) vm.roll(block.number + gaps[i - 1]);

            uint160 limit = zeroForOne[i] ? TickMath.MIN_SQRT_PRICE : TickMath.MAX_SQRT_PRICE - 1;
            uint24 fee = callBeforeSwap(zeroForOne[i], 1000 * 1e18, limit);
            assertLe(fee, 1_000_000, "fee must be <= 100%");
        }
    }
}
