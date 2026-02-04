// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {PoolManager} from "@uniswap/v4-core/src/PoolManager.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {CustomRevert} from "@uniswap/v4-core/src/libraries/CustomRevert.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {SafePoolSwapTest} from "./shared/SafePoolSwapTest.sol";
import {MockExternalLiqSource} from "./mocks/MockExternalLiqSource.sol";
import {MockExternalLiqSourceHook} from "./mocks/MockExternalLiqSourceHook.sol";
import {HookMiner} from "../../src/utils/HookMiner.sol";
import {ExternalLiqSourceHook} from "../../src/aggregator-hooks/ExternalLiqSourceHook.sol";

contract ExternalLiqSourceHookUnitTest is Test {
    using PoolIdLibrary for PoolKey;

    PoolManager public poolManager;
    SafePoolSwapTest public swapRouter;
    MockExternalLiqSource public externalSource;
    MockExternalLiqSourceHook public hook;
    MockERC20 public token0;
    MockERC20 public token1;

    uint24 constant FEE = 3000;
    int24 constant TICK_SPACING = 60;
    uint160 constant SQRT_PRICE_1_1 = 79228162514264337593543950336;
    uint160 constant MIN_PRICE = TickMath.MIN_SQRT_PRICE + 1;
    uint160 constant MAX_PRICE = TickMath.MAX_SQRT_PRICE - 1;

    address public alice = makeAddr("alice");
    PoolKey public poolKey;
    PoolId public poolId;

    function setUp() public {
        poolManager = new PoolManager(address(this));
        swapRouter = new SafePoolSwapTest(poolManager);
        externalSource = new MockExternalLiqSource();

        token0 = new MockERC20("Token0", "TK0", 18);
        token1 = new MockERC20("Token1", "TK1", 18);
        if (address(token0) > address(token1)) (token0, token1) = (token1, token0);

        uint160 flags =
            uint160(Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG | Hooks.BEFORE_INITIALIZE_FLAG);
        bytes memory constructorArgs = abi.encode(IPoolManager(address(poolManager)), externalSource);
        (, bytes32 salt) =
            HookMiner.find(address(this), flags, type(MockExternalLiqSourceHook).creationCode, constructorArgs);
        hook = new MockExternalLiqSourceHook{salt: salt}(IPoolManager(address(poolManager)), externalSource);

        poolKey = PoolKey({
            currency0: Currency.wrap(address(token0)),
            currency1: Currency.wrap(address(token1)),
            fee: FEE,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(address(hook))
        });
        poolId = poolKey.toId();
        poolManager.initialize(poolKey, SQRT_PRICE_1_1);

        token0.mint(alice, 1000 ether);
        token1.mint(alice, 1000 ether);
        token0.mint(address(poolManager), 1000 ether);
        token1.mint(address(poolManager), 1000 ether);
        vm.startPrank(alice);
        token0.approve(address(swapRouter), type(uint256).max);
        token1.approve(address(swapRouter), type(uint256).max);
        vm.stopPrank();
    }

    function test_getHookPermissions() public view {
        Hooks.Permissions memory p = hook.getHookPermissions();
        assertTrue(p.beforeSwap);
        assertTrue(p.beforeSwapReturnDelta);
        assertTrue(p.beforeInitialize);
    }

    function test_beforeInitialize_emitsAggregatorPoolRegistered() public {
        // Already initialized in setUp; event was emitted. Verify by initializing another pool.
        MockExternalLiqSource src2 = new MockExternalLiqSource();
        bytes memory args = abi.encode(IPoolManager(address(poolManager)), src2);
        (, bytes32 salt2) = HookMiner.find(
            address(this),
            uint160(Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG | Hooks.BEFORE_INITIALIZE_FLAG),
            type(MockExternalLiqSourceHook).creationCode,
            args
        );
        MockExternalLiqSourceHook hook2 =
            new MockExternalLiqSourceHook{salt: salt2}(IPoolManager(address(poolManager)), src2);
        PoolKey memory key2 = PoolKey({
            currency0: Currency.wrap(address(token0)),
            currency1: Currency.wrap(address(token1)),
            fee: FEE + 1,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(address(hook2))
        });
        vm.expectEmit(true, true, true, true);
        emit ExternalLiqSourceHook.AggregatorPoolRegistered(key2.toId());
        poolManager.initialize(key2, SQRT_PRICE_1_1);
    }

    function test_beforeSwap_exactIn() public {
        uint256 amountIn = 100 ether;
        uint256 amountOut = 95 ether;
        externalSource.setReturns(amountOut, amountIn, false);
        token1.mint(address(hook), amountOut);

        vm.prank(alice);
        swapRouter.swap(
            poolKey,
            SwapParams({zeroForOne: true, amountSpecified: -int256(amountIn), sqrtPriceLimitX96: MIN_PRICE}),
            SafePoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );

        assertEq(token0.balanceOf(alice), 1000 ether - amountIn);
        assertEq(token1.balanceOf(alice), 1000 ether + amountOut);
    }

    function test_beforeSwap_exactOut() public {
        uint256 amountOut = 50 ether;
        uint256 amountIn = 55 ether;
        externalSource.setReturns(amountOut, amountIn, false);
        token0.mint(address(hook), amountIn);

        vm.prank(alice);
        swapRouter.swap(
            poolKey,
            SwapParams({zeroForOne: false, amountSpecified: int256(amountOut), sqrtPriceLimitX96: MAX_PRICE}),
            SafePoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );

        // oneForZero exact-out: alice pays token1 (amountIn), receives token0 (amountOut)
        assertEq(token0.balanceOf(alice), 1000 ether + amountOut);
        assertEq(token1.balanceOf(alice), 1000 ether - amountIn);
    }

    function test_InsufficientLiquidity_payerBalanceLessThanSettle() public {
        uint256 amountIn = 100 ether;
        uint256 amountOut = 95 ether;
        externalSource.setReturns(amountOut, amountIn, false);
        token1.mint(address(hook), 50 ether);

        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(
                CustomRevert.WrappedError.selector,
                address(hook),
                IHooks.beforeSwap.selector,
                abi.encodeWithSelector(ExternalLiqSourceHook.InsufficientLiquidity.selector),
                abi.encodeWithSelector(Hooks.HookCallFailed.selector)
            )
        );
        swapRouter.swap(
            poolKey,
            SwapParams({zeroForOne: true, amountSpecified: -int256(amountIn), sqrtPriceLimitX96: MIN_PRICE}),
            SafePoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
    }

    function test_receive_acceptsEth() public {
        uint256 sent = 1 ether;
        (bool ok,) = address(hook).call{value: sent}("");
        assertTrue(ok);
        assertEq(address(hook).balance, sent);
    }

    function test_quote_returnsMockValue() public {
        hook.setMockQuoteReturn(12345);
        uint256 q = hook.quote(true, -int256(100 ether), poolId);
        assertEq(q, 12345);
    }

    function test_pseudoTotalValueLocked_returnsMockValues() public {
        hook.setMockPseudoTVL(1000 ether, 2000 ether);
        (uint256 a0, uint256 a1) = hook.pseudoTotalValueLocked(poolId);
        assertEq(a0, 1000 ether);
        assertEq(a1, 2000 ether);
    }
}
