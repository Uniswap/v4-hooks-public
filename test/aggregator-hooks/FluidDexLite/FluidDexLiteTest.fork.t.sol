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
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {SafePoolSwapTest} from "../shared/SafePoolSwapTest.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {HookMiner} from "@uniswap/v4-periphery/src/utils/HookMiner.sol";
import {CustomRevert} from "@uniswap/v4-core/src/libraries/CustomRevert.sol";
import {
    FluidDexLiteAggregator
} from "../../../src/aggregator-hooks/implementations/FluidDexLite/FluidDexLiteAggregator.sol";
import {IFluidDexLite} from "../../../src/aggregator-hooks/implementations/FluidDexLite/interfaces/IFluidDexLite.sol";
import {
    IFluidDexLiteResolver
} from "../../../src/aggregator-hooks/implementations/FluidDexLite/interfaces/IFluidDexLiteResolver.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

/// @title FluidDexLiteERCForkedTest
/// @notice Tests for Fluid DEX Lite with ERC20 token pairs (no native ETH)
contract FluidDexLiteERCForkedTest is Test {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;
    using StateLibrary for IPoolManager;
    using SafeERC20 for IERC20;

    // Pool configuration
    uint24 constant POOL_FEE = 500; // 0.05%
    int24 constant TICK_SPACING = 10;
    uint160 constant SQRT_PRICE_1_1 = 79_228_162_514_264_337_593_543_950_336; // 1:1 price

    // Price limits for swaps
    uint160 constant MIN_PRICE_LIMIT = TickMath.MIN_SQRT_PRICE + 1;
    uint160 constant MAX_PRICE_LIMIT = TickMath.MAX_SQRT_PRICE - 1;

    // Loaded from .env
    address fluidDexLiteAddress;
    address fluidDexLiteResolverAddress;
    bytes32 dexSalt;
    address token0Address;
    address token1Address;
    uint8 token0Decimals;
    uint8 token1Decimals;

    // Test amounts - set dynamically based on token decimals
    uint256 swapAmount0; // Amount for token0 swaps (in token0 decimals)
    uint256 swapAmount1; // Amount for token1 swaps (in token1 decimals)
    uint256 initialBalance0;
    uint256 initialBalance1;

    IPoolManager public manager;
    SafePoolSwapTest public swapRouter;
    FluidDexLiteAggregator public hook;
    IFluidDexLite public fluidDexLite;
    IFluidDexLiteResolver public fluidDexLiteResolver;

    PoolKey public poolKey;
    PoolId public poolId;

    Currency public currency0;
    Currency public currency1;

    address public alice;

    function setUp() public {
        string memory rpcUrl = vm.envString("MAINNET_RPC_URL");
        address poolManagerAddress = vm.envAddress("POOL_MANAGER");
        fluidDexLiteAddress = vm.envAddress("FLUID_DEX_LITE");
        fluidDexLiteResolverAddress = vm.envAddress("FLUID_DEX_LITE_RESOLVER");
        dexSalt = vm.envBytes32("FLUID_DEX_LITE_SALT_ERC");
        token0Address = vm.envAddress("FLUID_DEX_LITE_TOKEN0_ERC");
        token1Address = vm.envAddress("FLUID_DEX_LITE_TOKEN1_ERC");

        vm.createSelectFork(rpcUrl);

        // Create alice address that doesn't have code on mainnet
        alice = address(uint160(uint256(keccak256("fluid_lite_test_alice_erc_v1"))));

        fluidDexLite = IFluidDexLite(fluidDexLiteAddress);
        fluidDexLiteResolver = IFluidDexLiteResolver(fluidDexLiteResolverAddress);

        // Ensure tokens are ordered correctly for v4 (lower address = currency0)
        if (token0Address > token1Address) {
            (token0Address, token1Address) = (token1Address, token0Address);
        }

        currency0 = Currency.wrap(token0Address);
        currency1 = Currency.wrap(token1Address);

        // Get token decimals and set appropriate test amounts for each token
        token0Decimals = IERC20Metadata(token0Address).decimals();
        token1Decimals = IERC20Metadata(token1Address).decimals();

        // Use token-specific amounts to handle different decimal tokens
        swapAmount0 = 10 * (10 ** token0Decimals); // 1000 tokens in token0 decimals
        swapAmount1 = 10 * (10 ** token1Decimals); // 1000 tokens in token1 decimals
        initialBalance0 = 100_000 * (10 ** token0Decimals); // 100k tokens in token0 decimals
        initialBalance1 = 100_000 * (10 ** token1Decimals); // 100k tokens in token1 decimals

        manager = PoolManager(poolManagerAddress);

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

        // Deal tokens to alice for testing
        deal(token0Address, alice, initialBalance0);
        deal(token1Address, alice, initialBalance1);

        // Approve swap router for alice (use forceApprove for non-standard tokens like USDT)
        vm.startPrank(alice);
        IERC20(token0Address).forceApprove(address(swapRouter), type(uint256).max);
        IERC20(token1Address).forceApprove(address(swapRouter), type(uint256).max);
        vm.stopPrank();
    }

    function _deployHook() internal {
        // Hook flags required by ExternalLiqSourceHook:
        uint160 flags =
            uint160(Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG | Hooks.BEFORE_INITIALIZE_FLAG);

        bytes memory constructorArgs =
            abi.encode(address(manager), address(fluidDexLite), address(fluidDexLiteResolver), dexSalt);
        (address hookAddress, bytes32 salt) =
            HookMiner.find(address(this), flags, type(FluidDexLiteAggregator).creationCode, constructorArgs);

        hook = new FluidDexLiteAggregator{salt: salt}(manager, fluidDexLite, fluidDexLiteResolver, dexSalt);
        require(address(hook) == hookAddress, "Hook address mismatch");
    }

    // ========== SWAP TESTS ==========

    /// @notice Test exact input swap: Token0 -> Token1 (zero to one)
    function test_swapExactInput_ZeroForOne() public {
        uint256 amountIn = swapAmount0; // Use token0 amount since we're paying token0

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
        uint256 amountIn = swapAmount1; // Use token1 amount since we're paying token1

        // Get quote before swap
        uint256 expectedOut = hook.quote(false, -int256(amountIn), poolId);

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
        uint256 amountOut = swapAmount1; // Use token1 amount since we're receiving token1

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
        uint256 amountOut = swapAmount0; // Use token0 amount since we're receiving token0

        // Get quote for expected input amount
        uint256 expectedIn = hook.quote(false, int256(amountOut), poolId);

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

    /// @notice Test that multiple swaps work correctly
    function test_multipleSwaps() public {
        // First swap: Token0 -> Token1 (exact input)
        vm.prank(alice);
        swapRouter.swap(
            poolKey,
            SwapParams({
                zeroForOne: true, amountSpecified: -int256(swapAmount0 / 2), sqrtPriceLimitX96: MIN_PRICE_LIMIT
            }),
            SafePoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );

        // Second swap: Token1 -> Token0 (exact input)
        vm.prank(alice);
        swapRouter.swap(
            poolKey,
            SwapParams({
                zeroForOne: false, amountSpecified: -int256(swapAmount1 / 2), sqrtPriceLimitX96: MAX_PRICE_LIMIT
            }),
            SafePoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );

        // Third swap: exact output (receive token1)
        vm.prank(alice);
        swapRouter.swap(
            poolKey,
            SwapParams({
                zeroForOne: true, amountSpecified: int256(swapAmount1 / 4), sqrtPriceLimitX96: MIN_PRICE_LIMIT
            }),
            SafePoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
    }

    /// @notice Verify quote function returns reasonable values
    function test_quote() public {
        uint256 amountIn = swapAmount0; // Quote for zeroForOne (paying token0)

        uint256 expectedOut = hook.quote(true, -int256(amountIn), poolId);

        assertGt(expectedOut, 0, "Quote should return non-zero");
    }

    receive() external payable {}
}

contract FluidDexLiteNativeForkedTest is Test {
    // NOTE: No native ETH pools are currently available on Fluid DEX Lite.
    // TODO: Native tests can be added when a native pool is deployed.

    }
