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
import {FluidDexT1Aggregator} from "../../../src/aggregator-hooks/implementations/FluidDexT1/FluidDexT1Aggregator.sol";
import {IFluidDexT1} from "../../../src/aggregator-hooks/implementations/FluidDexT1/interfaces/IFluidDexT1.sol";
import {
    IFluidDexReservesResolver
} from "../../../src/aggregator-hooks/implementations/FluidDexT1/interfaces/IFluidDexT1Resolver.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

/// @title FluidDexT1ERCForkedTest
/// @notice Tests for Fluid DEX T1 with ERC20 token pairs (no native ETH)
contract FluidDexT1ERCForkedTest is Test {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;
    using StateLibrary for IPoolManager;
    using SafeERC20 for IERC20;

    // Fluid infrastructure addresses (mainnet)
    address constant FLUID_LIQUIDITY = 0x52Aa899454998Be5b000Ad077a46Bbe360F4e497;
    address constant FLUID_DEX_RESERVES_RESOLVER = 0x11D80CfF056Cef4F9E6d23da8672fE9873e5cC07;

    // Pool configuration
    uint24 constant POOL_FEE = 500; // 0.05%
    int24 constant TICK_SPACING = 10;
    uint160 constant SQRT_PRICE_1_1 = 79_228_162_514_264_337_593_543_950_336; // 1:1 price

    // Price limits for swaps
    uint160 constant MIN_PRICE_LIMIT = TickMath.MIN_SQRT_PRICE + 1;
    uint160 constant MAX_PRICE_LIMIT = TickMath.MAX_SQRT_PRICE - 1;

    // Loaded from .env
    address fluidPoolAddress;
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
    FluidDexT1Aggregator public hook;
    IFluidDexT1 public fluidPool;
    IFluidDexReservesResolver public fluidResolver;

    PoolKey public poolKey;
    PoolId public poolId;

    Currency public currency0;
    Currency public currency1;

    address public alice;

    function setUp() public {
        // Fork mainnet - requires MAINNET_RPC_URL env var
        string memory rpcUrl = vm.envString("MAINNET_RPC_URL");
        vm.createSelectFork(rpcUrl);

        // Create alice address that doesn't have code on mainnet
        alice = address(uint160(uint256(keccak256("fluid_test_alice_erc_v1"))));

        // Load ERC pool address from .env
        fluidPoolAddress = vm.envAddress("FLUID_DEX_T1_POOL_ERC");
        fluidPool = IFluidDexT1(fluidPoolAddress);
        fluidResolver = IFluidDexReservesResolver(FLUID_DEX_RESERVES_RESOLVER);

        // Dynamically fetch tokens from the pool via resolver
        (address fluidToken0, address fluidToken1) = fluidResolver.getDexTokens(fluidPoolAddress);

        // Order tokens correctly for v4 (lower address = currency0)
        if (fluidToken0 < fluidToken1) {
            token0Address = fluidToken0;
            token1Address = fluidToken1;
        } else {
            token0Address = fluidToken1;
            token1Address = fluidToken0;
        }

        currency0 = Currency.wrap(token0Address);
        currency1 = Currency.wrap(token1Address);

        // Get token decimals and set appropriate test amounts for each token
        token0Decimals = IERC20Metadata(token0Address).decimals();
        token1Decimals = IERC20Metadata(token1Address).decimals();

        // Use token-specific amounts to handle different decimal tokens (e.g., GHO 18 decimals, USDC 6 decimals)
        swapAmount0 = 1000 * (10 ** token0Decimals); // 1000 tokens in token0 decimals
        swapAmount1 = 1000 * (10 ** token1Decimals); // 1000 tokens in token1 decimals
        initialBalance0 = 100_000 * (10 ** token0Decimals); // 100k tokens in token0 decimals
        initialBalance1 = 100_000 * (10 ** token1Decimals); // 100k tokens in token1 decimals

        // Use deployed PoolManager
        address poolManagerAddress = vm.envAddress("POOL_MANAGER");
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
            abi.encode(address(manager), address(fluidPool), address(fluidResolver), FLUID_LIQUIDITY);
        (address hookAddress, bytes32 salt) =
            HookMiner.find(address(this), flags, type(FluidDexT1Aggregator).creationCode, constructorArgs);

        hook = new FluidDexT1Aggregator{salt: salt}(manager, fluidPool, fluidResolver, FLUID_LIQUIDITY);
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
        // Fluid's exactOut can be off by 1 wei
        assertApproxEqAbs(token1Received, amountOut, 1, "Token1 received should match exact output amount");

        uint256 token0Spent = token0Before - token0After;
        assertEq(token0Spent, expectedIn, "Token0 spent should match quote");
    }

    /// @notice Test exact output swap: Token1 -> Token0 (one to zero)
    function test_swapExactOutput_OneForZero() public {
        uint256 amountOut = swapAmount0; // Use token0 amount since we're receiving token0

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
        // Fluid's exactOut can be off by 1 wei
        assertApproxEqAbs(token0Received, amountOut, 1, "Token0 received should match exact output amount");

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

/// @title FluidDexT1NativeForkedTest
/// @notice Tests for Fluid DEX T1 with native ETH token pairs
/// @dev Native ETH is always currency0 (address(0) is the lowest address)
contract FluidDexT1NativeForkedTest is Test {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;
    using StateLibrary for IPoolManager;

    // Fluid's native currency representation
    address constant FLUID_NATIVE_CURRENCY = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;

    // Fluid infrastructure addresses (mainnet)
    address constant FLUID_LIQUIDITY = 0x52Aa899454998Be5b000Ad077a46Bbe360F4e497;
    address constant FLUID_DEX_RESERVES_RESOLVER = 0x11D80CfF056Cef4F9E6d23da8672fE9873e5cC07;

    // Pool configuration
    uint24 constant POOL_FEE = 500; // 0.05%
    int24 constant TICK_SPACING = 10;
    uint160 constant SQRT_PRICE_1_1 = 79_228_162_514_264_337_593_543_950_336; // 1:1 price

    // Price limits for swaps
    uint160 constant MIN_PRICE_LIMIT = TickMath.MIN_SQRT_PRICE + 1;
    uint160 constant MAX_PRICE_LIMIT = TickMath.MAX_SQRT_PRICE - 1;

    // Loaded from .env
    address fluidPoolAddress;
    address ercTokenAddress; // The ERC20 token in the pair (not native)

    // Test amounts (in 18 decimals)
    uint256 constant SWAP_AMOUNT = 1 ether;
    uint256 constant INITIAL_BALANCE = 100 ether;

    IPoolManager public manager;
    SafePoolSwapTest public swapRouter;
    FluidDexT1Aggregator public hook;
    IFluidDexT1 public fluidPool;
    IFluidDexReservesResolver public fluidResolver;

    PoolKey public poolKey;
    PoolId public poolId;

    // currency0 = Native ETH (address(0)), currency1 = ERC20 token
    Currency public currency0;
    Currency public currency1;

    address public alice;

    function setUp() public {
        // Fork mainnet - requires MAINNET_RPC_URL env var
        string memory rpcUrl = vm.envString("MAINNET_RPC_URL");
        vm.createSelectFork(rpcUrl);

        // Create alice address that doesn't have code on mainnet
        alice = address(uint160(uint256(keccak256("fluid_test_alice_native_v1"))));

        // Load native pool address from .env
        fluidPoolAddress = vm.envAddress("FLUID_DEX_T1_POOL_NATIVE");
        fluidPool = IFluidDexT1(fluidPoolAddress);
        fluidResolver = IFluidDexReservesResolver(FLUID_DEX_RESERVES_RESOLVER);

        // Dynamically fetch tokens from the pool via resolver
        (address fluidToken0, address fluidToken1) = fluidResolver.getDexTokens(fluidPoolAddress);

        // Identify which token is native and which is ERC20
        // Native should always be token1 in fluid
        if (fluidToken1 == FLUID_NATIVE_CURRENCY) {
            ercTokenAddress = fluidToken0;
        } else {
            revert("Pool does not contain native token");
        }

        // Native ETH (address(0)) is always currency0 (lowest address)
        currency0 = Currency.wrap(address(0));
        currency1 = Currency.wrap(ercTokenAddress);

        // Use mainnet PoolManager
        manager = PoolManager(address(0x000000000004444c5dc75cB358380D2e3dE08A90));

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
        vm.deal(alice, INITIAL_BALANCE);
        deal(ercTokenAddress, alice, INITIAL_BALANCE);

        // Approve swap router for alice (only ERC20 token needs approval)
        vm.startPrank(alice);
        IERC20(ercTokenAddress).approve(address(swapRouter), type(uint256).max);
        vm.stopPrank();
    }

    function _deployHook() internal {
        // Hook flags required by ExternalLiqSourceHook:
        uint160 flags =
            uint160(Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG | Hooks.BEFORE_INITIALIZE_FLAG);

        bytes memory constructorArgs =
            abi.encode(address(manager), address(fluidPool), address(fluidResolver), FLUID_LIQUIDITY);
        (address hookAddress, bytes32 salt) =
            HookMiner.find(address(this), flags, type(FluidDexT1Aggregator).creationCode, constructorArgs);

        hook = new FluidDexT1Aggregator{salt: salt}(manager, fluidPool, fluidResolver, FLUID_LIQUIDITY);
        require(address(hook) == hookAddress, "Hook address mismatch");
    }

    // ========== NATIVE TOKEN SWAP TESTS ==========

    /// @notice Test exact input swap: Native ETH in -> ERC20 out (zeroForOne)
    function test_nativeIn_exactIn() public {
        uint256 amountIn = SWAP_AMOUNT;

        // Get quote before swap
        uint256 expectedOut = hook.quote(true, -int256(amountIn), poolId);
        assertGt(expectedOut, 0, "Quote should return non-zero");

        uint256 ethBefore = alice.balance;
        uint256 ercBefore = IERC20(ercTokenAddress).balanceOf(alice);

        vm.prank(alice);
        swapRouter.swap{value: amountIn}(
            poolKey,
            SwapParams({zeroForOne: true, amountSpecified: -int256(amountIn), sqrtPriceLimitX96: MIN_PRICE_LIMIT}),
            SafePoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );

        uint256 ethAfter = alice.balance;
        uint256 ercAfter = IERC20(ercTokenAddress).balanceOf(alice);

        // ETH should decrease by approximately the input amount (small variance allowed for native handling)
        uint256 ethSpent = ethBefore - ethAfter;
        assertApproxEqRel(ethSpent, amountIn, 0.001e18, "ETH spent should be close to input amount");

        // Should receive ERC20 tokens matching quote (allow 0.1% variance)
        uint256 ercReceived = ercAfter - ercBefore;
        assertApproxEqRel(ercReceived, expectedOut, 0.001e18, "Received amount should be close to quote");
    }

    /// @notice Test exact input swap: ERC20 in -> Native ETH out (oneForZero)
    function test_nativeOut_exactIn() public {
        uint256 amountIn = SWAP_AMOUNT;

        // Get quote before swap
        uint256 expectedOut = hook.quote(false, -int256(amountIn), poolId);
        assertGt(expectedOut, 0, "Quote should return non-zero");

        uint256 ethBefore = alice.balance;
        uint256 ercBefore = IERC20(ercTokenAddress).balanceOf(alice);

        vm.prank(alice);
        swapRouter.swap(
            poolKey,
            SwapParams({zeroForOne: false, amountSpecified: -int256(amountIn), sqrtPriceLimitX96: MAX_PRICE_LIMIT}),
            SafePoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );

        uint256 ethAfter = alice.balance;
        uint256 ercAfter = IERC20(ercTokenAddress).balanceOf(alice);

        // ERC20 should decrease by exact input amount
        assertEq(ercBefore - ercAfter, amountIn, "ERC20 should decrease by exact input amount");

        // Should receive ETH close to quote (allow 0.1% variance for state changes between quote and swap)
        uint256 ethReceived = ethAfter - ethBefore;
        assertApproxEqRel(ethReceived, expectedOut, 0.001e18, "ETH received should be close to quote");
    }

    /// @notice Test exact output swap: Native ETH in -> ERC20 out (zeroForOne) - SHOULD REVERT
    /// @dev Native currency exact output is not supported because we can't know how much ETH to send upfront
    function test_nativeIn_exactOut_reverts() public {
        uint256 amountOut = SWAP_AMOUNT;

        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(
                CustomRevert.WrappedError.selector,
                address(hook),
                IHooks.beforeSwap.selector,
                abi.encodeWithSelector(FluidDexT1Aggregator.NativeCurrencyExactOut.selector),
                abi.encodeWithSelector(Hooks.HookCallFailed.selector)
            )
        );
        swapRouter.swap{value: amountOut * 2}( // Send extra ETH that would be refunded
            poolKey,
            SwapParams({zeroForOne: true, amountSpecified: int256(amountOut), sqrtPriceLimitX96: MIN_PRICE_LIMIT}),
            SafePoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
    }

    /// @notice Test exact output swap: ERC20 in -> Native ETH out (oneForZero)
    function test_nativeOut_exactOut() public {
        uint256 amountOut = SWAP_AMOUNT;

        // Get quote for expected input amount
        uint256 expectedIn = hook.quote(false, int256(amountOut), poolId);

        uint256 ethBefore = alice.balance;
        uint256 ercBefore = IERC20(ercTokenAddress).balanceOf(alice);

        vm.prank(alice);
        swapRouter.swap(
            poolKey,
            SwapParams({zeroForOne: false, amountSpecified: int256(amountOut), sqrtPriceLimitX96: MAX_PRICE_LIMIT}),
            SafePoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );

        uint256 ethAfter = alice.balance;
        uint256 ercAfter = IERC20(ercTokenAddress).balanceOf(alice);

        // ETH should increase by approximately the output amount (allow 0.1% variance)
        uint256 ethReceived = ethAfter - ethBefore;
        assertApproxEqRel(ethReceived, amountOut, 0.001e18, "ETH received should be close to output amount");

        // ERC20 should decrease
        uint256 ercSpent = ercBefore - ercAfter;

        assertApproxEqRel(ercSpent, expectedIn, 0.001e18, "ERC20 spent should be close to quote");
    }

    // ========== ADDITIONAL TESTS ==========

    /// @notice Test that multiple native swaps work correctly
    function test_multipleNativeSwaps() public {
        uint256 amount = 0.5 ether;

        // First swap: ETH -> ERC20 (exact input)
        vm.prank(alice);
        swapRouter.swap{value: amount}(
            poolKey,
            SwapParams({zeroForOne: true, amountSpecified: -int256(amount), sqrtPriceLimitX96: MIN_PRICE_LIMIT}),
            SafePoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );

        // Second swap: ERC20 -> ETH (exact input)
        vm.prank(alice);
        swapRouter.swap(
            poolKey,
            SwapParams({zeroForOne: false, amountSpecified: -int256(amount), sqrtPriceLimitX96: MAX_PRICE_LIMIT}),
            SafePoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );

        // Third swap: ERC20 -> ETH (exact output) - this direction works
        uint256 smallAmount = amount / 2;
        vm.prank(alice);
        swapRouter.swap(
            poolKey,
            SwapParams({zeroForOne: false, amountSpecified: int256(smallAmount), sqrtPriceLimitX96: MAX_PRICE_LIMIT}),
            SafePoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
    }

    /// @notice Verify quote function returns reasonable values for native pool
    function test_quote() public {
        uint256 amountIn = SWAP_AMOUNT;

        uint256 expectedOut = hook.quote(true, -int256(amountIn), poolId);

        assertGt(expectedOut, 0, "Quote should return non-zero");
        assertGt(expectedOut, amountIn * 70 / 100, "Quote should be within reasonable range");
    }

    receive() external payable {}
}
