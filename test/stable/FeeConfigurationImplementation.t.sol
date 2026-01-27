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
import {FeeConfig, HistoricalFeeData, IFeeConfiguration} from "../../src/stable/interfaces/IFeeConfiguration.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";

contract FeeConfigurationImplementationTest is Test {
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;

    event ConfigManagerUpdated(address indexed configManager);
    event DecayFactorUpdated(PoolId indexed poolId, uint256 k, uint256 logK);
    event OptimalFeeRateUpdated(PoolId indexed poolId, uint256 optimalFeeRate);
    event ReferenceSqrtPriceX96Updated(PoolId indexed poolId, uint160 referenceSqrtPriceX96);

    uint24 public constant OPTIMAL_FEE_SPREAD = 90; // 0.9 bps
    uint160 public constant REFERENCE_SQRT_PRICE_X96 = TickMath.MIN_SQRT_PRICE;
    uint256 public constant LOG_K = 9140;
    uint256 public constant K = 16_609_443;

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

    function test_updateDecayFactor_revertsWithNotConfigManager() public {
        vm.prank(address(this));
        vm.expectRevert(abi.encodeWithSelector(IFeeConfiguration.NotConfigManager.selector, address(this)));
        feeConfigurationImplementation.updateDecayFactor(testPoolKey.toId(), K - 1, LOG_K - 1);
    }

    function test_updateDecayFactor_succeeds() public {
        vm.expectEmit(true, false, false, true);
        emit DecayFactorUpdated(testPoolKey.toId(), K - 1, LOG_K - 1);
        vm.prank(poolFeeController);
        feeConfigurationImplementation.updateDecayFactor(testPoolKey.toId(), K - 1, LOG_K - 1);
        (uint256 k, uint256 logK,,) = feeConfigurationImplementation.feeConfig(testPoolKey.toId());
        assertEq(k, K - 1);
        assertEq(logK, LOG_K - 1);
    }

    function test_updateDecayFactor_gas() public {
        vm.prank(poolFeeController);
        feeConfigurationImplementation.updateDecayFactor(testPoolKey.toId(), K - 1, LOG_K - 1);
        vm.snapshotGasLastCall("updateDecayFactor");
    }

    function test_updateOptimalFeeRate_revertsWithNotConfigManager() public {
        vm.prank(address(this));
        vm.expectRevert(abi.encodeWithSelector(IFeeConfiguration.NotConfigManager.selector, address(this)));
        feeConfigurationImplementation.updateOptimalFeeRate(testPoolKey.toId(), OPTIMAL_FEE_SPREAD - 1);
    }

    function test_updateOptimalFeeRate_succeeds() public {
        vm.expectEmit(true, false, false, true);
        emit OptimalFeeRateUpdated(testPoolKey.toId(), OPTIMAL_FEE_SPREAD - 1);
        vm.prank(poolFeeController);
        feeConfigurationImplementation.updateOptimalFeeRate(testPoolKey.toId(), OPTIMAL_FEE_SPREAD - 1);
        (,, uint256 optimalFeeRate,) = feeConfigurationImplementation.feeConfig(testPoolKey.toId());
        assertEq(optimalFeeRate, OPTIMAL_FEE_SPREAD - 1);
    }

    function test_updateOptimalFeeRate_gas() public {
        vm.prank(poolFeeController);
        feeConfigurationImplementation.updateOptimalFeeRate(testPoolKey.toId(), OPTIMAL_FEE_SPREAD - 1);
        vm.snapshotGasLastCall("updateOptimalFeeRate");
    }

    function test_updateReferenceSqrtPrice_revertsWithNotConfigManager() public {
        vm.prank(address(this));
        vm.expectRevert(abi.encodeWithSelector(IFeeConfiguration.NotConfigManager.selector, address(this)));
        feeConfigurationImplementation.updateReferenceSqrtPriceX96(testPoolKey.toId(), REFERENCE_SQRT_PRICE_X96 - 1);
    }

    function test_updateReferenceSqrtPrice_succeeds() public {
        vm.expectEmit(true, false, false, true);
        emit ReferenceSqrtPriceX96Updated(testPoolKey.toId(), REFERENCE_SQRT_PRICE_X96 - 1);
        vm.prank(poolFeeController);
        feeConfigurationImplementation.updateReferenceSqrtPriceX96(testPoolKey.toId(), REFERENCE_SQRT_PRICE_X96 - 1);
        (,,, uint160 referenceSqrtPriceX96) = feeConfigurationImplementation.feeConfig(testPoolKey.toId());
        assertEq(referenceSqrtPriceX96, REFERENCE_SQRT_PRICE_X96 - 1);
    }

    function test_updateReferenceSqrtPrice_gas() public {
        vm.prank(poolFeeController);
        feeConfigurationImplementation.updateReferenceSqrtPriceX96(testPoolKey.toId(), REFERENCE_SQRT_PRICE_X96 - 1);
        vm.snapshotGasLastCall("updateReferenceSqrtPrice");
    }

    function test_resetHistoricalFeeData_revertsWithNotConfigManager() public {
        vm.prank(address(this));
        vm.expectRevert(abi.encodeWithSelector(IFeeConfiguration.NotConfigManager.selector, address(this)));
        feeConfigurationImplementation.resetHistoricalFeeData(testPoolKey.toId());
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
