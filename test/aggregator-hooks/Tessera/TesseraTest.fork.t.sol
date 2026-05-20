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
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {HookMiner} from "@uniswap/v4-periphery/src/utils/HookMiner.sol";
import {SafePoolSwapTest} from "../shared/SafePoolSwapTest.sol";
import {TesseraAggregator} from "../../../src/aggregator-hooks/implementations/Tessera/TesseraAggregator.sol";
import {ITesseraSwap} from "../../../src/aggregator-hooks/implementations/Tessera/interfaces/ITesseraSwap.sol";
import {ITesseraManager} from "../../../src/aggregator-hooks/implementations/Tessera/interfaces/ITesseraManager.sol";

/// @title TesseraForkedTest
/// @notice Fork tests for the Tessera aggregator hook against live deployments on Base / BSC.
/// @dev Set `FORK_RPC_URL`, `POOL_MANAGER`, `TESSERA_SWAP`, `TESSERA_MANAGER`,
///      `TESSERA_PAIR_TOKEN0`, `TESSERA_PAIR_TOKEN1`. Per the test README, at least one fork run
///      must exercise a USDT pool.
contract TesseraForkedTest is Test {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;
    using StateLibrary for IPoolManager;
    using SafeERC20 for IERC20;

    uint24 constant POOL_FEE = 500;
    int24 constant TICK_SPACING = 10;
    uint160 constant SQRT_PRICE_1_1 = 79_228_162_514_264_337_593_543_950_336;
    uint160 constant MIN_PRICE_LIMIT = TickMath.MIN_SQRT_PRICE + 1;
    uint160 constant MAX_PRICE_LIMIT = TickMath.MAX_SQRT_PRICE - 1;

    address tesseraSwapAddress;
    address tesseraManagerAddress;
    address token0Address;
    address token1Address;
    uint8 token0Decimals;
    uint8 token1Decimals;
    uint256 swapAmount0;
    uint256 swapAmount1;
    uint256 initialBalance0;
    uint256 initialBalance1;

    IPoolManager public manager;
    SafePoolSwapTest public swapRouter;
    TesseraAggregator public hook;

    PoolKey public poolKey;
    PoolId public poolId;
    Currency public currency0;
    Currency public currency1;
    address public alice = makeAddr("alice");

    function setUp() public {
        string memory rpcUrl;
        try vm.envString("FORK_RPC_URL") returns (string memory _u) {
            rpcUrl = _u;
        } catch {
            vm.skip(true);
        }
        uint256 forkBlockNumber = vm.envOr("FORK_BLOCK_NUMBER", uint256(0));
        if (forkBlockNumber > 0) {
            vm.createSelectFork(rpcUrl, forkBlockNumber);
        } else {
            vm.createSelectFork(rpcUrl);
        }

        tesseraSwapAddress = vm.envAddress("TESSERA_SWAP");
        tesseraManagerAddress = vm.envAddress("TESSERA_MANAGER");
        address poolManagerAddress = vm.envAddress("POOL_MANAGER");

        address tokenA = vm.envAddress("TESSERA_PAIR_TOKEN0");
        address tokenB = vm.envAddress("TESSERA_PAIR_TOKEN1");
        if (tokenA < tokenB) {
            token0Address = tokenA;
            token1Address = tokenB;
        } else {
            token0Address = tokenB;
            token1Address = tokenA;
        }
        currency0 = Currency.wrap(token0Address);
        currency1 = Currency.wrap(token1Address);
        token0Decimals = IERC20Metadata(token0Address).decimals();
        token1Decimals = IERC20Metadata(token1Address).decimals();
        swapAmount0 = 1 * (10 ** token0Decimals);
        swapAmount1 = 1 * (10 ** token1Decimals);
        initialBalance0 = 1_000 * (10 ** token0Decimals);
        initialBalance1 = 1_000 * (10 ** token1Decimals);

        manager = IPoolManager(poolManagerAddress);
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

        deal(token0Address, address(manager), initialBalance0 * 10);
        deal(token1Address, address(manager), initialBalance1 * 10);
        deal(token0Address, alice, initialBalance0);
        deal(token1Address, alice, initialBalance1);

        vm.startPrank(alice);
        IERC20(token0Address).forceApprove(address(swapRouter), type(uint256).max);
        IERC20(token1Address).forceApprove(address(swapRouter), type(uint256).max);
        vm.stopPrank();
    }

    function _deployHook() internal {
        uint160 flags = uint160(
            Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG | Hooks.BEFORE_INITIALIZE_FLAG
                | Hooks.BEFORE_ADD_LIQUIDITY_FLAG
        );
        // TesseraSwap treasury on Base (slot 1 of TesseraSwap): 0x3dbe077e7986657e95e1cc50089f17a5a4af0aae
        address tesseraTreasury = vm.envOr("TESSERA_TREASURY", address(0x3dBE077e7986657E95e1CC50089f17a5a4AF0AaE));
        bytes memory constructorArgs =
            abi.encode(address(manager), tesseraSwapAddress, tesseraManagerAddress, tesseraTreasury, address(this));
        (address hookAddress, bytes32 salt) =
            HookMiner.find(address(this), flags, type(TesseraAggregator).creationCode, constructorArgs);
        hook = new TesseraAggregator{salt: salt}(
            manager,
            ITesseraSwap(tesseraSwapAddress),
            ITesseraManager(tesseraManagerAddress),
            tesseraTreasury,
            address(this)
        );
        require(address(hook) == hookAddress, "Hook address mismatch");
    }

    function test_swapExactInput_ZeroForOne() public {
        uint256 amountIn = swapAmount0;
        uint256 expectedOut = hook.quote(true, -int256(amountIn), poolId);
        assertGt(expectedOut, 0);

        uint256 t0Before = IERC20(token0Address).balanceOf(alice);
        uint256 t1Before = IERC20(token1Address).balanceOf(alice);

        vm.prank(alice);
        swapRouter.swap(
            poolKey,
            SwapParams({zeroForOne: true, amountSpecified: -int256(amountIn), sqrtPriceLimitX96: MIN_PRICE_LIMIT}),
            SafePoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );

        assertEq(t0Before - IERC20(token0Address).balanceOf(alice), amountIn);
        assertEq(IERC20(token1Address).balanceOf(alice) - t1Before, expectedOut);
    }

    function test_swapExactInput_OneForZero() public {
        uint256 amountIn = swapAmount1;
        uint256 expectedOut = hook.quote(false, -int256(amountIn), poolId);
        assertGt(expectedOut, 0);

        uint256 t0Before = IERC20(token0Address).balanceOf(alice);
        uint256 t1Before = IERC20(token1Address).balanceOf(alice);

        vm.prank(alice);
        swapRouter.swap(
            poolKey,
            SwapParams({zeroForOne: false, amountSpecified: -int256(amountIn), sqrtPriceLimitX96: MAX_PRICE_LIMIT}),
            SafePoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );

        assertEq(t1Before - IERC20(token1Address).balanceOf(alice), amountIn);
        assertEq(IERC20(token0Address).balanceOf(alice) - t0Before, expectedOut);
    }

    function test_swapExactOutput_ZeroForOne() public {
        uint256 amountOut = swapAmount1;
        uint256 expectedIn = hook.quote(true, int256(amountOut), poolId);
        assertGt(expectedIn, 0);

        uint256 t0Before = IERC20(token0Address).balanceOf(alice);
        uint256 t1Before = IERC20(token1Address).balanceOf(alice);

        vm.prank(alice);
        swapRouter.swap(
            poolKey,
            SwapParams({zeroForOne: true, amountSpecified: int256(amountOut), sqrtPriceLimitX96: MIN_PRICE_LIMIT}),
            SafePoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );

        assertEq(IERC20(token1Address).balanceOf(alice) - t1Before, amountOut);
        assertEq(t0Before - IERC20(token0Address).balanceOf(alice), expectedIn);
    }

    function testFuzz_swapExactInput_ZeroForOne(uint128 amountIn) public {
        amountIn = uint128(bound(amountIn, 10 ** uint256(token0Decimals) / 100, initialBalance0 / 10));
        uint256 expectedOut = hook.quote(true, -int256(uint256(amountIn)), poolId);
        if (expectedOut == 0) return;

        uint256 t0Before = IERC20(token0Address).balanceOf(alice);
        uint256 t1Before = IERC20(token1Address).balanceOf(alice);

        vm.prank(alice);
        swapRouter.swap(
            poolKey,
            SwapParams({
                zeroForOne: true, amountSpecified: -int256(uint256(amountIn)), sqrtPriceLimitX96: MIN_PRICE_LIMIT
            }),
            SafePoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );

        assertEq(t0Before - IERC20(token0Address).balanceOf(alice), amountIn);
        assertEq(IERC20(token1Address).balanceOf(alice) - t1Before, expectedOut);
    }
}
