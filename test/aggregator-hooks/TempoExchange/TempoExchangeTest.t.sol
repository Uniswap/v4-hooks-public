// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolManager} from "@uniswap/v4-core/src/PoolManager.sol";
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
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {ExternalLiqSourceHook} from "../../../src/aggregator-hooks/ExternalLiqSourceHook.sol";
import {
    TempoExchangeAggregator
} from "../../../src/aggregator-hooks/implementations/TempoExchange/TempoExchangeAggregator.sol";
import {
    ITempoExchange
} from "../../../src/aggregator-hooks/implementations/TempoExchange/interfaces/ITempoExchange.sol";
import {MockTempoExchange} from "./mocks/MockTempoExchange.sol";
import {RevertingMockTempoExchange} from "./mocks/RevertingMockTempoExchange.sol";

/// @title TempoExchangeTest
/// @notice Unit tests for Tempo Exchange aggregator hook
/// @dev Uses mock contracts since Tempo is a separate chain
contract TempoExchangeTest is Test {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;
    using StateLibrary for IPoolManager;

    // Pool configuration
    uint24 constant POOL_FEE = 500; // 0.05%
    int24 constant TICK_SPACING = 10;
    uint160 constant SQRT_PRICE_1_1 = 79_228_162_514_264_337_593_543_950_336; // 1:1 price

    // Price limits for swaps
    uint160 constant MIN_PRICE_LIMIT = TickMath.MIN_SQRT_PRICE + 1;
    uint160 constant MAX_PRICE_LIMIT = TickMath.MAX_SQRT_PRICE - 1;

    // Stablecoin decimals (Tempo uses 6 decimals)
    uint8 constant DECIMALS = 6;

    // Test amounts
    uint256 constant SWAP_AMOUNT = 1000 * 10 ** DECIMALS; // 1000 tokens
    uint256 constant INITIAL_BALANCE = 1_000_000 * 10 ** DECIMALS; // 1M tokens

    IPoolManager public manager;
    SafePoolSwapTest public swapRouter;
    TempoExchangeAggregator public hook;
    MockTempoExchange public tempoExchange;

    MockERC20 public alphaUSD;
    MockERC20 public betaUSD;

    PoolKey public poolKey;
    PoolId public poolId;

    Currency public currency0;
    Currency public currency1;

    address public alice = makeAddr("alice");

    function setUp() public {
        // Deploy mock tokens (simulating Tempo stablecoins)
        alphaUSD = new MockERC20("AlphaUSD", "aUSD", DECIMALS);
        betaUSD = new MockERC20("BetaUSD", "bUSD", DECIMALS);

        // Ensure tokens are ordered correctly for v4 (lower address = currency0)
        if (address(alphaUSD) > address(betaUSD)) {
            (alphaUSD, betaUSD) = (betaUSD, alphaUSD);
        }

        currency0 = Currency.wrap(address(alphaUSD));
        currency1 = Currency.wrap(address(betaUSD));

        // Deploy mock Tempo exchange
        tempoExchange = new MockTempoExchange();

        // Fund the mock exchange with liquidity
        alphaUSD.mint(address(tempoExchange), INITIAL_BALANCE * 10);
        betaUSD.mint(address(tempoExchange), INITIAL_BALANCE * 10);

        // Deploy PoolManager
        manager = new PoolManager(address(0));

        // Mint tokens to PoolManager so it has liquidity for swaps
        alphaUSD.mint(address(manager), INITIAL_BALANCE * 10);
        betaUSD.mint(address(manager), INITIAL_BALANCE * 10);

        // Deploy swap router
        swapRouter = new SafePoolSwapTest(manager);

        // Deploy hook with correct address flags
        _deployHook();

        // Initialize the pool
        poolKey = PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: POOL_FEE,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(address(hook))
        });
        poolId = poolKey.toId();

        manager.initialize(poolKey, SQRT_PRICE_1_1);

        // Mint tokens to alice for testing
        alphaUSD.mint(alice, INITIAL_BALANCE);
        betaUSD.mint(alice, INITIAL_BALANCE);

        // Approve swap router for alice
        vm.startPrank(alice);
        alphaUSD.approve(address(swapRouter), type(uint256).max);
        betaUSD.approve(address(swapRouter), type(uint256).max);
        vm.stopPrank();
    }

    function _deployHook() internal {
        // Hook flags required by ExternalLiqSourceHook
        uint160 flags =
            uint160(Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG | Hooks.BEFORE_INITIALIZE_FLAG);

        bytes memory constructorArgs = abi.encode(address(manager), address(tempoExchange));
        (address hookAddress, bytes32 salt) =
            HookMiner.find(address(this), flags, type(TempoExchangeAggregator).creationCode, constructorArgs);

        hook = new TempoExchangeAggregator{salt: salt}(manager, ITempoExchange(address(tempoExchange)));
        require(address(hook) == hookAddress, "Hook address mismatch");
    }

    // ========== SWAP TESTS ==========

    /// @notice Test exact input swap: Token0 -> Token1 (zero to one)
    function test_swapExactInput_ZeroForOne() public {
        uint256 amountIn = SWAP_AMOUNT;

        // Get quote before swap
        uint256 expectedOut = hook.quote(true, -int256(amountIn), poolId);
        assertGt(expectedOut, 0, "Quote should return non-zero");

        uint256 token0Before = alphaUSD.balanceOf(alice);
        uint256 token1Before = betaUSD.balanceOf(alice);

        vm.prank(alice);
        swapRouter.swap(
            poolKey,
            SwapParams({zeroForOne: true, amountSpecified: -int256(amountIn), sqrtPriceLimitX96: MIN_PRICE_LIMIT}),
            SafePoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );

        uint256 token0After = alphaUSD.balanceOf(alice);
        uint256 token1After = betaUSD.balanceOf(alice);

        assertEq(token0Before - token0After, amountIn, "Token0 should decrease by exact input amount");

        uint256 received = token1After - token1Before;
        assertEq(received, expectedOut, "Received amount should match quote");
    }

    /// @notice Test exact input swap: Token1 -> Token0 (one to zero)
    function test_swapExactInput_OneForZero() public {
        uint256 amountIn = SWAP_AMOUNT;

        // Get quote before swap
        uint256 expectedOut = hook.quote(false, -int256(amountIn), poolId);
        assertGt(expectedOut, 0, "Quote should return non-zero");

        uint256 token0Before = alphaUSD.balanceOf(alice);
        uint256 token1Before = betaUSD.balanceOf(alice);

        vm.prank(alice);
        swapRouter.swap(
            poolKey,
            SwapParams({zeroForOne: false, amountSpecified: -int256(amountIn), sqrtPriceLimitX96: MAX_PRICE_LIMIT}),
            SafePoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );

        uint256 token0After = alphaUSD.balanceOf(alice);
        uint256 token1After = betaUSD.balanceOf(alice);

        assertEq(token1Before - token1After, amountIn, "Token1 should decrease by exact input amount");

        uint256 received = token0After - token0Before;
        assertEq(received, expectedOut, "Received amount should match quote");
    }

    /// @notice Test exact output swap: Token0 -> Token1 (zero to one)
    function test_swapExactOutput_ZeroForOne() public {
        uint256 amountOut = SWAP_AMOUNT;

        // Get quote for expected input amount
        uint256 expectedIn = hook.quote(true, int256(amountOut), poolId);
        assertGt(expectedIn, 0, "Quote should return non-zero");

        uint256 token0Before = alphaUSD.balanceOf(alice);
        uint256 token1Before = betaUSD.balanceOf(alice);

        vm.prank(alice);
        swapRouter.swap(
            poolKey,
            SwapParams({zeroForOne: true, amountSpecified: int256(amountOut), sqrtPriceLimitX96: MIN_PRICE_LIMIT}),
            SafePoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );

        uint256 token0After = alphaUSD.balanceOf(alice);
        uint256 token1After = betaUSD.balanceOf(alice);

        uint256 token1Received = token1After - token1Before;
        assertEq(token1Received, amountOut, "Token1 received should match exact output amount");

        uint256 token0Spent = token0Before - token0After;
        assertEq(token0Spent, expectedIn, "Token0 spent should match quote");
    }

    /// @notice Test exact output swap: Token1 -> Token0 (one to zero)
    function test_swapExactOutput_OneForZero() public {
        uint256 amountOut = SWAP_AMOUNT;

        // Get quote for expected input amount
        uint256 expectedIn = hook.quote(false, int256(amountOut), poolId);
        assertGt(expectedIn, 0, "Quote should return non-zero");

        uint256 token0Before = alphaUSD.balanceOf(alice);
        uint256 token1Before = betaUSD.balanceOf(alice);

        vm.prank(alice);
        swapRouter.swap(
            poolKey,
            SwapParams({zeroForOne: false, amountSpecified: int256(amountOut), sqrtPriceLimitX96: MAX_PRICE_LIMIT}),
            SafePoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );

        uint256 token0After = alphaUSD.balanceOf(alice);
        uint256 token1After = betaUSD.balanceOf(alice);

        uint256 token0Received = token0After - token0Before;
        assertEq(token0Received, amountOut, "Token0 received should match exact output amount");

        uint256 token1Spent = token1Before - token1After;
        assertEq(token1Spent, expectedIn, "Token1 spent should match quote");
    }

    // ========== ERROR PATH TESTS ==========

    /// @notice Test quote reverts for unregistered pool
    function test_quote_PoolDoesNotExist_reverts() public {
        // Create a fake pool ID that hasn't been registered
        PoolKey memory fakePoolKey = PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: 1000, // Different fee to get different pool ID
            tickSpacing: TICK_SPACING,
            hooks: IHooks(address(hook))
        });
        PoolId fakePoolId = fakePoolKey.toId();

        vm.expectRevert(ExternalLiqSourceHook.PoolDoesNotExist.selector);
        hook.quote(true, -int256(SWAP_AMOUNT), fakePoolId);
    }

    /// @notice Test pseudoTotalValueLocked reverts for unregistered pool
    function test_pseudoTotalValueLocked_PoolDoesNotExist_reverts() public {
        // Create a fake pool ID that hasn't been registered
        PoolKey memory fakePoolKey = PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: 1000, // Different fee to get different pool ID
            tickSpacing: TICK_SPACING,
            hooks: IHooks(address(hook))
        });
        PoolId fakePoolId = fakePoolKey.toId();

        vm.expectRevert(ExternalLiqSourceHook.PoolDoesNotExist.selector);
        hook.pseudoTotalValueLocked(fakePoolId);
    }

    /// @notice Test that amounts exceeding uint128 revert
    function test_amountExceedsUint128_reverts() public {
        // Try to quote with an amount that exceeds uint128
        uint256 hugeAmount = uint256(type(uint128).max) + 1;

        vm.expectRevert(TempoExchangeAggregator.AmountExceedsUint128.selector);
        hook.quote(true, -int256(hugeAmount), poolId);
    }

    /// @notice Test that exact output with amount exceeding uint128 reverts
    function test_amountExceedsUint128_exactOutput_reverts() public {
        uint256 hugeAmount = uint256(type(uint128).max) + 1;

        vm.expectRevert(TempoExchangeAggregator.AmountExceedsUint128.selector);
        hook.quote(true, int256(hugeAmount), poolId);
    }

    /// @notice Test initialization with unsupported tokens reverts
    function test_initializeUnsupportedTokens_reverts() public {
        // Deploy a new mock exchange that reverts on quote
        RevertingMockTempoExchange revertingExchange = new RevertingMockTempoExchange();

        // Deploy a new hook with the reverting exchange
        uint160 flags =
            uint160(Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG | Hooks.BEFORE_INITIALIZE_FLAG);

        bytes memory constructorArgs = abi.encode(address(manager), address(revertingExchange));
        (, bytes32 salt) =
            HookMiner.find(address(this), flags, type(TempoExchangeAggregator).creationCode, constructorArgs);

        TempoExchangeAggregator revertingHook =
            new TempoExchangeAggregator{salt: salt}(manager, ITempoExchange(address(revertingExchange)));

        // Try to initialize a pool with the reverting hook
        PoolKey memory unsupportedPoolKey = PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: 2000, // Different fee
            tickSpacing: TICK_SPACING,
            hooks: IHooks(address(revertingHook))
        });

        // PoolManager wraps hook errors in WrappedError, so we just verify it reverts
        vm.expectRevert();
        manager.initialize(unsupportedPoolKey, SQRT_PRICE_1_1);
    }

    // ========== SINGLETON PATTERN TESTS ==========

    /// @notice Test that the same hook can support multiple pools (singleton pattern)
    function test_singletonMultiplePools() public {
        // Deploy additional tokens for second pool
        MockERC20 gammaUSD = new MockERC20("GammaUSD", "gUSD", DECIMALS);
        MockERC20 deltaUSD = new MockERC20("DeltaUSD", "dUSD", DECIMALS);

        // Order tokens correctly
        if (address(gammaUSD) > address(deltaUSD)) {
            (gammaUSD, deltaUSD) = (deltaUSD, gammaUSD);
        }

        Currency currency2 = Currency.wrap(address(gammaUSD));
        Currency currency3 = Currency.wrap(address(deltaUSD));

        // Fund the mock exchange with new tokens
        gammaUSD.mint(address(tempoExchange), INITIAL_BALANCE * 10);
        deltaUSD.mint(address(tempoExchange), INITIAL_BALANCE * 10);

        // Fund PoolManager
        gammaUSD.mint(address(manager), INITIAL_BALANCE * 10);
        deltaUSD.mint(address(manager), INITIAL_BALANCE * 10);

        // Initialize a second pool with the SAME hook
        PoolKey memory poolKey2 = PoolKey({
            currency0: currency2,
            currency1: currency3,
            fee: POOL_FEE,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(address(hook)) // Same hook!
        });
        PoolId poolId2 = poolKey2.toId();

        manager.initialize(poolKey2, SQRT_PRICE_1_1);

        // Verify both pools work independently

        // Test quote on first pool
        uint256 quote1 = hook.quote(true, -int256(SWAP_AMOUNT), poolId);
        assertGt(quote1, 0, "First pool quote should work");

        // Test quote on second pool
        uint256 quote2 = hook.quote(true, -int256(SWAP_AMOUNT), poolId2);
        assertGt(quote2, 0, "Second pool quote should work");

        // Test TVL on both pools
        (uint256 tvl1_0, uint256 tvl1_1) = hook.pseudoTotalValueLocked(poolId);
        (uint256 tvl2_0, uint256 tvl2_1) = hook.pseudoTotalValueLocked(poolId2);

        assertGt(tvl1_0, 0, "First pool TVL token0");
        assertGt(tvl1_1, 0, "First pool TVL token1");
        assertGt(tvl2_0, 0, "Second pool TVL token0");
        assertGt(tvl2_1, 0, "Second pool TVL token1");

        // Verify poolIdToTokens mapping stores correct addresses
        (address stored0, address stored1) = hook.poolIdToTokens(poolId);
        assertEq(stored0, address(alphaUSD), "First pool token0 mismatch");
        assertEq(stored1, address(betaUSD), "First pool token1 mismatch");

        (address stored2, address stored3) = hook.poolIdToTokens(poolId2);
        assertEq(stored2, address(gammaUSD), "Second pool token0 mismatch");
        assertEq(stored3, address(deltaUSD), "Second pool token1 mismatch");
    }

    // ========== ADDITIONAL TESTS ==========

    /// @notice Test that multiple swaps work correctly
    function test_multipleSwaps() public {
        uint256 amount = SWAP_AMOUNT / 2;

        // First swap: Token0 -> Token1 (exact input)
        vm.prank(alice);
        swapRouter.swap(
            poolKey,
            SwapParams({zeroForOne: true, amountSpecified: -int256(amount), sqrtPriceLimitX96: MIN_PRICE_LIMIT}),
            SafePoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );

        // Second swap: Token1 -> Token0 (exact input)
        vm.prank(alice);
        swapRouter.swap(
            poolKey,
            SwapParams({zeroForOne: false, amountSpecified: -int256(amount), sqrtPriceLimitX96: MAX_PRICE_LIMIT}),
            SafePoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );

        // Third swap: Token0 -> Token1 (exact output)
        vm.prank(alice);
        swapRouter.swap(
            poolKey,
            SwapParams({zeroForOne: true, amountSpecified: int256(amount / 2), sqrtPriceLimitX96: MIN_PRICE_LIMIT}),
            SafePoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
    }

    /// @notice Verify quote function returns reasonable values
    function test_quote() public {
        uint256 amountIn = SWAP_AMOUNT;

        uint256 expectedOut = hook.quote(true, -int256(amountIn), poolId);

        assertGt(expectedOut, 0, "Quote should return non-zero");
        // With 0.1% fee, output should be close to input for stablecoins
        assertGt(expectedOut, amountIn * 99 / 100, "Quote should be close to input for stablecoins");
    }

    /// @notice Test pseudoTotalValueLocked returns non-zero values
    function test_pseudoTotalValueLocked() public view {
        (uint256 amount0, uint256 amount1) = hook.pseudoTotalValueLocked(poolId);

        assertGt(amount0, 0, "amount0 should be non-zero");
        assertGt(amount1, 0, "amount1 should be non-zero");
    }

    /// @notice Test swap with large amount
    function test_swapLargeAmount() public {
        uint256 largeAmount = 100_000 * 10 ** DECIMALS;

        // Mint extra tokens for large swap
        alphaUSD.mint(alice, largeAmount);

        uint256 expectedOut = hook.quote(true, -int256(largeAmount), poolId);
        assertGt(expectedOut, 0, "Quote should return non-zero");

        uint256 token0Before = alphaUSD.balanceOf(alice);
        uint256 token1Before = betaUSD.balanceOf(alice);

        vm.prank(alice);
        swapRouter.swap(
            poolKey,
            SwapParams({zeroForOne: true, amountSpecified: -int256(largeAmount), sqrtPriceLimitX96: MIN_PRICE_LIMIT}),
            SafePoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );

        uint256 token0After = alphaUSD.balanceOf(alice);
        uint256 token1After = betaUSD.balanceOf(alice);

        assertEq(token0Before - token0After, largeAmount, "Large swap input mismatch");
        assertEq(token1After - token1Before, expectedOut, "Large swap output mismatch");
    }

    /// @notice Test swap with minimum amount (1 wei)
    function test_swapMinimumAmount() public {
        uint256 minAmount = 1;

        uint256 expectedOut = hook.quote(true, -int256(minAmount), poolId);
        // With 0.1% fee on 1 wei, output will be 0
        assertEq(expectedOut, 0, "Minimum amount output should be 0 due to fee");
    }

    // ========== FUZZ TESTS ==========

    /// @notice Fuzz test for exact input swaps (zero to one)
    function testFuzz_swapExactInput_ZeroForOne(uint128 amountIn) public {
        // Bound to reasonable amounts (1 to 100k tokens)
        amountIn = uint128(bound(amountIn, 1 * 10 ** DECIMALS, 100_000 * 10 ** DECIMALS));

        uint256 expectedOut = hook.quote(true, -int256(uint256(amountIn)), poolId);
        assertGt(expectedOut, 0, "Quote should return non-zero");

        uint256 token0Before = alphaUSD.balanceOf(alice);
        uint256 token1Before = betaUSD.balanceOf(alice);

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

        uint256 token0After = alphaUSD.balanceOf(alice);
        uint256 token1After = betaUSD.balanceOf(alice);

        assertEq(token0Before - token0After, amountIn, "Input amount mismatch");
        assertEq(token1After - token1Before, expectedOut, "Output amount mismatch");
    }

    /// @notice Fuzz test for exact input swaps (one to zero)
    function testFuzz_swapExactInput_OneForZero(uint128 amountIn) public {
        // Bound to reasonable amounts (1 to 100k tokens)
        amountIn = uint128(bound(amountIn, 1 * 10 ** DECIMALS, 100_000 * 10 ** DECIMALS));

        uint256 expectedOut = hook.quote(false, -int256(uint256(amountIn)), poolId);
        assertGt(expectedOut, 0, "Quote should return non-zero");

        uint256 token0Before = alphaUSD.balanceOf(alice);
        uint256 token1Before = betaUSD.balanceOf(alice);

        vm.prank(alice);
        swapRouter.swap(
            poolKey,
            SwapParams({
                zeroForOne: false,
                amountSpecified: -int256(uint256(amountIn)),
                sqrtPriceLimitX96: MAX_PRICE_LIMIT
            }),
            SafePoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );

        uint256 token0After = alphaUSD.balanceOf(alice);
        uint256 token1After = betaUSD.balanceOf(alice);

        assertEq(token1Before - token1After, amountIn, "Input amount mismatch");
        assertEq(token0After - token0Before, expectedOut, "Output amount mismatch");
    }

    /// @notice Fuzz test for exact output swaps (zero to one)
    function testFuzz_swapExactOutput_ZeroForOne(uint128 amountOut) public {
        // Bound to reasonable amounts (1 to 100k tokens)
        amountOut = uint128(bound(amountOut, 1 * 10 ** DECIMALS, 100_000 * 10 ** DECIMALS));

        uint256 expectedIn = hook.quote(true, int256(uint256(amountOut)), poolId);
        assertGt(expectedIn, 0, "Quote should return non-zero");

        uint256 token0Before = alphaUSD.balanceOf(alice);
        uint256 token1Before = betaUSD.balanceOf(alice);

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

        uint256 token0After = alphaUSD.balanceOf(alice);
        uint256 token1After = betaUSD.balanceOf(alice);

        assertEq(token1After - token1Before, amountOut, "Output amount mismatch");
        assertEq(token0Before - token0After, expectedIn, "Input amount mismatch");
    }

    /// @notice Fuzz test for exact output swaps (one to zero)
    function testFuzz_swapExactOutput_OneForZero(uint128 amountOut) public {
        // Bound to reasonable amounts (1 to 100k tokens)
        amountOut = uint128(bound(amountOut, 1 * 10 ** DECIMALS, 100_000 * 10 ** DECIMALS));

        uint256 expectedIn = hook.quote(false, int256(uint256(amountOut)), poolId);
        assertGt(expectedIn, 0, "Quote should return non-zero");

        uint256 token0Before = alphaUSD.balanceOf(alice);
        uint256 token1Before = betaUSD.balanceOf(alice);

        vm.prank(alice);
        swapRouter.swap(
            poolKey,
            SwapParams({
                zeroForOne: false,
                amountSpecified: int256(uint256(amountOut)),
                sqrtPriceLimitX96: MAX_PRICE_LIMIT
            }),
            SafePoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );

        uint256 token0After = alphaUSD.balanceOf(alice);
        uint256 token1After = betaUSD.balanceOf(alice);

        assertEq(token0After - token0Before, amountOut, "Output amount mismatch");
        assertEq(token1Before - token1After, expectedIn, "Input amount mismatch");
    }

    /// @notice Fuzz test for quote consistency (exact in vs exact out)
    function testFuzz_quoteConsistency(uint128 amount) public {
        // Bound to reasonable amounts
        amount = uint128(bound(amount, 100 * 10 ** DECIMALS, 10_000 * 10 ** DECIMALS));

        // Get output for exact input
        uint256 outputFromExactIn = hook.quote(true, -int256(uint256(amount)), poolId);

        // Get input required for that output
        uint256 inputForExactOut = hook.quote(true, int256(outputFromExactIn), poolId);

        // Due to fee calculation rounding, input should be <= original amount
        assertLe(inputForExactOut, amount, "Round-trip should not exceed original");
    }

    receive() external payable {}
}
