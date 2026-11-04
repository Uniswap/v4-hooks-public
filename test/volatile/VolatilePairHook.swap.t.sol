// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {VolatilePairTestBase} from "./base/VolatilePairTestBase.sol";
import {VolatilePairHook} from "../../src/volatile/VolatilePairHook.sol";
import {BaseDynamicFeeHook} from "../../src/base/BaseDynamicFeeHook.sol";
import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol";
import {Constants} from "@uniswap/v4-core/test/utils/Constants.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {FixedPoint128} from "@uniswap/v4-core/src/libraries/FixedPoint128.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {ProtocolFeeLibrary} from "@uniswap/v4-core/src/libraries/ProtocolFeeLibrary.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {ModifyLiquidityParams, SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
// Imported only so forge builds the artifact `deployCodeTo` loads by name.
import {ERC1967Proxy as _ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

/// End-to-end swaps through a real PoolManager. Fees are measured, not inferred from output.
contract VolatilePairHookSwapTest is VolatilePairTestBase, Deployers {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    uint256 internal constant ONE_E6 = 1e6;

    uint24 internal constant WIDE_RESTING_SPREAD_E6 = RESTING_SPREAD_E6 * 10;
    uint24 internal constant HOOKLESS_LP_FEE = 3000;

    int24 internal constant LIQUIDITY_TICK_LOWER = -6000;
    int24 internal constant LIQUIDITY_TICK_UPPER = 6000;
    int256 internal constant DEEP_LIQUIDITY = 1e24;

    /// ~1e-6 relative price impact.
    int256 internal constant PROBE_AMOUNT = 1e18;
    int256 internal constant OVERSIZED_AMOUNT = 1e22;
    uint256 internal constant DISPLACED_PRICE_E6 = 1_010_000;

    VolatilePairHook internal impl;
    PoolKey internal hooklessPoolKey;

    function setUp() public override {
        deployFreshManagerAndRouters();
        deployMintAndApprove2Currencies();

        impl = new VolatilePairHook(manager, MAX_TEMP_FEE_BLOCK_GAP);

        hook = VolatilePairHook(address(uint160(uint256(type(uint160).max) & clearAllHookPermissionsMask | HOOK_FLAGS)));
        deployCodeTo(
            "ERC1967Proxy.sol:ERC1967Proxy",
            abi.encode(
                address(impl), abi.encodeCall(BaseDynamicFeeHook.initialize, (owner, poolInitializer, configManager))
            ),
            address(hook)
        );

        testPoolKey = PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(address(hook))
        });
        hooklessPoolKey = testPoolKey;
        hooklessPoolKey.fee = HOOKLESS_LP_FEE;
        hooklessPoolKey.hooks = IHooks(address(0));

        vm.prank(poolInitializer);
        hook.initializePool(testPoolKey, Constants.SQRT_PRICE_1_1, _defaultConfig());
        manager.initialize(hooklessPoolKey, Constants.SQRT_PRICE_1_1);

        _seedLiquidity(testPoolKey);
        _seedLiquidity(hooklessPoolKey);
    }

    // -------------------------------------------------------------------------
    // Helpers
    // -------------------------------------------------------------------------

    function _seedLiquidity(PoolKey memory key_) internal {
        modifyLiquidityRouter.modifyLiquidity(
            key_,
            ModifyLiquidityParams({
                tickLower: LIQUIDITY_TICK_LOWER,
                tickUpper: LIQUIDITY_TICK_UPPER,
                liquidityDelta: DEEP_LIQUIDITY,
                salt: 0
            }),
            ZERO_BYTES
        );
    }

    function _rawSwap(PoolKey memory key_, SwapParams memory params) internal returns (BalanceDelta) {
        return swapRouter.swap(
            key_, params, PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}), ZERO_BYTES
        );
    }

    /// Fee the swap paid, in pips of the input: LP share from the `feeGrowthGlobal` delta (one liquidity value, so
    /// the swap must stay inside the single seeded position), total = LP + `protocolFeesAccrued` delta.
    function _swapMeasuringFees(bool zeroForOne, int256 amountSpecified)
        internal
        returns (uint256 lpFeeE6, uint256 totalFeeE6)
    {
        PoolId poolId = testPoolKey.toId();
        Currency inputCurrency = zeroForOne ? testPoolKey.currency0 : testPoolKey.currency1;

        uint128 liquidity = manager.getLiquidity(poolId);
        uint256 growthBefore = _inputFeeGrowth(poolId, zeroForOne);
        uint256 protocolBefore = manager.protocolFeesAccrued(inputCurrency);

        uint256 amountIn;
        {
            BalanceDelta delta = swap(testPoolKey, zeroForOne, amountSpecified, ZERO_BYTES);
            amountIn = zeroForOne ? uint256(uint128(-delta.amount0())) : uint256(uint128(-delta.amount1()));
        }

        uint256 lpFee =
            FullMath.mulDiv(_inputFeeGrowth(poolId, zeroForOne) - growthBefore, liquidity, FixedPoint128.Q128);
        uint256 totalFee = lpFee + (manager.protocolFeesAccrued(inputCurrency) - protocolBefore);

        lpFeeE6 = lpFee * ONE_E6 / amountIn;
        totalFeeE6 = totalFee * ONE_E6 / amountIn;
    }

    function _inputFeeGrowth(PoolId poolId, bool zeroForOne) internal view returns (uint256) {
        (uint256 growth0, uint256 growth1) = manager.getFeeGrowthGlobals(poolId);
        return zeroForOne ? growth0 : growth1;
    }

    /// Leaves `zeroForOne` as the backrun side.
    function _openBlockAndDisplaceUp() internal {
        _advanceBlocks(1);
        swap(testPoolKey, true, -PROBE_AMOUNT, ZERO_BYTES);

        uint160 target = _sqrtPriceScaled(_storedState(testPoolKey.toId()).sqrtPriceTopX96, DISPLACED_PRICE_E6);
        _rawSwap(
            testPoolKey, SwapParams({zeroForOne: false, amountSpecified: -OVERSIZED_AMOUNT, sqrtPriceLimitX96: target})
        );

        (uint160 priceAfter,,,) = manager.getSlot0(testPoolKey.toId());
        assertEq(priceAfter, target, "displacing swap must stop exactly at the limit");
    }

    // -------------------------------------------------------------------------
    // The fee reaches the swap
    // -------------------------------------------------------------------------

    function test_swap_chargesTheQuotedFee_bothDirections() public {
        _advanceBlocks(1);
        (uint24 quotedZeroForOneE6, uint24 quotedOneForZeroE6) = hook.getFee(testPoolKey);
        assertEq(quotedZeroForOneE6, NEUTRAL_FEE_E6, "zeroForOne quote");
        assertEq(quotedOneForZeroE6, NEUTRAL_FEE_E6, "oneForZero quote");

        uint256 snap = vm.snapshotState();
        (uint256 lpFeeE6,) = _swapMeasuringFees(true, -PROBE_AMOUNT);
        assertApproxEqAbs(lpFeeE6, quotedZeroForOneE6, 1, "zeroForOne charged");
        vm.revertToState(snap);

        (lpFeeE6,) = _swapMeasuringFees(false, -PROBE_AMOUNT);
        assertApproxEqAbs(lpFeeE6, quotedOneForZeroE6, 1, "oneForZero charged");
    }

    /// 0.1% tolerance: the probe's price impact is three orders below the 450-pip fee.
    function test_swap_feeReducesOutput_bothDirections() public {
        _advanceBlocks(1);
        uint256 expectedOutput = uint256(PROBE_AMOUNT) * (ONE_E6 - NEUTRAL_FEE_E6) / ONE_E6;

        uint256 snap = vm.snapshotState();
        BalanceDelta sell = swap(testPoolKey, true, -PROBE_AMOUNT, ZERO_BYTES);
        assertLt(sell.amount1(), -sell.amount0(), "zeroForOne output must be short of the input");
        assertApproxEqRel(uint256(uint128(sell.amount1())), expectedOutput, 0.001e18, "zeroForOne output");
        vm.revertToState(snap);

        BalanceDelta buy = swap(testPoolKey, false, -PROBE_AMOUNT, ZERO_BYTES);
        assertLt(buy.amount0(), -buy.amount1(), "oneForZero output must be short of the input");
        assertApproxEqRel(uint256(uint128(buy.amount0())), expectedOutput, 0.001e18, "oneForZero output");
    }

    function test_swap_widerRestingSpread_yieldsStrictlyLessOutput() public {
        _advanceBlocks(1);

        // reverted between legs, else the buy backruns the sell
        uint256 snap = vm.snapshotState();
        BalanceDelta narrowSell = swap(testPoolKey, true, -PROBE_AMOUNT, ZERO_BYTES);
        vm.revertToState(snap);
        BalanceDelta narrowBuy = swap(testPoolKey, false, -PROBE_AMOUNT, ZERO_BYTES);
        vm.revertToState(snap);

        _setConfig(_configWithRestingSpread(WIDE_RESTING_SPREAD_E6));
        (uint24 widenedE6,) = hook.getFee(testPoolKey);
        assertEq(widenedE6, WIDE_RESTING_SPREAD_E6 / 2, "wider pie must quote a wider split");

        uint256 widenedSnap = vm.snapshotState();
        BalanceDelta wideSell = swap(testPoolKey, true, -PROBE_AMOUNT, ZERO_BYTES);
        vm.revertToState(widenedSnap);
        BalanceDelta wideBuy = swap(testPoolKey, false, -PROBE_AMOUNT, ZERO_BYTES);

        assertGt(narrowSell.amount1(), wideSell.amount1(), "zeroForOne output must fall");
        assertGt(narrowBuy.amount0(), wideBuy.amount0(), "oneForZero output must fall");
    }

    // -------------------------------------------------------------------------
    // Mid-block
    // -------------------------------------------------------------------------

    function test_swap_thirdAndLaterSwapsInBlock_continuingAndReversing() public {
        PoolId poolId = testPoolKey.toId();
        _openBlockAndDisplaceUp();

        bytes32 stateAfterOpen = _rawStateHash(poolId);
        (uint24 askBaselineFeeE6,) = _storedBaselines(poolId);
        assertEq(askBaselineFeeE6, NEUTRAL_FEE_E6, "baselines stay at the block open");

        (uint24 quotedBackrunE6, uint24 quotedContinuingE6) = hook.getFee(testPoolKey);
        assertEq(quotedContinuingE6, NEUTRAL_FEE_E6 + MAX_MID_FADE_E6, "continuing side capped at maxMidFade");
        assertApproxEqAbs(quotedBackrunE6, NEUTRAL_FEE_E6 + 5_000, 5, "backrun side tracks the displacement");
        assertGt(quotedBackrunE6, quotedContinuingE6, "unwinding the move must cost more than extending it");

        (uint256 continuingFeeE6,) = _swapMeasuringFees(false, -PROBE_AMOUNT);
        assertApproxEqAbs(continuingFeeE6, quotedContinuingE6, 1, "swap 3 charged");

        // re-quoted: swap 3 nudged the price
        (uint24 quotedSwapFourE6,) = hook.getFee(testPoolKey);
        (uint256 reversingFeeE6,) = _swapMeasuringFees(true, -PROBE_AMOUNT);
        assertApproxEqAbs(reversingFeeE6, quotedSwapFourE6, 1, "swap 4 charged");
        // Ge, not Gt: the extra displacement is worth about the 1-pip measurement floor
        assertGe(reversingFeeE6, quotedBackrunE6, "the reversing leg still pays the backrun price");

        assertEq(_rawStateHash(poolId), stateAfterOpen, "no swap after the first may write state");
    }

    // -------------------------------------------------------------------------
    // Liquidity callbacks
    // -------------------------------------------------------------------------

    /// Add-liquidity callbacks are claimed but inert; remove-liquidity flags are off, so exits cannot be blocked.
    function test_modifyLiquidity_inertCallbacksLeaveDeltasAndFeeStateUntouched() public {
        ModifyLiquidityParams memory addParams =
            ModifyLiquidityParams({tickLower: -1200, tickUpper: 1200, liquidityDelta: 5e21, salt: bytes32(uint256(1))});
        ModifyLiquidityParams memory removeParams = ModifyLiquidityParams({
            tickLower: addParams.tickLower,
            tickUpper: addParams.tickUpper,
            liquidityDelta: -addParams.liquidityDelta,
            salt: addParams.salt
        });

        bytes32 stateBefore = _rawStateHash(testPoolKey.toId());

        vm.expectCall(address(hook), abi.encodeWithSelector(IHooks.beforeAddLiquidity.selector));
        vm.expectCall(address(hook), abi.encodeWithSelector(IHooks.afterAddLiquidity.selector));
        BalanceDelta hookedAdd = modifyLiquidityRouter.modifyLiquidity(testPoolKey, addParams, ZERO_BYTES);
        BalanceDelta hooklessAdd = modifyLiquidityRouter.modifyLiquidity(hooklessPoolKey, addParams, ZERO_BYTES);
        assertEq(BalanceDelta.unwrap(hookedAdd), BalanceDelta.unwrap(hooklessAdd), "add delta");

        vm.expectCall(address(hook), abi.encodeWithSelector(IHooks.beforeRemoveLiquidity.selector), 0);
        vm.expectCall(address(hook), abi.encodeWithSelector(IHooks.afterRemoveLiquidity.selector), 0);
        BalanceDelta hookedRemove = modifyLiquidityRouter.modifyLiquidity(testPoolKey, removeParams, ZERO_BYTES);
        BalanceDelta hooklessRemove = modifyLiquidityRouter.modifyLiquidity(hooklessPoolKey, removeParams, ZERO_BYTES);
        assertEq(BalanceDelta.unwrap(hookedRemove), BalanceDelta.unwrap(hooklessRemove), "remove delta");

        assertEq(_rawStateHash(testPoolKey.toId()), stateBefore, "liquidity must not touch the fee state");
    }

    // -------------------------------------------------------------------------
    // Partial fills
    // -------------------------------------------------------------------------

    function test_swap_stoppedByPriceLimit_settlesPartialFill() public {
        _advanceBlocks(1);
        (uint160 sqrtPriceX96,,,) = manager.getSlot0(testPoolKey.toId());
        uint160 limit = _sqrtPriceScaled(sqrtPriceX96, DISPLACED_PRICE_E6);

        BalanceDelta delta = _rawSwap(
            testPoolKey, SwapParams({zeroForOne: false, amountSpecified: -OVERSIZED_AMOUNT, sqrtPriceLimitX96: limit})
        );

        (uint160 priceAfter,,,) = manager.getSlot0(testPoolKey.toId());
        assertEq(priceAfter, limit, "price must settle at the limit");
        assertLt(uint256(uint128(-delta.amount1())), uint256(OVERSIZED_AMOUNT), "only part of the input is taken");
        assertGt(delta.amount0(), 0, "the filled portion must still pay out");
    }

    // -------------------------------------------------------------------------
    // Protocol fee
    // -------------------------------------------------------------------------

    /// v4 takes the protocol rate off the input first and the hook's fee off the remainder, so against the full input
    /// LP share = quote * (1e6 - protocol) / 1e6.
    function _assertProtocolFeeCompounds(uint256 lpFeeE6, uint256 totalFeeE6, uint24 quotedE6, string memory label)
        internal
        pure
    {
        uint256 protocolE6 = ProtocolFeeLibrary.MAX_PROTOCOL_FEE;
        assertApproxEqAbs(totalFeeE6 - lpFeeE6, protocolE6, 1, string.concat(label, ": protocol takes its own rate"));
        assertApproxEqAbs(
            lpFeeE6, uint256(quotedE6) * (ONE_E6 - protocolE6) / ONE_E6, 1, string.concat(label, ": LP share")
        );
        assertApproxEqAbs(
            totalFeeE6,
            ProtocolFeeLibrary.calculateSwapFee(ProtocolFeeLibrary.MAX_PROTOCOL_FEE, quotedE6),
            1,
            string.concat(label, ": total is the two compounded")
        );
    }

    function test_swap_withMaxProtocolFee_compoundsOnTopOfTheLpFee() public {
        _setMaxProtocolFee();
        _advanceBlocks(1);

        (uint24 quotedE6,) = hook.getFee(testPoolKey);
        assertEq(quotedE6, NEUTRAL_FEE_E6, "the hook quote is independent of the protocol fee");

        (uint256 lpFeeE6, uint256 totalFeeE6) = _swapMeasuringFees(true, -PROBE_AMOUNT);
        _assertProtocolFeeCompounds(lpFeeE6, totalFeeE6, quotedE6, "neutral open");
    }

    function test_swap_withMaxProtocolFee_midBlockDirectionalityHolds() public {
        _setMaxProtocolFee();
        _openBlockAndDisplaceUp();

        (uint24 quotedBackrunE6, uint24 quotedContinuingE6) = hook.getFee(testPoolKey);
        assertEq(quotedContinuingE6, NEUTRAL_FEE_E6 + MAX_MID_FADE_E6, "continuing quote unchanged");
        assertGt(quotedBackrunE6, quotedContinuingE6, "backrun quote still the expensive side");

        (uint256 continuingLpFeeE6, uint256 continuingTotalE6) = _swapMeasuringFees(false, -PROBE_AMOUNT);
        _assertProtocolFeeCompounds(continuingLpFeeE6, continuingTotalE6, quotedContinuingE6, "continuing");

        (quotedBackrunE6,) = hook.getFee(testPoolKey);
        (uint256 backrunLpFeeE6, uint256 backrunTotalE6) = _swapMeasuringFees(true, -PROBE_AMOUNT);
        _assertProtocolFeeCompounds(backrunLpFeeE6, backrunTotalE6, quotedBackrunE6, "backrun");

        assertGt(backrunLpFeeE6, continuingLpFeeE6, "the backrun leg still pays more to LPs");
        assertGt(backrunTotalE6, continuingTotalE6, "and more in total");
    }

    function _setMaxProtocolFee() internal {
        vm.prank(feeController);
        manager.setProtocolFee(
            testPoolKey, uint24(ProtocolFeeLibrary.MAX_PROTOCOL_FEE) << 12 | uint24(ProtocolFeeLibrary.MAX_PROTOCOL_FEE)
        );
    }

    // -------------------------------------------------------------------------
    // Gas
    // -------------------------------------------------------------------------

    function test_swap_gas() public {
        _advanceBlocks(1);
        _rawSwap(
            testPoolKey,
            SwapParams({zeroForOne: true, amountSpecified: -PROBE_AMOUNT, sqrtPriceLimitX96: MIN_PRICE_LIMIT})
        );
        vm.snapshotGasLastCall("swap");
    }

    function test_swapHookless_gas() public {
        _advanceBlocks(1);
        _rawSwap(
            hooklessPoolKey,
            SwapParams({zeroForOne: true, amountSpecified: -PROBE_AMOUNT, sqrtPriceLimitX96: MIN_PRICE_LIMIT})
        );
        vm.snapshotGasLastCall("swapHookless");
    }
}
