// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {StableStableHook} from "../src/StableStableHook.sol";
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
import {IStableStableHook} from "../src/interfaces/IStableStableHook.sol";
import {FeeConfig} from "../src/types/FeeConfig.sol";
import {HistoricalFeeData} from "../src/types/HistoricalFeeData.sol";

contract StableStableHookTest is Test, Deployers {
    using StateLibrary for IPoolManager;

    event PoolInitialized(PoolKey indexed poolKey, uint160 sqrtPriceX96, FeeConfig feeConfig);
    event DecayFactorUpdated(PoolKey indexed poolKey, uint256 decayFactor);
    event OptimalFeeRateUpdated(PoolKey indexed poolKey, uint256 optimalFeeRate);
    event ReferenceSqrtPriceUpdated(PoolKey indexed poolKey, uint160 referenceSqrtPrice);

    StableStableHook public hook;

    address owner = makeAddr("owner");
    address poolFeeController = makeAddr("poolFeeController");

    uint256 public constant DECAY_FACTOR = 9140;
    uint256 public constant OPTIMAL_FEE_SPREAD = 90; // 0.9 bps
    uint160 public constant REFERENCE_SQRT_PRICE = TickMath.MIN_SQRT_PRICE;

    FeeConfig public feeConfig = FeeConfig({
        decayFactor: DECAY_FACTOR,
        optimalFeeRate: OPTIMAL_FEE_SPREAD, // 0.9 bps
        referenceSqrtPrice: REFERENCE_SQRT_PRICE
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

        deployCodeTo("StableStableHook", abi.encode(manager, owner, poolFeeController), address(hook));

        testPoolKey = PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(address(1)),
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: TickMath.MIN_TICK_SPACING,
            hooks: IHooks(address(hook))
        });
    }

    function test_getHookPermissions_succeeds() public {
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
        (uint256 decayFactor, uint256 optimalFeeRate, uint160 referenceSqrtPrice) = hook.feeConfig(testPoolKey.toId());
        assertEq(decayFactor, DECAY_FACTOR);
        assertEq(optimalFeeRate, OPTIMAL_FEE_SPREAD);
        assertEq(referenceSqrtPrice, REFERENCE_SQRT_PRICE);
        (uint24 previousFee, uint160 previousSqrtAmmPrice, uint256 blockNumber) =
            hook.historicalFeeData(testPoolKey.toId());
        assertEq(previousFee, 0);
        assertEq(previousSqrtAmmPrice, 0);
        assertEq(blockNumber, 0);
    }

    function test_updateDecayFactor_revertsWithNotFeeController() public {
        vm.prank(address(this));
        vm.expectRevert(abi.encodeWithSelector(IStableStableHook.NotFeeController.selector, address(this)));
        hook.updateDecayFactor(testPoolKey, DECAY_FACTOR - 1);
    }

    function test_updateDecayFactor_succeeds() public {
        vm.expectEmit(true, false, false, true);
        emit DecayFactorUpdated(testPoolKey, DECAY_FACTOR - 1);
        vm.prank(poolFeeController);
        hook.updateDecayFactor(testPoolKey, DECAY_FACTOR - 1);
        (uint256 decayFactor,,) = hook.feeConfig(testPoolKey.toId());
        assertEq(decayFactor, DECAY_FACTOR - 1);
    }

    function test_updateOptimalFeeRate_revertsWithNotFeeController() public {
        vm.prank(address(this));
        vm.expectRevert(abi.encodeWithSelector(IStableStableHook.NotFeeController.selector, address(this)));
        hook.updateOptimalFeeRate(testPoolKey, OPTIMAL_FEE_SPREAD - 1);
    }

    function test_updateOptimalFeeRate_succeeds() public {
        vm.expectEmit(true, false, false, true);
        emit OptimalFeeRateUpdated(testPoolKey, OPTIMAL_FEE_SPREAD - 1);
        vm.prank(poolFeeController);
        hook.updateOptimalFeeRate(testPoolKey, OPTIMAL_FEE_SPREAD - 1);
        (, uint256 optimalFeeRate,) = hook.feeConfig(testPoolKey.toId());
        assertEq(optimalFeeRate, OPTIMAL_FEE_SPREAD - 1);
    }

    function test_updateReferenceSqrtPrice_revertsWithNotFeeController() public {
        vm.prank(address(this));
        vm.expectRevert(abi.encodeWithSelector(IStableStableHook.NotFeeController.selector, address(this)));
        hook.updateReferenceSqrtPrice(testPoolKey, REFERENCE_SQRT_PRICE - 1);
    }

    function test_updateReferenceSqrtPrice_succeeds() public {
        vm.expectEmit(true, false, false, true);
        emit ReferenceSqrtPriceUpdated(testPoolKey, REFERENCE_SQRT_PRICE - 1);
        vm.prank(poolFeeController);
        hook.updateReferenceSqrtPrice(testPoolKey, REFERENCE_SQRT_PRICE - 1);
        (,, uint160 referenceSqrtPrice) = hook.feeConfig(testPoolKey.toId());
        assertEq(referenceSqrtPrice, REFERENCE_SQRT_PRICE - 1);
    }

    function test_clearHistoricalFeeData_revertsWithNotFeeController() public {
        vm.prank(address(this));
        vm.expectRevert(abi.encodeWithSelector(IStableStableHook.NotFeeController.selector, address(this)));
        hook.clearHistoricalFeeData(testPoolKey);
    }

    // TODO: add test later assuring clearHistoricalFeeData works as expected

    function test_multicall_revertsWithNotFeeController() public {
        vm.prank(owner);
        hook.initializePool(testPoolKey, TickMath.MIN_SQRT_PRICE, feeConfig);

        (uint256 decayFactor, uint256 optimalFeeRate, uint160 referenceSqrtPrice) = hook.feeConfig(testPoolKey.toId());
        assertEq(decayFactor, DECAY_FACTOR);
        assertEq(optimalFeeRate, OPTIMAL_FEE_SPREAD);
        assertEq(referenceSqrtPrice, REFERENCE_SQRT_PRICE);

        bytes[] memory calls = new bytes[](4);
        calls[0] = abi.encodeWithSelector(IStableStableHook.updateDecayFactor.selector, testPoolKey, DECAY_FACTOR - 1);
        calls[1] = abi.encodeWithSelector(
            IStableStableHook.updateOptimalFeeRate.selector, testPoolKey, OPTIMAL_FEE_SPREAD - 1
        );
        calls[2] = abi.encodeWithSelector(
            IStableStableHook.updateReferenceSqrtPrice.selector, testPoolKey, REFERENCE_SQRT_PRICE - 1
        );
        calls[3] = abi.encodeWithSelector(IStableStableHook.clearHistoricalFeeData.selector, testPoolKey);

        vm.prank(address(this)); // not the fee controller
        vm.expectRevert(abi.encodeWithSelector(IStableStableHook.NotFeeController.selector, address(this)));
        hook.multicall(calls);

        // check that the fee configuration is not updated
        (decayFactor,,) = hook.feeConfig(testPoolKey.toId());
        assertEq(decayFactor, DECAY_FACTOR);
        (, optimalFeeRate,) = hook.feeConfig(testPoolKey.toId());
        assertEq(optimalFeeRate, OPTIMAL_FEE_SPREAD);
        (,, referenceSqrtPrice) = hook.feeConfig(testPoolKey.toId());
        assertEq(referenceSqrtPrice, REFERENCE_SQRT_PRICE);
    }

    function test_multicall_succeeds() public {
        vm.prank(owner);
        hook.initializePool(testPoolKey, TickMath.MIN_SQRT_PRICE, feeConfig);

        (uint256 decayFactor, uint256 optimalFeeRate, uint160 referenceSqrtPrice) = hook.feeConfig(testPoolKey.toId());
        assertEq(decayFactor, DECAY_FACTOR);
        assertEq(optimalFeeRate, OPTIMAL_FEE_SPREAD);
        assertEq(referenceSqrtPrice, REFERENCE_SQRT_PRICE);

        bytes[] memory calls = new bytes[](4);
        calls[0] = abi.encodeWithSelector(IStableStableHook.updateDecayFactor.selector, testPoolKey, DECAY_FACTOR - 1);
        calls[1] = abi.encodeWithSelector(
            IStableStableHook.updateOptimalFeeRate.selector, testPoolKey, OPTIMAL_FEE_SPREAD - 1
        );
        calls[2] = abi.encodeWithSelector(
            IStableStableHook.updateReferenceSqrtPrice.selector, testPoolKey, REFERENCE_SQRT_PRICE - 1
        );
        calls[3] = abi.encodeWithSelector(IStableStableHook.clearHistoricalFeeData.selector, testPoolKey);

        vm.prank(poolFeeController);
        hook.multicall(calls);

        (decayFactor,,) = hook.feeConfig(testPoolKey.toId());
        assertEq(decayFactor, DECAY_FACTOR - 1);
        (, optimalFeeRate,) = hook.feeConfig(testPoolKey.toId());
        assertEq(optimalFeeRate, OPTIMAL_FEE_SPREAD - 1);
        (,, referenceSqrtPrice) = hook.feeConfig(testPoolKey.toId());
        assertEq(referenceSqrtPrice, REFERENCE_SQRT_PRICE - 1);
    }
}
