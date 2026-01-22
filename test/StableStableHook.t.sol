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

contract StableStableHookTest is Test, Deployers {
    using StateLibrary for IPoolManager;

    StableStableHook public hook;

    address owner = makeAddr("owner");

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

        deployCodeTo("StableStableHook", abi.encode(manager, owner), address(hook));
    }

    function test_initializePool_revertsWithOwnableUnauthorizedAccount() public {
        PoolKey memory poolKey = PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(address(1)),
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: TickMath.MIN_TICK_SPACING,
            hooks: IHooks(address(hook))
        });

        vm.prank(address(this));
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, address(this)));
        hook.initializePool(poolKey, TickMath.MIN_SQRT_PRICE);
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
        vm.expectRevert(abi.encodeWithSelector(StableStableHook.MustUseDynamicFee.selector, LPFeeLibrary.MAX_LP_FEE));
        hook.initializePool(poolKey, TickMath.MIN_SQRT_PRICE);
    }

    function test_initializePool_revertsWithInvalidInitializer() public {
        PoolKey memory poolKey = PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(address(1)),
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: TickMath.MIN_TICK_SPACING,
            hooks: IHooks(address(hook))
        });

        // The hook's InvalidInitializer error will be wrapped in a WrappedError by the Hooks library
        vm.expectRevert(
            abi.encodeWithSelector(
                CustomRevert.WrappedError.selector,
                address(hook), // target
                IHooks.beforeInitialize.selector, // selector
                abi.encodeWithSelector(StableStableHook.InvalidInitializer.selector, address(this)), // reason
                abi.encodeWithSelector(Hooks.HookCallFailed.selector) // details
            )
        );

        vm.prank(address(this));
        manager.initialize(poolKey, TickMath.MIN_SQRT_PRICE); // not called by the hook
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
        vm.expectRevert(abi.encodeWithSelector(StableStableHook.InvalidHookAddress.selector, address(0)));
        hook.initializePool(poolKey, TickMath.MIN_SQRT_PRICE);
    }

    function test_initializePool_succeeds() public {
        PoolKey memory poolKey = PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(address(1)),
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: TickMath.MIN_TICK_SPACING,
            hooks: IHooks(address(hook))
        });
        vm.prank(owner);
        hook.initializePool(poolKey, TickMath.MIN_SQRT_PRICE);

        (uint160 slot0SqrtPriceX96, int24 slot0Tick, uint24 slot0ProtocolFee,) = manager.getSlot0(poolKey.toId());
        assertEq(slot0SqrtPriceX96, TickMath.MIN_SQRT_PRICE);
        assertEq(slot0ProtocolFee, 0);
        assertEq(slot0Tick, TickMath.getTickAtSqrtPrice(TickMath.MIN_SQRT_PRICE));
    }
}
