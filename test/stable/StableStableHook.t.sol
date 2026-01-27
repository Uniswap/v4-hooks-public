// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
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
import {IStableStableHook} from "../../src/stable/interfaces/IStableStableHook.sol";
import {FeeConfig, IFeeConfiguration} from "../../src/stable/interfaces/IFeeConfiguration.sol";

contract StableStableHookTest is Test, Deployers {
    using StateLibrary for IPoolManager;

    event PoolInitialized(PoolKey indexed poolKey, uint160 sqrtPriceX96, FeeConfig feeConfig);

    uint256 public constant DECAY_FACTOR = 9140;
    uint24 public constant OPTIMAL_FEE_SPREAD = 90; // 0.9 bps
    uint160 public constant REFERENCE_SQRT_PRICE_X96 = TickMath.MIN_SQRT_PRICE;

    StableStableHook public hook;

    address owner = makeAddr("owner");
    address configManager = makeAddr("configManager");

    FeeConfig public feeConfig = FeeConfig({
        decayFactor: DECAY_FACTOR,
        optimalFeeRate: OPTIMAL_FEE_SPREAD, // 0.9 bps
        referenceSqrtPriceX96: REFERENCE_SQRT_PRICE_X96
    });

    PoolKey public testPoolKey;

    function setUp() public {
        deployFreshManagerAndRouters();
        hook = StableStableHook(
            address(
                uint160(
                    uint256(type(uint160).max) & clearAllHookPermissionsMask | Hooks.BEFORE_INITIALIZE_FLAG
                        | Hooks.BEFORE_SWAP_FLAG
                )
            )
        );

        deployCodeTo("StableStableHook", abi.encode(manager, owner, configManager), address(hook));

        testPoolKey = PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(address(1)),
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: TickMath.MIN_TICK_SPACING,
            hooks: IHooks(address(hook))
        });
    }

    function test_getHookPermissions_succeeds() public view {
        Hooks.Permissions memory permissions = hook.getHookPermissions();
        assertEq(permissions.beforeInitialize, true);
        assertEq(permissions.afterInitialize, false);
        assertEq(permissions.beforeAddLiquidity, false);
        assertEq(permissions.afterAddLiquidity, false);
        assertEq(permissions.beforeRemoveLiquidity, false);
        assertEq(permissions.afterRemoveLiquidity, false);
        assertEq(permissions.beforeSwap, true);
        assertEq(permissions.afterSwap, false);
        assertEq(permissions.beforeDonate, false);
        assertEq(permissions.afterDonate, false);
        assertEq(permissions.beforeSwapReturnDelta, false);
        assertEq(permissions.afterSwapReturnDelta, false);
        assertEq(permissions.afterAddLiquidityReturnDelta, false);
        assertEq(permissions.afterRemoveLiquidityReturnDelta, false);
    }

    function test_initializePool_revertsWithOwnableUnauthorizedAccount() public {
        vm.prank(address(this));
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, address(this)));
        hook.initializePool(testPoolKey, TickMath.MIN_SQRT_PRICE, feeConfig);
    }

    function test_initializePool_revertsWithMustUseDynamicFee() public {
        PoolKey memory poolKey = PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(address(1)),
            fee: LPFeeLibrary.MAX_LP_FEE, // static fee
            tickSpacing: TickMath.MIN_TICK_SPACING,
            hooks: IHooks(address(hook))
        });
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(IStableStableHook.MustUseDynamicFee.selector, LPFeeLibrary.MAX_LP_FEE));
        hook.initializePool(poolKey, TickMath.MIN_SQRT_PRICE, feeConfig);
    }

    function test_initializePool_revertsWithInvalidInitializer() public {
        // The hook's InvalidInitializer error will be wrapped in a WrappedError by the Hooks library
        vm.expectRevert(
            abi.encodeWithSelector(
                CustomRevert.WrappedError.selector,
                address(hook), // target
                IHooks.beforeInitialize.selector, // selector
                abi.encodeWithSelector(IStableStableHook.InvalidInitializer.selector, address(this)), // reason
                abi.encodeWithSelector(Hooks.HookCallFailed.selector) // details
            )
        );

        vm.prank(address(this));
        manager.initialize(testPoolKey, TickMath.MIN_SQRT_PRICE); // not called by the hook
    }

    function test_initializePool_revertsWithInvalidHookAddress() public {
        PoolKey memory poolKey = PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(address(1)),
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: TickMath.MIN_TICK_SPACING,
            hooks: IHooks(address(0)) // invalid hook address
        });
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(IStableStableHook.InvalidHookAddress.selector, address(0)));
        hook.initializePool(poolKey, TickMath.MIN_SQRT_PRICE, feeConfig);
    }

    function test_initializePool_succeeds() public {
        vm.expectEmit(true, false, false, true);
        emit PoolInitialized(testPoolKey, TickMath.MIN_SQRT_PRICE, feeConfig);
        vm.prank(owner);
        hook.initializePool(testPoolKey, TickMath.MIN_SQRT_PRICE, feeConfig);

        (uint160 slot0SqrtPriceX96, int24 slot0Tick, uint24 slot0ProtocolFee,) = manager.getSlot0(testPoolKey.toId());
        assertEq(slot0SqrtPriceX96, TickMath.MIN_SQRT_PRICE);
        assertEq(slot0ProtocolFee, 0);
        assertEq(slot0Tick, TickMath.getTickAtSqrtPrice(TickMath.MIN_SQRT_PRICE));
        (uint256 decayFactor, uint256 optimalFeeRate, uint160 referenceSqrtPriceX96) =
            hook.feeConfig(testPoolKey.toId());
        assertEq(decayFactor, DECAY_FACTOR);
        assertEq(optimalFeeRate, OPTIMAL_FEE_SPREAD);
        assertEq(referenceSqrtPriceX96, REFERENCE_SQRT_PRICE_X96);
        (uint40 previousFee, uint160 previousSqrtAmmPrice, uint256 blockNumber) =
            hook.historicalFeeData(testPoolKey.toId());
        assertEq(previousFee, 1e12 + 1); // UNDEFINED_FLEXIBLE_FEE
        assertEq(previousSqrtAmmPrice, 0);
        assertEq(blockNumber, block.number);
    }

    function test_initializePool_gas() public {
        vm.prank(owner);
        hook.initializePool(testPoolKey, TickMath.MIN_SQRT_PRICE, feeConfig);
        vm.snapshotGasLastCall("initializePool");
    }

    function test_multicall_revertsWithNotFeeController() public {
        vm.prank(owner);
        hook.initializePool(testPoolKey, TickMath.MIN_SQRT_PRICE, feeConfig);

        (uint256 decayFactor, uint256 optimalFeeRate, uint160 referenceSqrtPriceX96) =
            hook.feeConfig(testPoolKey.toId());
        assertEq(decayFactor, DECAY_FACTOR);
        assertEq(optimalFeeRate, OPTIMAL_FEE_SPREAD);
        assertEq(referenceSqrtPriceX96, REFERENCE_SQRT_PRICE_X96);

        bytes[] memory calls = new bytes[](4);
        calls[0] =
            abi.encodeWithSelector(IFeeConfiguration.updateDecayFactor.selector, testPoolKey.toId(), DECAY_FACTOR - 1);
        calls[1] = abi.encodeWithSelector(
            IFeeConfiguration.updateOptimalFeeRate.selector, testPoolKey.toId(), OPTIMAL_FEE_SPREAD - 1
        );
        calls[2] = abi.encodeWithSelector(
            IFeeConfiguration.updateReferenceSqrtPriceX96.selector, testPoolKey.toId(), REFERENCE_SQRT_PRICE_X96 - 1
        );
        calls[3] = abi.encodeWithSelector(IFeeConfiguration.resetHistoricalFeeData.selector, testPoolKey.toId());

        vm.prank(address(this)); // not the fee controller
        vm.expectRevert(abi.encodeWithSelector(IFeeConfiguration.NotConfigManager.selector, address(this)));
        hook.multicall(calls);

        // check that the fee configuration is not updated
        (decayFactor,,) = hook.feeConfig(testPoolKey.toId());
        assertEq(decayFactor, DECAY_FACTOR);
        (, optimalFeeRate,) = hook.feeConfig(testPoolKey.toId());
        assertEq(optimalFeeRate, OPTIMAL_FEE_SPREAD);
        (,, referenceSqrtPriceX96) = hook.feeConfig(testPoolKey.toId());
        assertEq(referenceSqrtPriceX96, REFERENCE_SQRT_PRICE_X96);
    }

    function test_multicall_succeeds() public {
        vm.prank(owner);
        hook.initializePool(testPoolKey, TickMath.MIN_SQRT_PRICE, feeConfig);

        (uint256 decayFactor, uint256 optimalFeeRate, uint160 referenceSqrtPriceX96) =
            hook.feeConfig(testPoolKey.toId());
        assertEq(decayFactor, DECAY_FACTOR);
        assertEq(optimalFeeRate, OPTIMAL_FEE_SPREAD);
        assertEq(referenceSqrtPriceX96, REFERENCE_SQRT_PRICE_X96);

        bytes[] memory calls = new bytes[](4);
        calls[0] =
            abi.encodeWithSelector(IFeeConfiguration.updateDecayFactor.selector, testPoolKey.toId(), DECAY_FACTOR - 1);
        calls[1] = abi.encodeWithSelector(
            IFeeConfiguration.updateOptimalFeeRate.selector, testPoolKey.toId(), OPTIMAL_FEE_SPREAD - 1
        );
        calls[2] = abi.encodeWithSelector(
            IFeeConfiguration.updateReferenceSqrtPriceX96.selector, testPoolKey.toId(), REFERENCE_SQRT_PRICE_X96 - 1
        );
        calls[3] = abi.encodeWithSelector(IFeeConfiguration.resetHistoricalFeeData.selector, testPoolKey.toId());

        vm.prank(configManager);
        hook.multicall(calls);

        (decayFactor,,) = hook.feeConfig(testPoolKey.toId());
        assertEq(decayFactor, DECAY_FACTOR - 1);
        (, optimalFeeRate,) = hook.feeConfig(testPoolKey.toId());
        assertEq(optimalFeeRate, OPTIMAL_FEE_SPREAD - 1);
        (,, referenceSqrtPriceX96) = hook.feeConfig(testPoolKey.toId());
        assertEq(referenceSqrtPriceX96, REFERENCE_SQRT_PRICE_X96 - 1);
    }

    function test_multicall_gas() public {
        vm.prank(owner);
        hook.initializePool(testPoolKey, TickMath.MIN_SQRT_PRICE, feeConfig);

        bytes[] memory calls = new bytes[](4);
        calls[0] =
            abi.encodeWithSelector(IFeeConfiguration.updateDecayFactor.selector, testPoolKey.toId(), DECAY_FACTOR - 1);
        calls[1] = abi.encodeWithSelector(
            IFeeConfiguration.updateOptimalFeeRate.selector, testPoolKey.toId(), OPTIMAL_FEE_SPREAD - 1
        );
        calls[2] = abi.encodeWithSelector(
            IFeeConfiguration.updateReferenceSqrtPriceX96.selector, testPoolKey.toId(), REFERENCE_SQRT_PRICE_X96 - 1
        );
        calls[3] = abi.encodeWithSelector(IFeeConfiguration.resetHistoricalFeeData.selector, testPoolKey.toId());

        vm.prank(configManager);
        hook.multicall(calls);
        vm.snapshotGasLastCall("multicall");
    }
}
