// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import "forge-std/Script.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {TempoExchangeAggregator} from
    "../src/aggregator-hooks/implementations/TempoExchange/TempoExchangeAggregator.sol";
import {ITempoExchange} from
    "../src/aggregator-hooks/implementations/TempoExchange/interfaces/ITempoExchange.sol";
import {SafePoolSwapTest} from "../test/aggregator-hooks/shared/SafePoolSwapTest.sol";

/// @title TestTempoAggregator
/// @notice Integration test script for the Tempo Exchange aggregator hook.
/// @dev Sends real transactions to the Tempo chain via `forge script --broadcast --skip-simulation`.
///      Reuses already-deployed hook + router; uses require() assertions instead of Test helpers.
contract TestTempoAggregator is Script {
    using PoolIdLibrary for PoolKey;

    // Default addresses (Tempo Moderato, chain 42431)
    address constant DEFAULT_POOL_MANAGER = 0x72B37Ad2798c6C2B51C7873Ed2E291a88bB909a2;
    address constant DEFAULT_TEMPO_EXCHANGE = 0xDEc0000000000000000000000000000000000000;
    address constant PATH_USD = 0x20C0000000000000000000000000000000000001;

    // Pool configuration
    uint24 constant POOL_FEE = 500;
    int24 constant TICK_SPACING = 10;

    // Price limits for swaps
    uint160 constant MIN_PRICE_LIMIT = TickMath.MIN_SQRT_PRICE + 1;
    uint160 constant MAX_PRICE_LIMIT = TickMath.MAX_SQRT_PRICE - 1;

    // Stablecoin decimals (all Tempo stablecoins use 6 decimals)
    uint8 constant DECIMALS = 6;

    // Test amounts (kept small for testnet liquidity resilience)
    uint256 constant SWAP_AMOUNT = 1 * 10 ** DECIMALS; // 1 token
    uint256 constant FUND_AMOUNT = 100_000 * 10 ** DECIMALS; // 100k tokens

    // Loaded from env
    uint256 private deployerKey;
    address private deployer;
    TempoExchangeAggregator private hook;
    SafePoolSwapTest private router;
    ITempoExchange private exchange;
    address private token0;
    address private token1;
    PoolKey private poolKey;
    PoolId private poolId;

    // ──────────────────── Configuration ────────────────────

    function _loadConfig() internal {
        deployerKey = vm.envUint("PRIVATE_KEY");
        deployer = vm.addr(deployerKey);

        hook = TempoExchangeAggregator(payable(vm.envAddress("HOOK_ADDRESS")));
        router = SafePoolSwapTest(payable(vm.envAddress("ROUTER_ADDRESS")));
        exchange = ITempoExchange(vm.envOr("TEMPO_EXCHANGE", DEFAULT_TEMPO_EXCHANGE));

        address t0 = vm.envAddress("TEMPO_TOKEN_0");
        address t1 = vm.envAddress("TEMPO_TOKEN_1");
        // Ensure correct ordering for v4
        if (t0 > t1) (t0, t1) = (t1, t0);
        token0 = t0;
        token1 = t1;

        address poolManager = vm.envOr("POOL_MANAGER", DEFAULT_POOL_MANAGER);
        poolKey = PoolKey({
            currency0: Currency.wrap(token0),
            currency1: Currency.wrap(token1),
            fee: POOL_FEE,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(address(hook))
        });
        poolId = poolKey.toId();

        console.log("=== TestTempoAggregator ===");
        console.log("Deployer:", deployer);
        console.log("Hook:", address(hook));
        console.log("Router:", address(router));
        console.log("Token0:", token0);
        console.log("Token1:", token1);
        console.log("PoolManager:", poolManager);
    }

    // ──────────────────── Fund ────────────────────

    /// @notice Buys tokens via Tempo exchange and approves the router. Run once before tests.
    function fund() public {
        _loadConfig();

        console.log("");
        console.log("--- fund ---");

        vm.startBroadcast(deployerKey);

        // Buy token0 (if not PathUSD) and token1 (if not PathUSD) via exchange
        _fundToken(token0);
        _fundToken(token1);

        // Approve router to spend both tokens
        IERC20(token0).approve(address(router), type(uint256).max);
        IERC20(token1).approve(address(router), type(uint256).max);

        vm.stopBroadcast();

        // Balance reads are view calls — outside broadcast
        uint256 bal0 = IERC20(token0).balanceOf(deployer);
        uint256 bal1 = IERC20(token1).balanceOf(deployer);
        console.log("Balance token0:", bal0);
        console.log("Balance token1:", bal1);
        require(bal0 >= SWAP_AMOUNT, "Insufficient token0 balance after funding");
        require(bal1 >= SWAP_AMOUNT, "Insufficient token1 balance after funding");

        console.log("fund PASS");
    }

    function _fundToken(address token) internal {
        if (token == PATH_USD) return; // deployer already holds PathUSD
        // Buy FUND_AMOUNT of token using PathUSD
        IERC20(PATH_USD).approve(address(exchange), type(uint256).max);
        exchange.swapExactAmountOut(PATH_USD, token, uint128(FUND_AMOUNT), type(uint128).max);
    }

    // ──────────────────── Test: Exact-Input 0→1 ────────────────────

    function test_swapExactInput_ZeroForOne() public {
        _loadConfig();
        console.log("");
        console.log("--- test_swapExactInput_ZeroForOne ---");

        uint256 amountIn = SWAP_AMOUNT;

        // Quote (payable — inside broadcast)
        vm.startBroadcast(deployerKey);
        uint256 expectedOut = hook.quote(true, -int256(amountIn), poolId);
        vm.stopBroadcast();
        require(expectedOut > 0, "Quote should return non-zero");

        // Balances before (view)
        uint256 bal0Before = IERC20(token0).balanceOf(deployer);
        uint256 bal1Before = IERC20(token1).balanceOf(deployer);

        // Swap
        vm.startBroadcast(deployerKey);
        router.swap(
            poolKey,
            SwapParams({zeroForOne: true, amountSpecified: -int256(amountIn), sqrtPriceLimitX96: MIN_PRICE_LIMIT}),
            SafePoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
        vm.stopBroadcast();

        // Balances after (view)
        uint256 bal0After = IERC20(token0).balanceOf(deployer);
        uint256 bal1After = IERC20(token1).balanceOf(deployer);

        uint256 spent = bal0Before - bal0After;
        uint256 received = bal1After - bal1Before;
        require(spent == amountIn, "Token0 should decrease by exact input amount");
        require(received == expectedOut, "Received amount should match quote");

        console.log("  spent:", spent);
        console.log("  received:", received);
        console.log("test_swapExactInput_ZeroForOne PASS");
    }

    // ──────────────────── Test: Exact-Input 1→0 ────────────────────

    function test_swapExactInput_OneForZero() public {
        _loadConfig();
        console.log("");
        console.log("--- test_swapExactInput_OneForZero ---");

        uint256 amountIn = SWAP_AMOUNT;

        vm.startBroadcast(deployerKey);
        uint256 expectedOut = hook.quote(false, -int256(amountIn), poolId);
        vm.stopBroadcast();
        require(expectedOut > 0, "Quote should return non-zero");

        uint256 bal0Before = IERC20(token0).balanceOf(deployer);
        uint256 bal1Before = IERC20(token1).balanceOf(deployer);

        vm.startBroadcast(deployerKey);
        router.swap(
            poolKey,
            SwapParams({zeroForOne: false, amountSpecified: -int256(amountIn), sqrtPriceLimitX96: MAX_PRICE_LIMIT}),
            SafePoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
        vm.stopBroadcast();

        uint256 bal0After = IERC20(token0).balanceOf(deployer);
        uint256 bal1After = IERC20(token1).balanceOf(deployer);

        uint256 spent = bal1Before - bal1After;
        uint256 received = bal0After - bal0Before;
        require(spent == amountIn, "Token1 should decrease by exact input amount");
        require(received == expectedOut, "Received amount should match quote");

        console.log("  spent:", spent);
        console.log("  received:", received);
        console.log("test_swapExactInput_OneForZero PASS");
    }

    // ──────────────────── Test: Exact-Output 0→1 ────────────────────

    function test_swapExactOutput_ZeroForOne() public {
        _loadConfig();
        console.log("");
        console.log("--- test_swapExactOutput_ZeroForOne ---");

        uint256 amountOut = SWAP_AMOUNT;

        vm.startBroadcast(deployerKey);
        uint256 expectedIn = hook.quote(true, int256(amountOut), poolId);
        vm.stopBroadcast();
        require(expectedIn > 0, "Quote should return non-zero");

        uint256 bal0Before = IERC20(token0).balanceOf(deployer);
        uint256 bal1Before = IERC20(token1).balanceOf(deployer);

        vm.startBroadcast(deployerKey);
        router.swap(
            poolKey,
            SwapParams({zeroForOne: true, amountSpecified: int256(amountOut), sqrtPriceLimitX96: MIN_PRICE_LIMIT}),
            SafePoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
        vm.stopBroadcast();

        uint256 bal0After = IERC20(token0).balanceOf(deployer);
        uint256 bal1After = IERC20(token1).balanceOf(deployer);

        uint256 spent = bal0Before - bal0After;
        uint256 received = bal1After - bal1Before;
        require(received == amountOut, "Token1 received should match exact output amount");
        require(spent == expectedIn, "Token0 spent should match quote");

        console.log("  spent:", spent);
        console.log("  received:", received);
        console.log("test_swapExactOutput_ZeroForOne PASS");
    }

    // ──────────────────── Test: Exact-Output 1→0 ────────────────────

    function test_swapExactOutput_OneForZero() public {
        _loadConfig();
        console.log("");
        console.log("--- test_swapExactOutput_OneForZero ---");

        uint256 amountOut = SWAP_AMOUNT;

        vm.startBroadcast(deployerKey);
        uint256 expectedIn = hook.quote(false, int256(amountOut), poolId);
        vm.stopBroadcast();
        require(expectedIn > 0, "Quote should return non-zero");

        uint256 bal0Before = IERC20(token0).balanceOf(deployer);
        uint256 bal1Before = IERC20(token1).balanceOf(deployer);

        vm.startBroadcast(deployerKey);
        router.swap(
            poolKey,
            SwapParams({zeroForOne: false, amountSpecified: int256(amountOut), sqrtPriceLimitX96: MAX_PRICE_LIMIT}),
            SafePoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
        vm.stopBroadcast();

        uint256 bal0After = IERC20(token0).balanceOf(deployer);
        uint256 bal1After = IERC20(token1).balanceOf(deployer);

        uint256 spent = bal1Before - bal1After;
        uint256 received = bal0After - bal0Before;
        require(received == amountOut, "Token0 received should match exact output amount");
        require(spent == expectedIn, "Token1 spent should match quote");

        console.log("  spent:", spent);
        console.log("  received:", received);
        console.log("test_swapExactOutput_OneForZero PASS");
    }

    // ──────────────────── Test: Multiple Swaps ────────────────────

    function test_multipleSwaps() public {
        _loadConfig();
        console.log("");
        console.log("--- test_multipleSwaps ---");

        uint256 amount = SWAP_AMOUNT / 2;

        // Swap 1: Token0 → Token1 (exact-input)
        vm.startBroadcast(deployerKey);
        router.swap(
            poolKey,
            SwapParams({zeroForOne: true, amountSpecified: -int256(amount), sqrtPriceLimitX96: MIN_PRICE_LIMIT}),
            SafePoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
        vm.stopBroadcast();
        console.log("  swap 1 OK (token0 -> token1, exact-input)");

        // Swap 2: Token1 → Token0 (exact-input)
        vm.startBroadcast(deployerKey);
        router.swap(
            poolKey,
            SwapParams({zeroForOne: false, amountSpecified: -int256(amount), sqrtPriceLimitX96: MAX_PRICE_LIMIT}),
            SafePoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
        vm.stopBroadcast();
        console.log("  swap 2 OK (token1 -> token0, exact-input)");

        // Swap 3: Token0 → Token1 (exact-output)
        vm.startBroadcast(deployerKey);
        router.swap(
            poolKey,
            SwapParams({zeroForOne: true, amountSpecified: int256(amount / 2), sqrtPriceLimitX96: MIN_PRICE_LIMIT}),
            SafePoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
        vm.stopBroadcast();
        console.log("  swap 3 OK (token0 -> token1, exact-output)");

        console.log("test_multipleSwaps PASS");
    }

    // ──────────────────── Test: Large Swap ────────────────────

    function test_swapLargeAmount() public {
        _loadConfig();
        console.log("");
        console.log("--- test_swapLargeAmount ---");

        uint256 largeAmount = 5 * 10 ** DECIMALS;

        vm.startBroadcast(deployerKey);
        uint256 expectedOut = hook.quote(true, -int256(largeAmount), poolId);
        vm.stopBroadcast();
        require(expectedOut > 0, "Quote should return non-zero for large amount");

        uint256 bal1Before = IERC20(token1).balanceOf(deployer);

        vm.startBroadcast(deployerKey);
        router.swap(
            poolKey,
            SwapParams({zeroForOne: true, amountSpecified: -int256(largeAmount), sqrtPriceLimitX96: MIN_PRICE_LIMIT}),
            SafePoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
        vm.stopBroadcast();

        uint256 received = IERC20(token1).balanceOf(deployer) - bal1Before;
        require(received == expectedOut, "Large swap output should match quote");

        console.log("  received:", received);
        console.log("test_swapLargeAmount PASS");
    }

    // ──────────────────── Test: Quote ────────────────────

    function test_quote() public {
        _loadConfig();
        console.log("");
        console.log("--- test_quote ---");

        uint256 amountIn = SWAP_AMOUNT;

        vm.startBroadcast(deployerKey);
        uint256 expectedOut = hook.quote(true, -int256(amountIn), poolId);
        vm.stopBroadcast();

        require(expectedOut > 0, "Quote should return non-zero");
        // For stablecoins, output should be close to input (accounting for fees)
        require(expectedOut > amountIn * 95 / 100, "Quote should be within 5% for stablecoins");

        console.log("  amountIn:", amountIn);
        console.log("  expectedOut:", expectedOut);
        console.log("test_quote PASS");
    }

    // ──────────────────── Test: Pseudo TVL ────────────────────

    /// @notice View-only test — no broadcast needed.
    function test_pseudoTotalValueLocked() public {
        _loadConfig();
        console.log("");
        console.log("--- test_pseudoTotalValueLocked ---");

        (uint256 amount0, uint256 amount1) = hook.pseudoTotalValueLocked(poolId);

        uint256 expected0 = IERC20(token0).balanceOf(address(exchange));
        uint256 expected1 = IERC20(token1).balanceOf(address(exchange));

        require(amount0 == expected0, "TVL token0 should match Tempo balance");
        require(amount1 == expected1, "TVL token1 should match Tempo balance");

        console.log("  tvl0:", amount0);
        console.log("  tvl1:", amount1);
        console.log("test_pseudoTotalValueLocked PASS");
    }

    // ──────────────────── Run All ────────────────────

    function run() external {
        fund();
        test_swapExactInput_ZeroForOne();
        test_swapExactInput_OneForZero();
        test_swapExactOutput_ZeroForOne();
        test_swapExactOutput_OneForZero();
        test_multipleSwaps();
        test_swapLargeAmount();
        test_quote();
        test_pseudoTotalValueLocked();

        console.log("");
        console.log("=== ALL TESTS PASSED ===");
    }
}
