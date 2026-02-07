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
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {HookMiner} from "@uniswap/v4-periphery/src/utils/HookMiner.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {
    TempoExchangeAggregator
} from "../../../src/aggregator-hooks/implementations/TempoExchange/TempoExchangeAggregator.sol";
import {
    ITempoExchange
} from "../../../src/aggregator-hooks/implementations/TempoExchange/interfaces/ITempoExchange.sol";

/// @title TempoExchangeForkedTest
/// @notice Fork tests for Tempo Exchange aggregator hook against live Tempo chain
/// @dev Requires TEMPO_RPC_URL environment variable to be set
/// @dev Requires TEMPO_POOL_MANAGER to be set (or deploys a new one)
/// @dev Requires TEMPO_TOKEN_0 and TEMPO_TOKEN_1 for the token pair to test
contract TempoExchangeForkedTest is Test {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;
    using StateLibrary for IPoolManager;
    using SafeERC20 for IERC20;

    // Tempo Exchange precompile address
    address constant TEMPO_EXCHANGE_ADDRESS = 0xDEc0000000000000000000000000000000000000;

    // Pool configuration
    uint24 constant POOL_FEE = 500; // 0.05%
    int24 constant TICK_SPACING = 10;
    uint160 constant SQRT_PRICE_1_1 = 79_228_162_514_264_337_593_543_950_336; // 1:1 price

    // Price limits for swaps
    uint160 constant MIN_PRICE_LIMIT = TickMath.MIN_SQRT_PRICE + 1;
    uint160 constant MAX_PRICE_LIMIT = TickMath.MAX_SQRT_PRICE - 1;

    // Loaded from environment
    address token0Address;
    address token1Address;
    uint8 token0Decimals;
    uint8 token1Decimals;

    // Test amounts - set dynamically based on token decimals
    uint256 swapAmount0;
    uint256 swapAmount1;
    uint256 initialBalance0;
    uint256 initialBalance1;

    IPoolManager public manager;
    SafePoolSwapTest public swapRouter;
    TempoExchangeAggregator public hook;
    ITempoExchange public tempoExchange;

    PoolKey public poolKey;
    PoolId public poolId;

    Currency public currency0;
    Currency public currency1;

    address public alice;

    function setUp() public {
        // Load RPC URL - skip test if not set
        string memory rpcUrl;
        try vm.envString("TEMPO_RPC_URL") returns (string memory url) {
            rpcUrl = url;
        } catch {
            vm.skip(true);
            return;
        }

        vm.createSelectFork(rpcUrl);

        // Create alice address
        alice = address(uint160(uint256(keccak256("tempo_test_alice_v1"))));

        // Load Tempo Exchange (precompile)
        tempoExchange = ITempoExchange(TEMPO_EXCHANGE_ADDRESS);

        // Load token addresses from environment
        token0Address = vm.envAddress("TEMPO_TOKEN_0");
        token1Address = vm.envAddress("TEMPO_TOKEN_1");

        // Ensure correct ordering for v4
        if (token0Address > token1Address) {
            (token0Address, token1Address) = (token1Address, token0Address);
        }

        currency0 = Currency.wrap(token0Address);
        currency1 = Currency.wrap(token1Address);

        // Get token decimals
        token0Decimals = IERC20Metadata(token0Address).decimals();
        token1Decimals = IERC20Metadata(token1Address).decimals();

        // Set test amounts based on decimals
        swapAmount0 = 1000 * (10 ** token0Decimals);
        swapAmount1 = 1000 * (10 ** token1Decimals);
        initialBalance0 = 100_000 * (10 ** token0Decimals);
        initialBalance1 = 100_000 * (10 ** token1Decimals);

        // Deploy or use existing PoolManager
        try vm.envAddress("TEMPO_POOL_MANAGER") returns (address pmAddr) {
            manager = IPoolManager(pmAddr);
        } catch {
            manager = new PoolManager(address(0));
        }

        // Deploy swap router
        swapRouter = new SafePoolSwapTest(manager);

        // Deploy hook
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

        // Deal tokens to alice for testing
        deal(token0Address, alice, initialBalance0);
        deal(token1Address, alice, initialBalance1);

        // Approve swap router for alice
        vm.startPrank(alice);
        IERC20(token0Address).forceApprove(address(swapRouter), type(uint256).max);
        IERC20(token1Address).forceApprove(address(swapRouter), type(uint256).max);
        vm.stopPrank();
    }

    function _deployHook() internal {
        uint160 flags =
            uint160(Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG | Hooks.BEFORE_INITIALIZE_FLAG);

        bytes memory constructorArgs = abi.encode(address(manager), address(tempoExchange));
        (address hookAddress, bytes32 salt) =
            HookMiner.find(address(this), flags, type(TempoExchangeAggregator).creationCode, constructorArgs);

        hook = new TempoExchangeAggregator{salt: salt}(manager, tempoExchange);
        require(address(hook) == hookAddress, "Hook address mismatch");
    }

    // ========== SWAP TESTS ==========

    /// @notice Test exact input swap: Token0 -> Token1 (zero to one)
    function test_swapExactInput_ZeroForOne() public {
        uint256 amountIn = swapAmount0;

        // Get quote before swap
        uint256 expectedOut = hook.quote(true, -int256(amountIn), poolId);
        assertGt(expectedOut, 0, "Quote should return non-zero");

        uint256 token0Before = IERC20(token0Address).balanceOf(alice);
        uint256 token1Before = IERC20(token1Address).balanceOf(alice);

        vm.prank(alice);
        swapRouter.swap(
            poolKey,
            SwapParams({zeroForOne: true, amountSpecified: -int256(amountIn), sqrtPriceLimitX96: MIN_PRICE_LIMIT}),
            SafePoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );

        uint256 token0After = IERC20(token0Address).balanceOf(alice);
        uint256 token1After = IERC20(token1Address).balanceOf(alice);

        assertEq(token0Before - token0After, amountIn, "Token0 should decrease by exact input amount");

        uint256 received = token1After - token1Before;
        assertEq(received, expectedOut, "Received amount should match quote");
    }

    /// @notice Test exact input swap: Token1 -> Token0 (one to zero)
    function test_swapExactInput_OneForZero() public {
        uint256 amountIn = swapAmount1;

        // Get quote before swap
        uint256 expectedOut = hook.quote(false, -int256(amountIn), poolId);
        assertGt(expectedOut, 0, "Quote should return non-zero");

        uint256 token0Before = IERC20(token0Address).balanceOf(alice);
        uint256 token1Before = IERC20(token1Address).balanceOf(alice);

        vm.prank(alice);
        swapRouter.swap(
            poolKey,
            SwapParams({zeroForOne: false, amountSpecified: -int256(amountIn), sqrtPriceLimitX96: MAX_PRICE_LIMIT}),
            SafePoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );

        uint256 token0After = IERC20(token0Address).balanceOf(alice);
        uint256 token1After = IERC20(token1Address).balanceOf(alice);

        assertEq(token1Before - token1After, amountIn, "Token1 should decrease by exact input amount");

        uint256 received = token0After - token0Before;
        assertEq(received, expectedOut, "Received amount should match quote");
    }

    /// @notice Test exact output swap: Token0 -> Token1 (zero to one)
    function test_swapExactOutput_ZeroForOne() public {
        uint256 amountOut = swapAmount1;

        // Get quote for expected input amount
        uint256 expectedIn = hook.quote(true, int256(amountOut), poolId);
        assertGt(expectedIn, 0, "Quote should return non-zero");

        uint256 token0Before = IERC20(token0Address).balanceOf(alice);
        uint256 token1Before = IERC20(token1Address).balanceOf(alice);

        vm.prank(alice);
        swapRouter.swap(
            poolKey,
            SwapParams({zeroForOne: true, amountSpecified: int256(amountOut), sqrtPriceLimitX96: MIN_PRICE_LIMIT}),
            SafePoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );

        uint256 token0After = IERC20(token0Address).balanceOf(alice);
        uint256 token1After = IERC20(token1Address).balanceOf(alice);

        uint256 token1Received = token1After - token1Before;
        assertEq(token1Received, amountOut, "Token1 received should match exact output amount");

        uint256 token0Spent = token0Before - token0After;
        assertEq(token0Spent, expectedIn, "Token0 spent should match quote");
    }

    /// @notice Test exact output swap: Token1 -> Token0 (one to zero)
    function test_swapExactOutput_OneForZero() public {
        uint256 amountOut = swapAmount0;

        // Get quote for expected input amount
        uint256 expectedIn = hook.quote(false, int256(amountOut), poolId);
        assertGt(expectedIn, 0, "Quote should return non-zero");

        uint256 token0Before = IERC20(token0Address).balanceOf(alice);
        uint256 token1Before = IERC20(token1Address).balanceOf(alice);

        vm.prank(alice);
        swapRouter.swap(
            poolKey,
            SwapParams({zeroForOne: false, amountSpecified: int256(amountOut), sqrtPriceLimitX96: MAX_PRICE_LIMIT}),
            SafePoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );

        uint256 token0After = IERC20(token0Address).balanceOf(alice);
        uint256 token1After = IERC20(token1Address).balanceOf(alice);

        uint256 token0Received = token0After - token0Before;
        assertEq(token0Received, amountOut, "Token0 received should match exact output amount");

        uint256 token1Spent = token1Before - token1After;
        assertEq(token1Spent, expectedIn, "Token1 spent should match quote");
    }

    // ========== ADDITIONAL TESTS ==========

    /// @notice Test multiple consecutive swaps
    function test_multipleSwaps() public {
        uint256 amount0 = swapAmount0 / 2;
        uint256 amount1 = swapAmount1 / 2;

        // First swap: Token0 -> Token1
        vm.prank(alice);
        swapRouter.swap(
            poolKey,
            SwapParams({zeroForOne: true, amountSpecified: -int256(amount0), sqrtPriceLimitX96: MIN_PRICE_LIMIT}),
            SafePoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );

        // Second swap: Token1 -> Token0
        vm.prank(alice);
        swapRouter.swap(
            poolKey,
            SwapParams({zeroForOne: false, amountSpecified: -int256(amount1), sqrtPriceLimitX96: MAX_PRICE_LIMIT}),
            SafePoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );

        // Third swap: exact output
        vm.prank(alice);
        swapRouter.swap(
            poolKey,
            SwapParams({zeroForOne: true, amountSpecified: int256(amount1 / 2), sqrtPriceLimitX96: MIN_PRICE_LIMIT}),
            SafePoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
    }

    /// @notice Test large swap amount
    function test_swapLargeAmount() public {
        uint256 largeAmount = 50_000 * (10 ** token0Decimals);

        // Ensure alice has enough tokens
        deal(token0Address, alice, largeAmount * 2);

        uint256 expectedOut = hook.quote(true, -int256(largeAmount), poolId);
        assertGt(expectedOut, 0, "Quote should return non-zero for large amount");

        uint256 token1Before = IERC20(token1Address).balanceOf(alice);

        vm.prank(alice);
        swapRouter.swap(
            poolKey,
            SwapParams({zeroForOne: true, amountSpecified: -int256(largeAmount), sqrtPriceLimitX96: MIN_PRICE_LIMIT}),
            SafePoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );

        uint256 token1Received = IERC20(token1Address).balanceOf(alice) - token1Before;
        assertEq(token1Received, expectedOut, "Large swap output should match quote");
    }

    /// @notice Verify quote returns reasonable values for stablecoins
    function test_quote() public {
        uint256 amountIn = swapAmount0;

        uint256 expectedOut = hook.quote(true, -int256(amountIn), poolId);

        assertGt(expectedOut, 0, "Quote should return non-zero");
        // For stablecoins, output should be close to input (accounting for fees)
        assertGt(expectedOut, amountIn * 95 / 100, "Quote should be within 5% for stablecoins");
    }

    /// @notice Test pseudoTotalValueLocked returns Tempo exchange balances
    function test_pseudoTotalValueLocked() public view {
        (uint256 amount0, uint256 amount1) = hook.pseudoTotalValueLocked(poolId);

        // Should match token balances of Tempo exchange
        uint256 expectedAmount0 = IERC20(token0Address).balanceOf(address(tempoExchange));
        uint256 expectedAmount1 = IERC20(token1Address).balanceOf(address(tempoExchange));

        assertEq(amount0, expectedAmount0, "TVL token0 should match Tempo balance");
        assertEq(amount1, expectedAmount1, "TVL token1 should match Tempo balance");
    }

    receive() external payable {}
}
