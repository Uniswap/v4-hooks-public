// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";

import {DeployGatewayHook} from "../../script/DeployGatewayHook.s.sol";
import {GatewayHook} from "../../src/guidestar/GatewayHook.sol";
import {Guidestar4Stable} from "../../src/guidestar/Guidestar4Stable.sol";

import {Constants} from "../utils/Constants.sol";
import {PoolManager} from "@uniswap/v4-core/src/PoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TestERC20} from "@uniswap/v4-core/src/test/TestERC20.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {ModifyLiquidityParams, SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";

contract UnitStableBeforeSwapTest is Test {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;

    DeployGatewayHook deployGatewayHook;
    GatewayHook gatewayHook;
    Guidestar4Stable implHook;

    PoolKey guidestarKey;
    uint160 constant FLAGS = uint160(
        Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_SWAP_FLAG
            | Hooks.AFTER_REMOVE_LIQUIDITY_FLAG | Hooks.AFTER_REMOVE_LIQUIDITY_RETURNS_DELTA_FLAG
    );
    TestERC20 token0;
    TestERC20 token1;
    int24 constant TICK_SPACING = 60;
    uint160 internal sqrtAmmPrice = Constants.SQRT_RATIO_1_1;

    function setUp() public {
        token0 = new TestERC20(2 ** 128);
        token1 = new TestERC20(2 ** 128);
        deployGatewayHook = new DeployGatewayHook();
        gatewayHook = deployGatewayHook.run(address(this), FLAGS, address(this));

        implHook = new Guidestar4Stable(IPoolManager(address(this)), address(this), address(gatewayHook));
        gatewayHook.setImplementation(IHooks(address(implHook)));

        guidestarKey = PoolKey(
            Currency.wrap(address(token1)),
            Currency.wrap(address(token0)),
            LPFeeLibrary.DYNAMIC_FEE_FLAG,
            TICK_SPACING,
            gatewayHook
        );

        Guidestar4Stable.FeeData memory feeData = Guidestar4Stable.FeeData({
            flags: 1, // бит 0 = stable
            previousFee: 1e12 + 1, // INVALID_FEE
            previousSqrtAmmPrice: sqrtAmmPrice,
            blockNumber: block.number,
            timeStep: 1 days, // 86400
            rate: 7 // 0.7 bps
        });

        Guidestar4Stable.HookParams memory hookParams = Guidestar4Stable.HookParams({
            flags: 1,
            k: 16_609_443, // k = 99% в Q0.24
            logK: 9140,
            optimalFeeSpread: 90, // 0.9 bps
            referenceSqrtPrice: uint160(2 ** 96), // sqrt(1) = 1 << 96
            blockTime: 12 * 32, // 12s / блок * 32 = 384
            previousTimestamp: block.timestamp
        });

        implHook.setFeeData(guidestarKey, feeData);
        implHook.setHookParams(guidestarKey, hookParams);
    }

    function callBeforeSwap(
        bool zeroForOne,
        int256 amountSpecified,
        uint160 sqrtPriceLimitX96
    )
        internal
        returns (uint24)
    {
        Guidestar4Stable.HookParams memory hookParams = implHook.hookParams(guidestarKey.toId());
        SwapParams memory swapParams =
            SwapParams({zeroForOne: zeroForOne, amountSpecified: amountSpecified, sqrtPriceLimitX96: sqrtPriceLimitX96});
        (bytes4 selector, BeforeSwapDelta delta, uint24 fee) =
            gatewayHook.beforeSwap(address(this), guidestarKey, swapParams, Constants.ZERO_BYTES);
        Guidestar4Stable.HookParams memory afterHookParams = implHook.hookParams(guidestarKey.toId());

        assertEq(hookParams.flags, afterHookParams.flags);
        assertEq(hookParams.k, afterHookParams.k);
        assertEq(hookParams.logK, afterHookParams.logK);
        assertEq(hookParams.optimalFeeSpread, afterHookParams.optimalFeeSpread);
        assertEq(hookParams.referenceSqrtPrice, afterHookParams.referenceSqrtPrice);
        assertEq(hookParams.blockTime, afterHookParams.blockTime);
        assertEq(hookParams.previousTimestamp, afterHookParams.previousTimestamp);

        assertEq(selector, IHooks.beforeSwap.selector);
        assertEq(BeforeSwapDelta.unwrap(delta), BeforeSwapDelta.unwrap(BeforeSwapDeltaLibrary.ZERO_DELTA));

        assert(LPFeeLibrary.isOverride(fee));
        fee = LPFeeLibrary.removeOverrideFlag(fee);

        return fee;
    }

    function extsload(bytes32 slot) external view returns (bytes32) {
        assertEq(slot, StateLibrary._getPoolStateSlot(guidestarKey.toId()));
        return bytes32(uint256(sqrtAmmPrice) | ((0x000000_000bb8_000000_ffff75) << 160));
    }

    function testStableBeforeSwapSecondInFirstBlock() public {
        sqrtAmmPrice = sqrtAmmPrice * 1;
        uint24 fee;

        fee = callBeforeSwap(true, 50_000 * 1e18, (Constants.SQRT_RATIO_1_1 * 99) / 100);
        assertEq(fee, 90);

        fee = callBeforeSwap(false, 50_000 * 1e18, (Constants.SQRT_RATIO_1_1 * 101) / 100);
        assertEq(fee, 90);
    }

    function testUnitSwapAmmPriceBiggerThanOptimalSpreadTargetMovedOpposite() public {
        uint24 fee;
        uint160 ammPrice = uint160(1_000_130 * 2 ** 96) / 1_000_000;
        sqrtAmmPrice = uint160(FixedPointMathLib.sqrt(uint256(ammPrice) * 2 ** 96));

        vm.roll(block.number + 750);

        fee = callBeforeSwap(false, 50_000 * 1e18, (Constants.SQRT_RATIO_1_1 * 101) / 100);
        assertEq(fee, 0);

        ammPrice = uint160(1_000_140 * 2 ** 96) / 1_000_000;
        sqrtAmmPrice = uint160(FixedPointMathLib.sqrt(uint256(ammPrice) * 2 ** 96));
        Guidestar4Stable.FeeData memory feeData = implHook.feeData(guidestarKey.toId());
        feeData.previousSqrtAmmPrice = sqrtAmmPrice;
        implHook.setFeeData(guidestarKey, feeData);

        fee = callBeforeSwap(true, 50_000 * 1e18, (Constants.SQRT_RATIO_1_1 * 99) / 100);
        assertEq(fee, 90 + 114);
    }

    function testUnitSwapAmmPriceLessThanOptimalSpreadTargetMovedOpposite() public {
        uint24 fee;
        uint160 ammPrice = uint160(999_870 * 2 ** 96) / 1_000_000;
        sqrtAmmPrice = uint160(FixedPointMathLib.sqrt(uint256(ammPrice) * 2 ** 96));

        vm.roll(block.number + 750);

        fee = callBeforeSwap(true, 50_000 * 1e18, (Constants.SQRT_RATIO_1_1 * 99) / 100);
        assertEq(fee, 0);

        ammPrice = uint160(999_860 * 2 ** 96) / 1_000_000;
        sqrtAmmPrice = uint160(FixedPointMathLib.sqrt(uint256(ammPrice) * 2 ** 96));
        Guidestar4Stable.FeeData memory feeData = implHook.feeData(guidestarKey.toId());
        feeData.previousSqrtAmmPrice = sqrtAmmPrice;
        implHook.setFeeData(guidestarKey, feeData);

        fee = callBeforeSwap(false, 50_000 * 1e18, (Constants.SQRT_RATIO_1_1 * 101) / 100);
        assertEq(fee, 90 + 114);
    }

    function testRevertTooMuchNegativeRateAccumulated() public {
        Guidestar4Stable.FeeData memory feeData = implHook.feeData(guidestarKey.toId());

        feeData.flags = feeData.flags | 2;

        Guidestar4Stable.FeeData memory feeData_ =
            toFeeData(feeData.flags, feeData.previousFee, feeData.previousSqrtAmmPrice, feeData.blockNumber, -128, 1200);

        implHook.setFeeData(guidestarKey, feeData_);

        uint256 passed = 100;
        vm.warp(block.timestamp + passed * 24 * 60 * 60);
        vm.roll(block.number + 1000);

        gatewayHook.beforeSwap(
            address(this),
            guidestarKey,
            SwapParams(false, 50_000 * 1e18, Constants.SQRT_RATIO_1_1),
            Constants.ZERO_BYTES
        );

        Guidestar4Stable.HookParams memory hookParams = implHook.hookParams(guidestarKey.toId());

        assertEq(2 ** 32, hookParams.referenceSqrtPrice);
    }

    function testAfterAddLiquidityShouldRevertIfMsgSenderIsNotPoolManager() public {
        ModifyLiquidityParams memory mlParams;
        BalanceDelta bd;

        vm.expectRevert(GatewayHook.NotPoolManager.selector);
        vm.prank(address(123));
        gatewayHook.afterAddLiquidity(address(this), guidestarKey, mlParams, bd, bd, abi.encode());
    }

    function testBeforeInitializeShouldRevertIfPoolIsNotUsingDynamicFee() public {
        guidestarKey = PoolKey(
            Currency.wrap(address(token1)), Currency.wrap(address(token0)), uint24(0), TICK_SPACING, gatewayHook
        );
        vm.expectRevert(Guidestar4Stable.MustUseDynamicFee.selector);
        vm.prank(address(gatewayHook));
        implHook.beforeInitialize(address(this), guidestarKey, 0);
    }

    function toFeeData(
        uint256 flagsX4,
        uint256 previousFeeX40,
        uint256 previousSqrtAmmPriceX160,
        uint256 blockNumberX32,
        int256 rateX9,
        uint256 timeStepSecs
    )
        public
        pure
        returns (Guidestar4Stable.FeeData memory)
    {
        unchecked {
            return Guidestar4Stable.FeeData({
                flags: flagsX4 & (2 ** 4 - 1),
                previousFee: previousFeeX40 & (2 ** 40 - 1),
                previousSqrtAmmPrice: uint160(previousSqrtAmmPriceX160 & (2 ** 160 - 1)),
                blockNumber: blockNumberX32 & (2 ** 32 - 1),
                timeStep: (timeStepSecs / (20 * 60)) & (2 ** 10 - 1),
                rate: rateX9
            });
        }
    }
}
