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
import {FeeConfig, FeeState, IFeeConfiguration} from "../../src/stable/interfaces/IFeeConfiguration.sol";

contract FeeConfigurationImplementationTest is Test {
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;

    event ConfigManagerUpdated(address indexed configManager);
    event FeeConfigUpdated(PoolId indexed poolId, FeeConfig feeConfig);

    uint256 public constant K = 16_609_443;
    uint256 public constant LOG_K = 9140;
    uint24 public constant OPTIMAL_FEE_RATE = 90; // 0.9 bps
    uint160 public constant REFERENCE_SQRT_PRICE_X96 = TickMath.MIN_SQRT_PRICE;

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
            k: K, logK: LOG_K, optimalFeeRate: OPTIMAL_FEE_RATE, referenceSqrtPriceX96: REFERENCE_SQRT_PRICE_X96
        });

        vm.prank(address(this));
        vm.expectRevert(abi.encodeWithSelector(IFeeConfiguration.NotConfigManager.selector, address(this)));
        feeConfigurationImplementation.updateFeeConfig(testPoolKey.toId(), newConfig);
    }

    function test_updateFeeConfig_succeeds() public {
        FeeConfig memory newConfig = FeeConfig({
            k: K, logK: LOG_K, optimalFeeRate: OPTIMAL_FEE_RATE, referenceSqrtPriceX96: REFERENCE_SQRT_PRICE_X96
        });

        vm.expectEmit(true, false, false, true);
        emit FeeConfigUpdated(testPoolKey.toId(), newConfig);
        vm.prank(poolFeeController);
        feeConfigurationImplementation.updateFeeConfig(testPoolKey.toId(), newConfig);

        // Verify FeeConfig was updated
        (uint256 k, uint256 logK, uint24 optimalFeeRate, uint160 referenceSqrtPriceX96) =
            feeConfigurationImplementation.feeConfig(testPoolKey.toId());
        assertEq(k, K);
        assertEq(logK, LOG_K);
        assertEq(optimalFeeRate, OPTIMAL_FEE_RATE);
        assertEq(referenceSqrtPriceX96, REFERENCE_SQRT_PRICE_X96);

        // Verify FeeState was reset
        (uint40 previousFee, uint160 previousSqrtAmmPriceX96, uint256 blockNumber) =
            feeConfigurationImplementation.feeState(testPoolKey.toId());
        assertEq(previousFee, 1e12 + 1);
        assertEq(previousSqrtAmmPriceX96, 0);
        assertEq(blockNumber, block.number);
    }

    function test_updateFeeConfig_gas() public {
        FeeConfig memory newConfig = FeeConfig({
            k: K, logK: LOG_K, optimalFeeRate: OPTIMAL_FEE_RATE, referenceSqrtPriceX96: REFERENCE_SQRT_PRICE_X96
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
