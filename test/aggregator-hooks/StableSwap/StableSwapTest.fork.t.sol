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
import {CustomRevert} from "@uniswap/v4-core/src/libraries/CustomRevert.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {SafePoolSwapTest} from "../shared/SafePoolSwapTest.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {HookMiner} from "@uniswap/v4-periphery/src/utils/HookMiner.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {StableSwapAggregator} from "../../../src/aggregator-hooks/implementations/StableSwap/StableSwapAggregator.sol";
import {ICurveStableSwap} from "../../../src/aggregator-hooks/implementations/StableSwap/interfaces/IStableSwap.sol";

contract StableSwapForkedTest is Test {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;
    using StateLibrary for IPoolManager;

    // Pool configuration
    uint24 constant POOL_FEE = 500; // 0.05%
    int24 constant TICK_SPACING = 10;
    uint160 constant SQRT_PRICE_1_1 = 79228162514264337593543950336; // 1:1 price

    // Price limits for swaps
    uint160 constant MIN_PRICE_LIMIT = TickMath.MIN_SQRT_PRICE + 1;
    uint160 constant MAX_PRICE_LIMIT = TickMath.MAX_SQRT_PRICE - 1;

    // Loaded from .env
    address curvePoolAddress;
    address token0Address;
    address token1Address;
    uint8 tokenDecimals;

    // Test amounts - set dynamically based on token decimals
    uint256 swapAmount;
    uint256 initialBalance;

    IPoolManager public manager;
    SafePoolSwapTest public swapRouter;
    StableSwapAggregator public hook;
    ICurveStableSwap public curvePool;

    PoolKey public poolKey;
    PoolId public poolId;

    Currency public currency0;
    Currency public currency1;

    address public alice = makeAddr("alice");

    function setUp() public {
        string memory rpcUrl = vm.envString("MAINNET_RPC_URL");
        address poolManagerAddress = vm.envAddress("POOL_MANAGER");
        curvePoolAddress = vm.envAddress("STABLE_SWAP_POOL");

        vm.createSelectFork(rpcUrl);

        curvePool = ICurveStableSwap(curvePoolAddress);

        // Dynamically fetch tokens from the pool
        address coinA = curvePool.coins(0);
        address coinB = curvePool.coins(1);

        // Order tokens correctly for v4 (lower address = currency0)
        if (coinA < coinB) {
            token0Address = coinA;
            token1Address = coinB;
        } else {
            token0Address = coinB;
            token1Address = coinA;
        }

        currency0 = Currency.wrap(token0Address);
        currency1 = Currency.wrap(token1Address);

        // Get token decimals (assume both tokens have same decimals for stableswap)
        tokenDecimals = IERC20Metadata(token0Address).decimals();

        // Set test amounts based on decimals
        swapAmount = 1 * (10 ** tokenDecimals);
        initialBalance = 1000 * (10 ** tokenDecimals);

        // Use deployedPoolManager
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

        // Mint tokens to PoolManager (since these might not have existing balance)
        _mintToPoolManager();

        // Deal tokens to alice for testing
        _dealTokens(alice, initialBalance, initialBalance);

        // Approve swap router for alice
        vm.startPrank(alice);
        IERC20(token0Address).approve(address(swapRouter), type(uint256).max);
        IERC20(token1Address).approve(address(swapRouter), type(uint256).max);
        vm.stopPrank();
    }

    function _deployHook() internal {
        uint160 flags =
            uint160(Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG | Hooks.BEFORE_INITIALIZE_FLAG);

        bytes memory constructorArgs = abi.encode(address(manager), address(curvePool));
        (address hookAddress, bytes32 salt) =
            HookMiner.find(address(this), flags, type(StableSwapAggregator).creationCode, constructorArgs);

        hook = new StableSwapAggregator{salt: salt}(manager, curvePool);
        require(address(hook) == hookAddress, "Hook address mismatch");
    }

    function _mintToPoolManager() internal {
        // Mint tokens to PoolManager so it has liquidity for swaps
        uint256 poolManagerBalance = 10_000 * (10 ** tokenDecimals);
        deal(token0Address, address(manager), poolManagerBalance);
        deal(token1Address, address(manager), poolManagerBalance);
    }

    function _dealTokens(address to, uint256 amount0, uint256 amount1) internal {
        deal(token0Address, to, amount0);
        deal(token1Address, to, amount1);
    }

    /// @notice Get safe swap amount for zeroForOne based on PoolManager balance
    function _getSafeAmountZeroForOne(uint256 desiredAmount) internal view returns (uint256 safeAmount) {
        uint256 poolManagerBalance = IERC20(token0Address).balanceOf(address(manager));
        uint256 maxSafe = poolManagerBalance * 90 / 100;
        return desiredAmount < maxSafe ? desiredAmount : maxSafe;
    }

    /// @notice Get safe swap amount for oneForZero based on PoolManager balance
    function _getSafeAmountOneForZero(uint256 desiredAmount) internal view returns (uint256 safeAmount) {
        uint256 poolManagerBalance = IERC20(token1Address).balanceOf(address(manager));
        uint256 maxSafe = poolManagerBalance * 90 / 100;
        return desiredAmount < maxSafe ? desiredAmount : maxSafe;
    }

    // ========== SWAP TESTS ==========

    /// @notice Test exact input swap: Token0 -> Token1 (zero to one)
    function test_swapExactInput_ZeroForOne() public {
        uint256 amountIn = _getSafeAmountZeroForOne(swapAmount);
        require(amountIn > 0, "No balance for swap");

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
        uint256 amountIn = _getSafeAmountOneForZero(swapAmount);
        require(amountIn > 0, "No balance for swap");

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

    /// @notice Test that exact output swap reverts (StableSwap pools don't support get_dx)
    function test_swapExactOutput_ZeroForOne_Reverts() public {
        uint256 amountOut = swapAmount;

        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(
                CustomRevert.WrappedError.selector,
                address(hook),
                IHooks.beforeSwap.selector,
                abi.encodeWithSelector(StableSwapAggregator.ExactOutputNotSupported.selector),
                abi.encodeWithSelector(Hooks.HookCallFailed.selector)
            )
        );
        swapRouter.swap(
            poolKey,
            SwapParams({zeroForOne: true, amountSpecified: int256(amountOut), sqrtPriceLimitX96: MIN_PRICE_LIMIT}),
            SafePoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
    }

    /// @notice Test that exact output swap reverts (StableSwap pools don't support get_dx)
    function test_swapExactOutput_OneForZero_Reverts() public {
        uint256 amountOut = swapAmount;

        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(
                CustomRevert.WrappedError.selector,
                address(hook),
                IHooks.beforeSwap.selector,
                abi.encodeWithSelector(StableSwapAggregator.ExactOutputNotSupported.selector),
                abi.encodeWithSelector(Hooks.HookCallFailed.selector)
            )
        );
        swapRouter.swap(
            poolKey,
            SwapParams({zeroForOne: false, amountSpecified: int256(amountOut), sqrtPriceLimitX96: MAX_PRICE_LIMIT}),
            SafePoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
    }

    // ========== ADDITIONAL TESTS ==========

    /// @notice Test that multiple swaps work correctly
    function test_multipleSwaps() public {
        uint256 amount = _getSafeAmountZeroForOne(100 * (10 ** tokenDecimals));
        require(amount > 0, "No balance for swap");

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

        // Third swap: Another exact input swap (Note: StableSwap pools don't have get_dx, so exact output not
        // supported)
        uint256 smallAmount = amount / 2;
        vm.prank(alice);
        swapRouter.swap(
            poolKey,
            SwapParams({zeroForOne: true, amountSpecified: -int256(smallAmount), sqrtPriceLimitX96: MIN_PRICE_LIMIT}),
            SafePoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
    }

    /// @notice Test swap with larger amount
    function test_swapLargeAmount() public {
        uint256 desiredAmount = 1000 * (10 ** tokenDecimals);
        uint256 largeAmount = _getSafeAmountOneForZero(desiredAmount);
        require(largeAmount > 0, "No balance for swap");

        _dealTokens(alice, largeAmount, largeAmount);

        uint256 token0Before = IERC20(token0Address).balanceOf(alice);

        vm.prank(alice);
        swapRouter.swap(
            poolKey,
            SwapParams({zeroForOne: false, amountSpecified: -int256(largeAmount), sqrtPriceLimitX96: MAX_PRICE_LIMIT}),
            SafePoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );

        uint256 received = IERC20(token0Address).balanceOf(alice) - token0Before;
        // Note: Some stableswap pools have non-1:1 exchange rates, so we just check we received something
        assertGt(received, 0, "Should receive some tokens for large swap");
    }

    /// @notice Verify quote function returns reasonable values
    function test_quote() public {
        uint256 amountIn = swapAmount;

        uint256 expectedOut = hook.quote(true, -int256(amountIn), poolId);

        assertGt(expectedOut, 0, "Quote should return non-zero");
        assertGt(expectedOut, amountIn * 99 / 100, "Quote should be close to 1:1 for stableswap");
    }

    /// @notice Test pseudoTotalValueLocked returns values matching Curve pool balances
    function test_pseudoTotalValueLocked() public view {
        (uint256 amount0, uint256 amount1) = hook.pseudoTotalValueLocked(poolId);

        (int128 token0Index, int128 token1Index) = hook.poolIdToTokenInfo(poolId);
        uint256 expectedBalance0 = curvePool.balances(uint256(uint128(token0Index)));
        uint256 expectedBalance1 = curvePool.balances(uint256(uint128(token1Index)));

        assertEq(amount0, expectedBalance0, "amount0 should match Curve pool balance");
        assertEq(amount1, expectedBalance1, "amount1 should match Curve pool balance");
        assertGt(amount0, 0, "amount0 should be non-zero");
        assertGt(amount1, 0, "amount1 should be non-zero");
    }

    receive() external payable {}
}
