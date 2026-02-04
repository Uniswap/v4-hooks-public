// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {FeeConfigurationImplementation} from "../../src/stable/test/FeeConfigurationImplementation.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {FeeConfig, FeeState, IFeeConfiguration} from "../../src/stable/interfaces/IFeeConfiguration.sol";
import {Constants} from "@uniswap/v4-core/test/utils/Constants.sol";
import {FeeCalculation} from "../../src/stable/libraries/FeeCalculation.sol";

contract FeeConfigurationImplementationTest is Test {
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;

    event ConfigManagerUpdated(address indexed configManager);
    event FeeConfigUpdated(PoolId indexed poolId, FeeConfig feeConfig);

    uint24 public constant K = 16_609_443;
    uint24 public constant LOG_K = 9140;
    uint24 public constant OPTIMAL_FEE_E6 = 90; // 0.9 bps
    uint160 public constant REFERENCE_SQRT_PRICE_X96 = Constants.SQRT_PRICE_1_1;

    FeeConfigurationImplementation public feeConfigurationImplementation;
    PoolKey public testPoolKey;

    address poolFeeController = makeAddr("poolFeeController");

    function setUp() public {
        feeConfigurationImplementation = new FeeConfigurationImplementation(poolFeeController);

        testPoolKey = PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(address(1)),
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: TickMath.MIN_TICK_SPACING,
            hooks: IHooks(address(feeConfigurationImplementation))
        });
    }

    function test_updateFeeConfig_revertsWithNotConfigManager() public {
        FeeConfig memory newConfig = FeeConfig({
            k: K, logK: LOG_K, optimalFeeE6: OPTIMAL_FEE_E6, referenceSqrtPriceX96: REFERENCE_SQRT_PRICE_X96
        });

        vm.prank(address(this));
        vm.expectRevert(abi.encodeWithSelector(IFeeConfiguration.NotConfigManager.selector, address(this)));
        feeConfigurationImplementation.updateFeeConfig(testPoolKey.toId(), newConfig);
    }

    function test_updateFeeConfig_revertsWithInvalidReferenceSqrtPriceX96_belowMin() public {
        FeeConfig memory newConfig = FeeConfig({
            k: K, logK: LOG_K, optimalFeeE6: OPTIMAL_FEE_E6, referenceSqrtPriceX96: TickMath.MIN_SQRT_PRICE - 1
        });

        vm.prank(poolFeeController);
        vm.expectRevert(
            abi.encodeWithSelector(IFeeConfiguration.InvalidReferenceSqrtPriceX96.selector, TickMath.MIN_SQRT_PRICE - 1)
        );
        feeConfigurationImplementation.updateFeeConfig(testPoolKey.toId(), newConfig);
    }

    function test_updateFeeConfig_revertsWithInvalidReferenceSqrtPriceX96_atMin() public {
        // MIN_SQRT_PRICE is now invalid because the optimal range would extend below it
        // minBoundedRef = MIN_SQRT_PRICE * 1e6 / (1e6 - MAX_OPTIMAL_FEE_E6)
        // = MIN_SQRT_PRICE * 1e6 / 990000 > MIN_SQRT_PRICE
        FeeConfig memory newConfig = FeeConfig({
            k: K, logK: LOG_K, optimalFeeE6: OPTIMAL_FEE_E6, referenceSqrtPriceX96: TickMath.MIN_SQRT_PRICE
        });

        vm.prank(poolFeeController);
        vm.expectRevert(
            abi.encodeWithSelector(IFeeConfiguration.InvalidReferenceSqrtPriceX96.selector, TickMath.MIN_SQRT_PRICE)
        );
        feeConfigurationImplementation.updateFeeConfig(testPoolKey.toId(), newConfig);
    }

    function test_updateFeeConfig_revertsWithInvalidReferenceSqrtPriceX96_atMax() public {
        // MAX_SQRT_PRICE - 1 is now invalid because the optimal range would extend above MAX_SQRT_PRICE
        // maxBoundedRef = MAX_SQRT_PRICE * (1e6 - MAX_OPTIMAL_FEE_E6) / 1e6
        // = MAX_SQRT_PRICE * 990000 / 1e6 < MAX_SQRT_PRICE
        FeeConfig memory newConfig = FeeConfig({
            k: K, logK: LOG_K, optimalFeeE6: OPTIMAL_FEE_E6, referenceSqrtPriceX96: TickMath.MAX_SQRT_PRICE - 1
        });

        vm.prank(poolFeeController);
        vm.expectRevert(
            abi.encodeWithSelector(IFeeConfiguration.InvalidReferenceSqrtPriceX96.selector, TickMath.MAX_SQRT_PRICE - 1)
        );
        feeConfigurationImplementation.updateFeeConfig(testPoolKey.toId(), newConfig);
    }

    function test_updateFeeConfig_succeedsWithBoundedReferencePrices() public {
        // Calculate the bounded min/max reference prices
        uint256 oneMinusMaxFee = FeeCalculation.ONE_E6 - feeConfigurationImplementation.MAX_OPTIMAL_FEE_E6();
        uint256 minBoundedRef =
            (uint256(TickMath.MIN_SQRT_PRICE) * FeeCalculation.ONE_E6 + oneMinusMaxFee - 1) / oneMinusMaxFee;
        uint256 maxBoundedRef = uint256(TickMath.MAX_SQRT_PRICE) * oneMinusMaxFee / FeeCalculation.ONE_E6;

        // Test minimum bounded reference price (inclusive - MIN_SQRT_PRICE is valid in v4)
        FeeConfig memory minConfig =
            FeeConfig({k: K, logK: LOG_K, optimalFeeE6: OPTIMAL_FEE_E6, referenceSqrtPriceX96: uint160(minBoundedRef)});
        vm.prank(poolFeeController);
        feeConfigurationImplementation.updateFeeConfig(testPoolKey.toId(), minConfig);

        // Test maximum bounded reference price - 1 (exclusive - MAX_SQRT_PRICE is invalid in v4)
        // maxBoundedRef itself is invalid, so we use maxBoundedRef - 1
        FeeConfig memory maxConfig = FeeConfig({
            k: K, logK: LOG_K, optimalFeeE6: OPTIMAL_FEE_E6, referenceSqrtPriceX96: uint160(maxBoundedRef - 1)
        });
        vm.prank(poolFeeController);
        feeConfigurationImplementation.updateFeeConfig(testPoolKey.toId(), maxConfig);

        // Verify the optimal range at boundaries stays within v4 limits
        // At minBoundedRef: lowerOptimal = minBoundedRef * (1 - maxOptimalFee) >= MIN_SQRT_PRICE
        uint256 lowerOptimalAtMin = minBoundedRef * oneMinusMaxFee / FeeCalculation.ONE_E6;
        assertGe(lowerOptimalAtMin, TickMath.MIN_SQRT_PRICE);

        // At maxBoundedRef - 1: upperOptimal = (maxBoundedRef - 1) / (1 - maxOptimalFee) < MAX_SQRT_PRICE
        uint256 upperOptimalAtMax = (maxBoundedRef - 1) * FeeCalculation.ONE_E6 / oneMinusMaxFee;
        assertLt(upperOptimalAtMax, TickMath.MAX_SQRT_PRICE);
    }

    function test_updateFeeConfig_revertsWithInvalidReferenceSqrtPriceX96_atMaxBounded() public {
        // maxBoundedRef is exactly at the exclusive boundary, so it should fail
        uint256 oneMinusMaxFee = FeeCalculation.ONE_E6 - feeConfigurationImplementation.MAX_OPTIMAL_FEE_E6();
        uint256 maxBoundedRef = uint256(TickMath.MAX_SQRT_PRICE) * oneMinusMaxFee / FeeCalculation.ONE_E6;

        FeeConfig memory newConfig =
            FeeConfig({k: K, logK: LOG_K, optimalFeeE6: OPTIMAL_FEE_E6, referenceSqrtPriceX96: uint160(maxBoundedRef)});

        vm.prank(poolFeeController);
        vm.expectRevert(abi.encodeWithSelector(IFeeConfiguration.InvalidReferenceSqrtPriceX96.selector, maxBoundedRef));
        feeConfigurationImplementation.updateFeeConfig(testPoolKey.toId(), newConfig);
    }

    function test_updateFeeConfig_revertsWithInvalidOptimalFeeE6() public {
        FeeConfig memory newConfig =
            FeeConfig({k: K, logK: LOG_K, optimalFeeE6: 1e4 + 1, referenceSqrtPriceX96: REFERENCE_SQRT_PRICE_X96});

        vm.prank(poolFeeController);
        vm.expectRevert(abi.encodeWithSelector(IFeeConfiguration.InvalidOptimalFeeE6.selector, 1e4 + 1));
        feeConfigurationImplementation.updateFeeConfig(testPoolKey.toId(), newConfig);
    }

    function test_updateFeeConfig_revertsWithInvalidKAndLogK() public {
        FeeConfig memory newConfig =
            FeeConfig({k: 0, logK: 0, optimalFeeE6: OPTIMAL_FEE_E6, referenceSqrtPriceX96: REFERENCE_SQRT_PRICE_X96});

        vm.prank(poolFeeController);
        vm.expectRevert(abi.encodeWithSelector(IFeeConfiguration.InvalidKAndLogK.selector, 0, 0));
        feeConfigurationImplementation.updateFeeConfig(testPoolKey.toId(), newConfig);
    }

    function test_updateFeeConfig_succeeds() public {
        (uint256 k, uint256 logK, uint24 optimalFeeE6, uint160 referenceSqrtPriceX96) =
            feeConfigurationImplementation.feeConfig(testPoolKey.toId());
        assertEq(k, 0);
        assertEq(logK, 0);
        assertEq(optimalFeeE6, 0);
        assertEq(referenceSqrtPriceX96, 0);

        FeeConfig memory newConfig = FeeConfig({
            k: K, logK: LOG_K, optimalFeeE6: OPTIMAL_FEE_E6, referenceSqrtPriceX96: REFERENCE_SQRT_PRICE_X96
        });

        vm.expectEmit(true, false, false, true);
        emit FeeConfigUpdated(testPoolKey.toId(), newConfig);
        vm.prank(poolFeeController);
        feeConfigurationImplementation.updateFeeConfig(testPoolKey.toId(), newConfig);

        // Verify FeeConfig was updated
        (k, logK, optimalFeeE6, referenceSqrtPriceX96) = feeConfigurationImplementation.feeConfig(testPoolKey.toId());
        assertEq(k, K);
        assertEq(logK, LOG_K);
        assertEq(optimalFeeE6, OPTIMAL_FEE_E6);
        assertEq(referenceSqrtPriceX96, REFERENCE_SQRT_PRICE_X96);

        // Verify FeeState was reset
        (uint256 previousFeeE12, uint160 previousSqrtAmmPriceX96, uint256 blockNumber) =
            feeConfigurationImplementation.feeState(testPoolKey.toId());
        assertEq(previousFeeE12, 1e12 + 1);
        assertEq(previousSqrtAmmPriceX96, 0);
        assertEq(blockNumber, block.number);
    }

    function test_updateFeeConfig_gas() public {
        FeeConfig memory newConfig = FeeConfig({
            k: K, logK: LOG_K, optimalFeeE6: OPTIMAL_FEE_E6, referenceSqrtPriceX96: REFERENCE_SQRT_PRICE_X96
        });

        vm.prank(poolFeeController);
        feeConfigurationImplementation.updateFeeConfig(testPoolKey.toId(), newConfig);
        vm.snapshotGasLastCall("updateFeeConfig");
    }

    function test_setConfigManager_revertsWithNotConfigManager() public {
        vm.prank(address(this));
        vm.expectRevert(abi.encodeWithSelector(IFeeConfiguration.NotConfigManager.selector, address(this)));
        feeConfigurationImplementation.setConfigManager(address(1));
    }

    function test_setConfigManager_succeeds() public {
        assertEq(feeConfigurationImplementation.configManager(), poolFeeController);
        vm.expectEmit(true, false, false, true);
        emit ConfigManagerUpdated(address(1));
        vm.prank(poolFeeController);
        feeConfigurationImplementation.setConfigManager(address(1));
        assertEq(feeConfigurationImplementation.configManager(), address(1));
    }

    function test_setConfigManager_gas() public {
        vm.prank(poolFeeController);
        feeConfigurationImplementation.setConfigManager(address(1));
        vm.snapshotGasLastCall("setConfigManager");
    }
}
