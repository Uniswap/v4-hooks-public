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
import {MockCurveStableSwap} from "./mocks/MockCurveStableSwap.sol";
import {StableSwapAggregator} from "../../../src/aggregator-hooks/implementations/StableSwap/StableSwapAggregator.sol";
import {
    StableSwapAggregatorFactory
} from "../../../src/aggregator-hooks/implementations/StableSwap/StableSwapAggregatorFactory.sol";
import {HookMiner} from "../../../src/utils/HookMiner.sol";
import {CustomRevert} from "@uniswap/v4-core/src/libraries/CustomRevert.sol";
import {Hooks as HooksLib} from "@uniswap/v4-core/src/libraries/Hooks.sol";

contract StableSwapAggregatorUnitTest is Test {
    using PoolIdLibrary for PoolKey;

    PoolManager public poolManager;
    SafePoolSwapTest public swapRouter;
    MockCurveStableSwap public mockPool;
    StableSwapAggregator public hook;
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

        token0 = new MockERC20("Token0", "TK0", 18);
        token1 = new MockERC20("Token1", "TK1", 18);
        if (address(token0) > address(token1)) (token0, token1) = (token1, token0);

        // Create mock pool with tokens
        address[] memory coins = new address[](2);
        coins[0] = address(token0);
        coins[1] = address(token1);
        mockPool = new MockCurveStableSwap(coins);

        // Deploy hook with valid address
        uint160 flags =
            uint160(Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG | Hooks.BEFORE_INITIALIZE_FLAG);
        bytes memory constructorArgs = abi.encode(IPoolManager(address(poolManager)), mockPool);
        (, bytes32 salt) =
            HookMiner.find(address(this), flags, type(StableSwapAggregator).creationCode, constructorArgs);
        hook = new StableSwapAggregator{salt: salt}(IPoolManager(address(poolManager)), mockPool);

        poolKey = PoolKey({
            currency0: Currency.wrap(address(token0)),
            currency1: Currency.wrap(address(token1)),
            fee: FEE,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(address(hook))
        });
        poolId = poolKey.toId();

        poolManager.initialize(poolKey, SQRT_PRICE_1_1);

        // Setup tokens
        token0.mint(alice, 1000 ether);
        token1.mint(alice, 1000 ether);
        token0.mint(address(poolManager), 1000 ether);
        token1.mint(address(poolManager), 1000 ether);
        token0.mint(address(hook), 1000 ether);
        token1.mint(address(hook), 1000 ether);

        // Mint tokens to mock pool so it can transfer output tokens
        token0.mint(address(mockPool), 1000 ether);
        token1.mint(address(mockPool), 1000 ether);
        vm.startPrank(alice);
        token0.approve(address(swapRouter), type(uint256).max);
        token1.approve(address(swapRouter), type(uint256).max);
        vm.stopPrank();
    }

    // ========== CONSTRUCTOR ==========

    function test_constructor_setsPool() public view {
        assertEq(address(hook.pool()), address(mockPool));
    }

    // ========== quote ==========

    function test_quote_revertsExactOutputNotSupported() public {
        vm.expectRevert(StableSwapAggregator.ExactOutputNotSupported.selector);
        hook.quote(true, int256(100 ether), poolId);
    }

    function test_quote_exactIn_zeroToOne() public {
        mockPool.setReturnGetDy(12345);
        uint256 result = hook.quote(true, -int256(100 ether), poolId);
        assertEq(result, 12345);
    }

    function test_quote_exactIn_oneToZero() public {
        mockPool.setReturnGetDy(54321);
        uint256 result = hook.quote(false, -int256(100 ether), poolId);
        assertEq(result, 54321);
    }

    // ========== pseudoTotalValueLocked ==========

    function test_pseudoTotalValueLocked_returnsBalances() public {
        mockPool.setBalance(0, 1000 ether);
        mockPool.setBalance(1, 2000 ether);
        (uint256 a0, uint256 a1) = hook.pseudoTotalValueLocked(poolId);
        assertEq(a0, 1000 ether);
        assertEq(a1, 2000 ether);
    }

    // ========== _beforeInitialize ==========

    function test_beforeInitialize_revertsTokensNotInPool() public {
        // Create mock pool without our tokens
        address[] memory wrongCoins = new address[](2);
        wrongCoins[0] = address(0xdead);
        wrongCoins[1] = address(0xbeef);
        MockCurveStableSwap wrongPool = new MockCurveStableSwap(wrongCoins);

        bytes memory args = abi.encode(IPoolManager(address(poolManager)), wrongPool);
        (, bytes32 salt2) = HookMiner.find(
            address(this),
            uint160(Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG | Hooks.BEFORE_INITIALIZE_FLAG),
            type(StableSwapAggregator).creationCode,
            args
        );
        StableSwapAggregator hook2 =
            new StableSwapAggregator{salt: salt2}(IPoolManager(address(poolManager)), wrongPool);

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
                abi.encodeWithSelector(
                    StableSwapAggregator.TokensNotInPool.selector,
                    Currency.unwrap(key2.currency0),
                    Currency.unwrap(key2.currency1)
                ),
                abi.encodeWithSelector(HooksLib.HookCallFailed.selector)
            )
        );
        poolManager.initialize(key2, SQRT_PRICE_1_1);
    }

    function test_beforeInitialize_revertsToken0NotInPool() public {
        // Create mock pool with only token1 (token0 is missing)
        address[] memory partialCoins = new address[](2);
        partialCoins[0] = address(0xdead); // wrong token0
        partialCoins[1] = address(token1); // correct token1
        MockCurveStableSwap partialPool = new MockCurveStableSwap(partialCoins);

        bytes memory args = abi.encode(IPoolManager(address(poolManager)), partialPool);
        (, bytes32 salt2) = HookMiner.find(
            address(this),
            uint160(Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG | Hooks.BEFORE_INITIALIZE_FLAG),
            type(StableSwapAggregator).creationCode,
            args
        );
        StableSwapAggregator hook2 =
            new StableSwapAggregator{salt: salt2}(IPoolManager(address(poolManager)), partialPool);

        PoolKey memory key2 = PoolKey({
            currency0: Currency.wrap(address(token0)),
            currency1: Currency.wrap(address(token1)),
            fee: FEE + 2,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(address(hook2))
        });

        vm.expectRevert(
            abi.encodeWithSelector(
                CustomRevert.WrappedError.selector,
                address(hook2),
                IHooks.beforeInitialize.selector,
                abi.encodeWithSelector(StableSwapAggregator.TokenNotInPool.selector, address(token0)),
                abi.encodeWithSelector(HooksLib.HookCallFailed.selector)
            )
        );
        poolManager.initialize(key2, SQRT_PRICE_1_1);
    }

    function test_beforeInitialize_revertsToken1NotInPool() public {
        // Create mock pool with only token0 (token1 is missing)
        address[] memory partialCoins = new address[](2);
        partialCoins[0] = address(token0); // correct token0
        partialCoins[1] = address(0xbeef); // wrong token1
        MockCurveStableSwap partialPool = new MockCurveStableSwap(partialCoins);

        bytes memory args = abi.encode(IPoolManager(address(poolManager)), partialPool);
        (, bytes32 salt2) = HookMiner.find(
            address(this),
            uint160(Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG | Hooks.BEFORE_INITIALIZE_FLAG),
            type(StableSwapAggregator).creationCode,
            args
        );
        StableSwapAggregator hook2 =
            new StableSwapAggregator{salt: salt2}(IPoolManager(address(poolManager)), partialPool);

        PoolKey memory key2 = PoolKey({
            currency0: Currency.wrap(address(token0)),
            currency1: Currency.wrap(address(token1)),
            fee: FEE + 3,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(address(hook2))
        });

        vm.expectRevert(
            abi.encodeWithSelector(
                CustomRevert.WrappedError.selector,
                address(hook2),
                IHooks.beforeInitialize.selector,
                abi.encodeWithSelector(StableSwapAggregator.TokenNotInPool.selector, address(token1)),
                abi.encodeWithSelector(HooksLib.HookCallFailed.selector)
            )
        );
        poolManager.initialize(key2, SQRT_PRICE_1_1);
    }

    function test_beforeInitialize_setsTokenIndices() public view {
        (int128 idx0, int128 idx1) = hook.poolIdToTokenInfo(poolId);
        assertEq(idx0, 0);
        assertEq(idx1, 1);
    }

    // ========== SWAP (via _conductSwap) ==========

    function test_swap_exactIn_zeroForOne() public {
        uint256 amountIn = 100 ether;
        uint256 amountOut = 95 ether;
        mockPool.setReturnExchange(amountOut);
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

    function test_swap_exactIn_oneForZero() public {
        uint256 amountIn = 100 ether;
        uint256 amountOut = 95 ether;
        mockPool.setReturnExchange(amountOut);
        token0.mint(address(hook), amountOut);

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

    function test_swap_exactOut_reverts() public {
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(
                CustomRevert.WrappedError.selector,
                address(hook),
                IHooks.beforeSwap.selector,
                abi.encodeWithSelector(StableSwapAggregator.ExactOutputNotSupported.selector),
                abi.encodeWithSelector(HooksLib.HookCallFailed.selector)
            )
        );
        swapRouter.swap(
            poolKey,
            SwapParams({zeroForOne: true, amountSpecified: int256(50 ether), sqrtPriceLimitX96: MIN_PRICE}),
            SafePoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
    }

    // ========== FACTORY ==========

    function test_factory_createPool() public {
        StableSwapAggregatorFactory factory = new StableSwapAggregatorFactory(IPoolManager(address(poolManager)));

        MockERC20 tkA = new MockERC20("A", "A", 18);
        MockERC20 tkB = new MockERC20("B", "B", 18);
        if (address(tkA) > address(tkB)) (tkA, tkB) = (tkB, tkA);

        address[] memory coins2 = new address[](2);
        coins2[0] = address(tkA);
        coins2[1] = address(tkB);
        MockCurveStableSwap pool2 = new MockCurveStableSwap(coins2);

        Currency[] memory tokens = new Currency[](2);
        tokens[0] = Currency.wrap(address(tkA));
        tokens[1] = Currency.wrap(address(tkB));

        bytes memory args = abi.encode(address(poolManager), address(pool2));
        (, bytes32 factorySalt) = HookMiner.find(
            address(factory),
            uint160(Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG | Hooks.BEFORE_INITIALIZE_FLAG),
            type(StableSwapAggregator).creationCode,
            args
        );

        address hookAddr = factory.createPool(factorySalt, pool2, tokens, FEE, TICK_SPACING, SQRT_PRICE_1_1);
        assertTrue(hookAddr != address(0));
    }

    function test_factory_computeAddress() public {
        StableSwapAggregatorFactory factory = new StableSwapAggregatorFactory(IPoolManager(address(poolManager)));

        bytes memory args = abi.encode(address(poolManager), address(mockPool));
        (, bytes32 factorySalt) = HookMiner.find(
            address(factory),
            uint160(Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG | Hooks.BEFORE_INITIALIZE_FLAG),
            type(StableSwapAggregator).creationCode,
            args
        );

        address computed = factory.computeAddress(factorySalt, mockPool);
        assertTrue(computed != address(0));
    }

    function test_factory_revertsInsufficientTokens() public {
        StableSwapAggregatorFactory factory = new StableSwapAggregatorFactory(IPoolManager(address(poolManager)));

        Currency[] memory tokens = new Currency[](1);
        tokens[0] = Currency.wrap(address(token0));

        vm.expectRevert(StableSwapAggregatorFactory.InsufficientTokens.selector);
        factory.createPool(bytes32(0), mockPool, tokens, FEE, TICK_SPACING, SQRT_PRICE_1_1);
    }
}
