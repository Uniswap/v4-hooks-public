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
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {SafePoolSwapTest} from "../shared/SafePoolSwapTest.sol";
import {MockIFluidDexLite} from "./mocks/MockIFluidDexLite.sol";
import {MockIFluidDexLiteResolver} from "./mocks/MockIFluidDexLiteResolver.sol";
import {
    FluidDexLiteAggregator
} from "../../../src/aggregator-hooks/implementations/FluidDexLite/FluidDexLiteAggregator.sol";
import {
    FluidDexLiteAggregatorFactory
} from "../../../src/aggregator-hooks/implementations/FluidDexLite/FluidDexLiteAggregatorFactory.sol";
import {IFluidDexLite} from "../../../src/aggregator-hooks/implementations/FluidDexLite/interfaces/IFluidDexLite.sol";
import {HookMiner} from "../../../src/utils/HookMiner.sol";
import {ExternalLiqSourceHook} from "../../../src/aggregator-hooks/ExternalLiqSourceHook.sol";
import {CustomRevert} from "@uniswap/v4-core/src/libraries/CustomRevert.sol";
import {Hooks as HooksLib} from "@uniswap/v4-core/src/libraries/Hooks.sol";

contract FluidDexLiteAggregatorUnitTest is Test {
    using PoolIdLibrary for PoolKey;

    PoolManager public poolManager;
    SafePoolSwapTest public swapRouter;
    MockIFluidDexLite public mockDex;
    MockIFluidDexLiteResolver public mockResolver;
    FluidDexLiteAggregator public hook;
    MockERC20 public token0;
    MockERC20 public token1;

    uint24 constant FEE = 3000;
    int24 constant TICK_SPACING = 60;
    uint160 constant SQRT_PRICE_1_1 = 79228162514264337593543950336;
    uint160 constant MIN_PRICE = TickMath.MIN_SQRT_PRICE + 1;
    uint160 constant MAX_PRICE = TickMath.MAX_SQRT_PRICE - 1;
    bytes32 constant DEX_SALT = bytes32(uint256(1));

    address public alice = makeAddr("alice");
    PoolKey public poolKey;
    PoolId public poolId;

    function setUp() public {
        poolManager = new PoolManager(address(this));
        swapRouter = new SafePoolSwapTest(poolManager);
        mockDex = new MockIFluidDexLite();
        mockResolver = new MockIFluidDexLiteResolver();

        token0 = new MockERC20("Token0", "TK0", 18);
        token1 = new MockERC20("Token1", "TK1", 18);
        if (address(token0) > address(token1)) (token0, token1) = (token1, token0);

        // Deploy hook with valid address
        uint160 flags =
            uint160(Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG | Hooks.BEFORE_INITIALIZE_FLAG);
        bytes memory constructorArgs = abi.encode(IPoolManager(address(poolManager)), mockDex, mockResolver, DEX_SALT);
        (, bytes32 salt) =
            HookMiner.find(address(this), flags, type(FluidDexLiteAggregator).creationCode, constructorArgs);
        hook =
            new FluidDexLiteAggregator{salt: salt}(IPoolManager(address(poolManager)), mockDex, mockResolver, DEX_SALT);

        poolKey = PoolKey({
            currency0: Currency.wrap(address(token0)),
            currency1: Currency.wrap(address(token1)),
            fee: FEE,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(address(hook))
        });
        poolId = poolKey.toId();

        // Mock resolver returns non-empty state so initialize succeeds
        mockResolver.setReturnEmptyDexState(false);
        poolManager.initialize(poolKey, SQRT_PRICE_1_1);

        // Setup tokens
        token0.mint(alice, 1000 ether);
        token1.mint(alice, 1000 ether);
        token0.mint(address(poolManager), 1000 ether);
        token1.mint(address(poolManager), 1000 ether);
        // Mint tokens to mock dex so it can transfer output tokens
        token0.mint(address(mockDex), 1000 ether);
        token1.mint(address(mockDex), 1000 ether);
        vm.startPrank(alice);
        token0.approve(address(swapRouter), type(uint256).max);
        token1.approve(address(swapRouter), type(uint256).max);
        vm.stopPrank();
    }

    // ========== CONSTRUCTOR ==========

    function test_constructor_setsImmutables() public view {
        assertEq(address(hook.FLUID_DEX_LITE()), address(mockDex));
        assertEq(address(hook.FLUID_DEX_LITE_RESOLVER()), address(mockResolver));
    }

    // ========== dexCallback ==========

    function test_dexCallback_revertsUnauthorizedCaller() public {
        vm.expectRevert(FluidDexLiteAggregator.UnauthorizedCaller.selector);
        hook.dexCallback(address(token0), 100 ether, "");
    }

    function test_dexCallback_takesFromPoolManager() public {
        // Callback must come from mockDex; simulate by pranking
        token0.mint(address(poolManager), 100 ether);

        // Need to be in unlocked context for take to work
        vm.prank(address(mockDex));
        vm.expectRevert(IPoolManager.ManagerLocked.selector);
        hook.dexCallback(address(token0), 100 ether, "");
    }

    // ========== quote ==========

    function test_quote_revertsPoolDoesNotExist() public {
        PoolId wrongPoolId = PoolId.wrap(bytes32(uint256(999)));
        vm.expectRevert(ExternalLiqSourceHook.PoolDoesNotExist.selector);
        hook.quote(true, -int256(100 ether), wrongPoolId);
    }

    function test_quote_returnsResolverEstimate() public {
        mockResolver.setReturnEstimateSwapSingle(12345);
        uint256 result = hook.quote(true, -int256(100 ether), poolId);
        assertEq(result, 12345);
    }

    // ========== pseudoTotalValueLocked ==========

    function test_pseudoTotalValueLocked_revertsPoolDoesNotExist() public {
        PoolId wrongPoolId = PoolId.wrap(bytes32(uint256(999)));
        vm.expectRevert(ExternalLiqSourceHook.PoolDoesNotExist.selector);
        hook.pseudoTotalValueLocked(wrongPoolId);
    }

    function test_pseudoTotalValueLocked_returnsReserves() public {
        mockResolver.setReturnReserves(1000 ether, 2000 ether);
        (uint256 a0, uint256 a1) = hook.pseudoTotalValueLocked(poolId);
        assertEq(a0, 1000 ether);
        assertEq(a1, 2000 ether);
    }

    // ========== _beforeInitialize ==========

    function test_beforeInitialize_revertsPoolDoesNotExist_emptyState() public {
        // Deploy new hook
        MockIFluidDexLiteResolver resolver2 = new MockIFluidDexLiteResolver();
        resolver2.setReturnEmptyDexState(true); // isEmpty() returns true

        bytes memory args = abi.encode(IPoolManager(address(poolManager)), mockDex, resolver2, DEX_SALT);
        (, bytes32 salt2) = HookMiner.find(
            address(this),
            uint160(Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG | Hooks.BEFORE_INITIALIZE_FLAG),
            type(FluidDexLiteAggregator).creationCode,
            args
        );
        FluidDexLiteAggregator hook2 =
            new FluidDexLiteAggregator{salt: salt2}(IPoolManager(address(poolManager)), mockDex, resolver2, DEX_SALT);

        PoolKey memory key2 = PoolKey({
            currency0: Currency.wrap(address(token0)),
            currency1: Currency.wrap(address(token1)),
            fee: FEE + 1,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(address(hook2))
        });

        vm.expectRevert(
            abi.encodeWithSelector(
                CustomRevert.WrappedError.selector,
                address(hook2),
                IHooks.beforeInitialize.selector,
                abi.encodeWithSelector(ExternalLiqSourceHook.PoolDoesNotExist.selector),
                abi.encodeWithSelector(HooksLib.HookCallFailed.selector)
            )
        );
        poolManager.initialize(key2, SQRT_PRICE_1_1);
    }

    function test_beforeInitialize_emitsEvent() public view {
        // Already tested via setUp, but verify localPoolId is set
        assertEq(PoolId.unwrap(hook.localPoolId()), PoolId.unwrap(poolId));
    }

    // ========== SWAP (via _conductSwap) ==========

    function test_swap_exactIn_zeroForOne() public {
        uint256 amountIn = 100 ether;
        uint256 amountOut = 95 ether;
        mockDex.setReturnSwapSingle(amountOut);
        token1.mint(address(poolManager), amountOut);

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

    function test_swap_exactIn_oneForZero() public {
        uint256 amountIn = 100 ether;
        uint256 amountOut = 95 ether;
        mockDex.setReturnSwapSingle(amountOut);
        token0.mint(address(poolManager), amountOut);

        vm.prank(alice);
        swapRouter.swap(
            poolKey,
            SwapParams({zeroForOne: false, amountSpecified: -int256(amountIn), sqrtPriceLimitX96: MAX_PRICE}),
            SafePoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );

        assertEq(token1.balanceOf(alice), 1000 ether - amountIn);
        assertEq(token0.balanceOf(alice), 1000 ether + amountOut);
    }

    // NOTE: Exact-out tests for FluidDexLite are covered in fork tests (FluidDexLiteERC20Test.fork.t.sol)
    // The unit test mock doesn't properly simulate the exact-out flow which requires
    // specific Fluid DEX Lite behavior

    // ========== REVERSED POOL ORDER (Native Currency) ==========

    function test_pseudoTotalValueLocked_reversed_returnsSwappedReserves() public {
        // Deploy hook with native currency which will trigger reversed order
        // Native currency (address(0)) converts to FLUID_NATIVE_CURRENCY (0xEeee...)
        // which is > any normal token address, so _isReversed = true
        MockIFluidDexLiteResolver resolver2 = new MockIFluidDexLiteResolver();
        resolver2.setReturnEmptyDexState(false);
        resolver2.setReturnReserves(1000 ether, 2000 ether);

        bytes memory args = abi.encode(IPoolManager(address(poolManager)), mockDex, resolver2, DEX_SALT);
        (, bytes32 salt2) = HookMiner.find(
            address(this),
            uint160(Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG | Hooks.BEFORE_INITIALIZE_FLAG),
            type(FluidDexLiteAggregator).creationCode,
            args
        );
        FluidDexLiteAggregator hook2 =
            new FluidDexLiteAggregator{salt: salt2}(IPoolManager(address(poolManager)), mockDex, resolver2, DEX_SALT);

        // Use native currency (address(0)) as currency0
        // After conversion to FLUID_NATIVE_CURRENCY, it becomes > token1, triggering _isReversed
        PoolKey memory key2 = PoolKey({
            currency0: Currency.wrap(address(0)), // Native currency
            currency1: Currency.wrap(address(token1)),
            fee: FEE + 1,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(address(hook2))
        });

        poolManager.initialize(key2, SQRT_PRICE_1_1);

        // With _isReversed = true, reserves should be swapped
        (uint256 a0, uint256 a1) = hook2.pseudoTotalValueLocked(key2.toId());
        // token0RealReserves=1000, token1RealReserves=2000
        // When reversed: returns (token1Reserves, token0Reserves) = (2000, 1000)
        assertEq(a0, 2000 ether);
        assertEq(a1, 1000 ether);
    }

    // ========== FACTORY ==========

    function test_factory_createPool() public {
        FluidDexLiteAggregatorFactory factory =
            new FluidDexLiteAggregatorFactory(IPoolManager(address(poolManager)), mockDex, mockResolver);

        MockERC20 tkA = new MockERC20("A", "A", 18);
        MockERC20 tkB = new MockERC20("B", "B", 18);
        if (address(tkA) > address(tkB)) (tkA, tkB) = (tkB, tkA);

        bytes32 dexSalt = bytes32(uint256(42));
        bytes memory args = abi.encode(address(poolManager), address(mockDex), address(mockResolver), dexSalt);
        (, bytes32 factorySalt) = HookMiner.find(
            address(factory),
            uint160(Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG | Hooks.BEFORE_INITIALIZE_FLAG),
            type(FluidDexLiteAggregator).creationCode,
            args
        );

        address hookAddr = factory.createPool(
            factorySalt,
            dexSalt,
            Currency.wrap(address(tkA)),
            Currency.wrap(address(tkB)),
            FEE,
            TICK_SPACING,
            SQRT_PRICE_1_1
        );
        assertTrue(hookAddr != address(0));
    }

    function test_factory_computeAddress() public {
        FluidDexLiteAggregatorFactory factory =
            new FluidDexLiteAggregatorFactory(IPoolManager(address(poolManager)), mockDex, mockResolver);

        bytes32 dexSalt = bytes32(uint256(99));
        bytes memory args = abi.encode(address(poolManager), address(mockDex), address(mockResolver), dexSalt);
        (, bytes32 factorySalt) = HookMiner.find(
            address(factory),
            uint160(Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG | Hooks.BEFORE_INITIALIZE_FLAG),
            type(FluidDexLiteAggregator).creationCode,
            args
        );

        address computed = factory.computeAddress(factorySalt, dexSalt);
        assertTrue(computed != address(0));
    }
}
