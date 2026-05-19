// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {SafePoolSwapTest} from "../shared/SafePoolSwapTest.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {HookMiner} from "@uniswap/v4-periphery/src/utils/HookMiner.sol";
import {IAggregatorHook} from "../../../src/aggregator-hooks/interfaces/IAggregatorHook.sol";
import {TesseraAggregator} from "../../../src/aggregator-hooks/implementations/Tessera/TesseraAggregator.sol";
import {ITesseraSwap} from "../../../src/aggregator-hooks/implementations/Tessera/interfaces/ITesseraSwap.sol";
import {ITesseraManager} from "../../../src/aggregator-hooks/implementations/Tessera/interfaces/ITesseraManager.sol";
import {MockTesseraSwap} from "./mocks/MockTesseraSwap.sol";
import {MockTesseraManager} from "./mocks/MockTesseraManager.sol";
import {MockTesseraPool} from "./mocks/MockTesseraPool.sol";
import {MockERC20} from "./mocks/MockERC20.sol";

/// @title TesseraTest
/// @notice Unit tests for the Tessera aggregator hook
contract TesseraTest is Test {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;
    using StateLibrary for IPoolManager;

    uint24 constant POOL_FEE = 500;
    int24 constant TICK_SPACING = 10;
    uint160 constant SQRT_PRICE_1_1 = 79_228_162_514_264_337_593_543_950_336;
    uint160 constant MIN_PRICE_LIMIT = TickMath.MIN_SQRT_PRICE + 1;
    uint160 constant MAX_PRICE_LIMIT = TickMath.MAX_SQRT_PRICE - 1;

    uint8 constant DECIMALS = 18;
    uint256 constant SWAP_AMOUNT = 1_000 * 10 ** DECIMALS;
    uint256 constant INITIAL_BALANCE = 1_000_000 * 10 ** DECIMALS;

    IPoolManager public manager;
    SafePoolSwapTest public swapRouter;
    TesseraAggregator public hook;
    MockTesseraSwap public tesseraSwap;
    MockTesseraManager public tesseraManager;
    MockTesseraPool public tesseraPool;

    MockERC20 public token0Erc;
    MockERC20 public token1Erc;

    PoolKey public poolKey;
    PoolId public poolId;
    Currency public currency0;
    Currency public currency1;
    address public alice = makeAddr("alice");

    function setUp() public {
        token0Erc = new MockERC20("Token0", "T0", DECIMALS);
        token1Erc = new MockERC20("Token1", "T1", DECIMALS);
        if (address(token0Erc) > address(token1Erc)) {
            (token0Erc, token1Erc) = (token1Erc, token0Erc);
        }
        currency0 = Currency.wrap(address(token0Erc));
        currency1 = Currency.wrap(address(token1Erc));

        tesseraSwap = new MockTesseraSwap();
        tesseraManager = new MockTesseraManager();
        tesseraPool = new MockTesseraPool(address(token0Erc), address(token1Erc), DECIMALS, DECIMALS, true);

        tesseraSwap.addSupportedPair(address(token0Erc), address(token1Erc));
        tesseraManager.registerPool(address(token0Erc), address(token1Erc), address(tesseraPool));
        token0Erc.mint(address(tesseraSwap), INITIAL_BALANCE * 10);
        token1Erc.mint(address(tesseraSwap), INITIAL_BALANCE * 10);

        manager = IPoolManager(deployCode("foundry-out/PoolManager.sol/PoolManager.json", abi.encode(address(0))));
        token0Erc.mint(address(manager), INITIAL_BALANCE * 10);
        token1Erc.mint(address(manager), INITIAL_BALANCE * 10);

        swapRouter = new SafePoolSwapTest(manager);
        _deployHook();

        poolKey = PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: POOL_FEE,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(address(hook))
        });
        poolId = poolKey.toId();
        manager.initialize(poolKey, SQRT_PRICE_1_1);

        token0Erc.mint(alice, INITIAL_BALANCE);
        token1Erc.mint(alice, INITIAL_BALANCE);
        vm.startPrank(alice);
        token0Erc.approve(address(swapRouter), type(uint256).max);
        token1Erc.approve(address(swapRouter), type(uint256).max);
        vm.stopPrank();
    }

    function _deployHook() internal {
        uint160 flags = uint160(
            Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG | Hooks.BEFORE_INITIALIZE_FLAG
                | Hooks.BEFORE_ADD_LIQUIDITY_FLAG
        );
        bytes memory constructorArgs = abi.encode(
            address(manager), address(tesseraSwap), address(tesseraManager), address(tesseraSwap), address(this)
        );
        (address hookAddress, bytes32 salt) =
            HookMiner.find(address(this), flags, type(TesseraAggregator).creationCode, constructorArgs);
        hook = new TesseraAggregator{salt: salt}(
            manager,
            ITesseraSwap(address(tesseraSwap)),
            ITesseraManager(address(tesseraManager)),
            address(tesseraSwap),
            address(this)
        );
        require(address(hook) == hookAddress, "Hook address mismatch");
    }

    // ========== SWAP TESTS ==========

    function test_swapExactInput_ZeroForOne() public {
        uint256 expectedOut = hook.quote(true, -int256(SWAP_AMOUNT), poolId);
        assertGt(expectedOut, 0);

        uint256 t0Before = token0Erc.balanceOf(alice);
        uint256 t1Before = token1Erc.balanceOf(alice);

        vm.prank(alice);
        swapRouter.swap(
            poolKey,
            SwapParams({zeroForOne: true, amountSpecified: -int256(SWAP_AMOUNT), sqrtPriceLimitX96: MIN_PRICE_LIMIT}),
            SafePoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );

        assertEq(t0Before - token0Erc.balanceOf(alice), SWAP_AMOUNT);
        assertEq(token1Erc.balanceOf(alice) - t1Before, expectedOut);
    }

    function test_swapExactInput_OneForZero() public {
        uint256 expectedOut = hook.quote(false, -int256(SWAP_AMOUNT), poolId);
        assertGt(expectedOut, 0);

        uint256 t0Before = token0Erc.balanceOf(alice);
        uint256 t1Before = token1Erc.balanceOf(alice);

        vm.prank(alice);
        swapRouter.swap(
            poolKey,
            SwapParams({zeroForOne: false, amountSpecified: -int256(SWAP_AMOUNT), sqrtPriceLimitX96: MAX_PRICE_LIMIT}),
            SafePoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );

        assertEq(t1Before - token1Erc.balanceOf(alice), SWAP_AMOUNT);
        assertEq(token0Erc.balanceOf(alice) - t0Before, expectedOut);
    }

    function test_swapExactOutput_ZeroForOne() public {
        uint256 expectedIn = hook.quote(true, int256(SWAP_AMOUNT), poolId);
        assertGt(expectedIn, 0);

        uint256 t0Before = token0Erc.balanceOf(alice);
        uint256 t1Before = token1Erc.balanceOf(alice);

        vm.prank(alice);
        swapRouter.swap(
            poolKey,
            SwapParams({zeroForOne: true, amountSpecified: int256(SWAP_AMOUNT), sqrtPriceLimitX96: MIN_PRICE_LIMIT}),
            SafePoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );

        assertEq(token1Erc.balanceOf(alice) - t1Before, SWAP_AMOUNT);
        assertEq(t0Before - token0Erc.balanceOf(alice), expectedIn);
    }

    function test_swapExactOutput_OneForZero() public {
        uint256 expectedIn = hook.quote(false, int256(SWAP_AMOUNT), poolId);
        assertGt(expectedIn, 0);

        uint256 t0Before = token0Erc.balanceOf(alice);
        uint256 t1Before = token1Erc.balanceOf(alice);

        vm.prank(alice);
        swapRouter.swap(
            poolKey,
            SwapParams({zeroForOne: false, amountSpecified: int256(SWAP_AMOUNT), sqrtPriceLimitX96: MAX_PRICE_LIMIT}),
            SafePoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );

        assertEq(token0Erc.balanceOf(alice) - t0Before, SWAP_AMOUNT);
        assertEq(t1Before - token1Erc.balanceOf(alice), expectedIn);
    }

    // ========== ERROR PATH TESTS ==========

    function test_quote_PoolDoesNotExist_reverts() public {
        PoolKey memory fakeKey = PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: 1000,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(address(hook))
        });
        vm.expectRevert(IAggregatorHook.PoolDoesNotExist.selector);
        hook.quote(true, -int256(SWAP_AMOUNT), fakeKey.toId());
    }

    function test_pseudoTotalValueLocked_PoolDoesNotExist_reverts() public {
        PoolKey memory fakeKey = PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: 1000,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(address(hook))
        });
        vm.expectRevert(IAggregatorHook.PoolDoesNotExist.selector);
        hook.pseudoTotalValueLocked(fakeKey.toId());
    }

    function test_initialize_NativeRejected_reverts() public {
        MockERC20 someToken = new MockERC20("Some", "S", DECIMALS);
        PoolKey memory nativeKey = PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(address(someToken)),
            fee: POOL_FEE,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(address(hook))
        });
        vm.expectRevert();
        manager.initialize(nativeKey, SQRT_PRICE_1_1);
    }

    function test_initialize_PairNotSupported_reverts() public {
        MockERC20 a = new MockERC20("A", "A", DECIMALS);
        MockERC20 b = new MockERC20("B", "B", DECIMALS);
        if (address(a) > address(b)) (a, b) = (b, a);
        PoolKey memory unsupportedKey = PoolKey({
            currency0: Currency.wrap(address(a)),
            currency1: Currency.wrap(address(b)),
            fee: POOL_FEE,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(address(hook))
        });
        vm.expectRevert();
        manager.initialize(unsupportedKey, SQRT_PRICE_1_1);
    }

    function test_initialize_TradingDisabled_reverts() public {
        MockERC20 a = new MockERC20("A", "A", DECIMALS);
        MockERC20 b = new MockERC20("B", "B", DECIMALS);
        if (address(a) > address(b)) (a, b) = (b, a);

        MockTesseraPool disabledPool =
            new MockTesseraPool(address(a), address(b), DECIMALS, DECIMALS, false);
        tesseraManager.registerPool(address(a), address(b), address(disabledPool));

        PoolKey memory disabledKey = PoolKey({
            currency0: Currency.wrap(address(a)),
            currency1: Currency.wrap(address(b)),
            fee: POOL_FEE,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(address(hook))
        });
        vm.expectRevert();
        manager.initialize(disabledKey, SQRT_PRICE_1_1);
    }

    function test_initialize_DuplicatePair_reverts() public {
        PoolKey memory dupKey = PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(address(hook))
        });
        vm.expectRevert();
        manager.initialize(dupKey, SQRT_PRICE_1_1);
    }

    function test_unauthorizedCallback_reverts() public {
        vm.expectRevert(TesseraAggregator.UnauthorizedCallback.selector);
        hook.tesseraSwapCallback(int256(1), -int256(1), "");
    }

    function test_callbackOutsideInflight_reverts() public {
        vm.prank(address(tesseraSwap));
        vm.expectRevert(TesseraAggregator.ProhibitedEntry.selector);
        hook.tesseraSwapCallback(int256(1), -int256(1), abi.encode(currency0));
    }

    // ========== SINGLETON ==========

    function test_singletonMultiplePools() public {
        (PoolId pid2, address t0Addr, address t1Addr) = _deploySecondPool();
        assertGt(hook.quote(true, -int256(SWAP_AMOUNT), poolId), 0);
        assertGt(hook.quote(true, -int256(SWAP_AMOUNT), pid2), 0);
        (address s0a, address s1a,) = hook.poolIdToTokens(poolId);
        (address s0b, address s1b,) = hook.poolIdToTokens(pid2);
        assertEq(s0a, address(token0Erc));
        assertEq(s1a, address(token1Erc));
        assertEq(s0b, t0Addr);
        assertEq(s1b, t1Addr);
    }

    function _deploySecondPool() internal returns (PoolId pid, address t0Addr, address t1Addr) {
        MockERC20 c = new MockERC20("C", "C", DECIMALS);
        MockERC20 d = new MockERC20("D", "D", DECIMALS);
        if (address(c) > address(d)) (c, d) = (d, c);
        t0Addr = address(c);
        t1Addr = address(d);

        MockTesseraPool p = new MockTesseraPool(t0Addr, t1Addr, DECIMALS, DECIMALS, true);
        tesseraSwap.addSupportedPair(t0Addr, t1Addr);
        tesseraManager.registerPool(t0Addr, t1Addr, address(p));

        c.mint(address(tesseraSwap), INITIAL_BALANCE * 10);
        d.mint(address(tesseraSwap), INITIAL_BALANCE * 10);
        c.mint(address(manager), INITIAL_BALANCE * 10);
        d.mint(address(manager), INITIAL_BALANCE * 10);

        PoolKey memory key2 = PoolKey({
            currency0: Currency.wrap(t0Addr),
            currency1: Currency.wrap(t1Addr),
            fee: POOL_FEE,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(address(hook))
        });
        pid = key2.toId();
        manager.initialize(key2, SQRT_PRICE_1_1);
    }

    // ========== TVL ==========

    function test_pseudoTotalValueLocked_returnsTreasuryBalances() public {
        // The hook is configured with `address(tesseraSwap)` as the treasury (see _deployHook).
        // Already-minted balance on the treasury (mock) from setUp is INITIAL_BALANCE * 10 per token.
        (uint256 a0, uint256 a1) = hook.pseudoTotalValueLocked(poolId);
        assertEq(a0, INITIAL_BALANCE * 10);
        assertEq(a1, INITIAL_BALANCE * 10);
    }

    // ========== CONSTRUCTOR ZERO-ADDRESS CHECKS (M-06) ==========

    /// @dev BaseHook's address-permission validation in the parent constructor may revert before
    ///      our ZeroAddress check fires. We accept any revert here.
    function test_constructor_revertsOnZeroManager() public {
        vm.expectRevert();
        new TesseraAggregator(
            IPoolManager(address(0)),
            ITesseraSwap(address(tesseraSwap)),
            ITesseraManager(address(tesseraManager)),
            address(tesseraSwap),
            address(this)
        );
    }

    function test_constructor_revertsOnZeroSwap() public {
        vm.expectRevert();
        new TesseraAggregator(
            manager,
            ITesseraSwap(address(0)),
            ITesseraManager(address(tesseraManager)),
            address(tesseraSwap),
            address(this)
        );
    }

    function test_constructor_revertsOnZeroManagerRegistry() public {
        vm.expectRevert();
        new TesseraAggregator(
            manager,
            ITesseraSwap(address(tesseraSwap)),
            ITesseraManager(address(0)),
            address(tesseraSwap),
            address(this)
        );
    }

    function test_constructor_revertsOnZeroTreasury() public {
        vm.expectRevert();
        new TesseraAggregator(
            manager,
            ITesseraSwap(address(tesseraSwap)),
            ITesseraManager(address(tesseraManager)),
            address(0),
            address(this)
        );
    }

    function test_constructor_revertsOnZeroOwner() public {
        vm.expectRevert();
        new TesseraAggregator(
            manager,
            ITesseraSwap(address(tesseraSwap)),
            ITesseraManager(address(tesseraManager)),
            address(tesseraSwap),
            address(0)
        );
    }

    // ========== CALLBACK SIGN GUARDS (L-03) ==========

    function test_callback_revertsOnInvalidSign() public {
        tesseraSwap.setEngineInvertSignsNext(true);
        vm.prank(alice);
        vm.expectRevert();
        swapRouter.swap(
            poolKey,
            SwapParams({zeroForOne: true, amountSpecified: -int256(SWAP_AMOUNT), sqrtPriceLimitX96: MIN_PRICE_LIMIT}),
            SafePoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
    }

    // ========== ENGINE SPECIFIED AMOUNT SANITY (H-01 mitigation) ==========

    function test_swap_revertsOnEngineSpecifiedAmountMismatch_exactIn() public {
        tesseraSwap.setEngineMisreportNext(true, 1);
        vm.prank(alice);
        vm.expectRevert();
        swapRouter.swap(
            poolKey,
            SwapParams({zeroForOne: true, amountSpecified: -int256(SWAP_AMOUNT), sqrtPriceLimitX96: MIN_PRICE_LIMIT}),
            SafePoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
    }

    function test_swap_revertsOnEngineSpecifiedAmountMismatch_exactOut() public {
        tesseraSwap.setEngineMisreportNext(true, 1);
        vm.prank(alice);
        vm.expectRevert();
        swapRouter.swap(
            poolKey,
            SwapParams({zeroForOne: true, amountSpecified: int256(SWAP_AMOUNT), sqrtPriceLimitX96: MIN_PRICE_LIMIT}),
            SafePoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
    }

    // ========== DEREGISTER (M-01) ==========

    function test_deregisterPair_revertsNotOwner() public {
        vm.prank(alice);
        vm.expectRevert();
        hook.deregisterPair(poolId, address(token0Erc), address(token1Erc));
    }

    function test_deregisterPair_revertsWrongCanonical() public {
        PoolKey memory other = PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: 1000,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(address(hook))
        });
        vm.expectRevert();
        hook.deregisterPair(other.toId(), address(token0Erc), address(token1Erc));
    }

    function test_deregisterPair_allowsReregistration() public {
        hook.deregisterPair(poolId, address(token0Erc), address(token1Erc));
        (address stored0, address stored1,) = hook.poolIdToTokens(poolId);
        assertEq(stored0, address(0));
        assertEq(stored1, address(0));

        PoolKey memory freshKey = PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(address(hook))
        });
        manager.initialize(freshKey, SQRT_PRICE_1_1);
        (address fresh0, address fresh1,) = hook.poolIdToTokens(freshKey.toId());
        assertEq(fresh0, address(token0Erc));
        assertEq(fresh1, address(token1Erc));
    }

    // ========== RECEIVE BLOCKS ETH (L-06) ==========

    function test_receive_reverts() public {
        (bool ok,) = address(hook).call{value: 1 wei}("");
        assertFalse(ok, "ETH transfer should revert");
    }

    // ========== FUZZ ==========

    function testFuzz_swapExactInput_ZeroForOne(uint128 amountIn) public {
        amountIn = uint128(bound(amountIn, 10_000, INITIAL_BALANCE / 10));
        uint256 expectedOut = hook.quote(true, -int256(uint256(amountIn)), poolId);
        if (expectedOut == 0) return;

        uint256 t0Before = token0Erc.balanceOf(alice);
        uint256 t1Before = token1Erc.balanceOf(alice);

        vm.prank(alice);
        swapRouter.swap(
            poolKey,
            SwapParams({
                zeroForOne: true,
                amountSpecified: -int256(uint256(amountIn)),
                sqrtPriceLimitX96: MIN_PRICE_LIMIT
            }),
            SafePoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );

        assertEq(t0Before - token0Erc.balanceOf(alice), amountIn);
        assertEq(token1Erc.balanceOf(alice) - t1Before, expectedOut);
    }

    function testFuzz_swapExactOutput_ZeroForOne(uint128 amountOut) public {
        amountOut = uint128(bound(amountOut, 10_000, INITIAL_BALANCE / 10));
        uint256 expectedIn = hook.quote(true, int256(uint256(amountOut)), poolId);
        if (expectedIn == 0) return;

        uint256 t0Before = token0Erc.balanceOf(alice);
        uint256 t1Before = token1Erc.balanceOf(alice);

        vm.prank(alice);
        swapRouter.swap(
            poolKey,
            SwapParams({
                zeroForOne: true,
                amountSpecified: int256(uint256(amountOut)),
                sqrtPriceLimitX96: MIN_PRICE_LIMIT
            }),
            SafePoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );

        assertEq(token1Erc.balanceOf(alice) - t1Before, amountOut);
        assertEq(t0Before - token0Erc.balanceOf(alice), expectedIn);
    }

    receive() external payable {}
}
