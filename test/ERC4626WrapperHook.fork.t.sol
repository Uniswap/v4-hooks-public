// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {PoolModifyLiquidityTest} from "@uniswap/v4-core/src/test/PoolModifyLiquidityTest.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {ModifyLiquidityParams, SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol";

import {ERC4626WrapperHook} from "../src/ERC4626WrapperHook.sol";
import {TestRouter} from "./shared/TestRouter.sol";

/// @notice End-to-end fork coverage for the deployed SK hynix xStock and its ERC-4626 wrapper.
contract ERC4626WrapperHookForkTest is Test, Deployers {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    uint256 internal constant MAINNET_FORK_BLOCK = 25_540_000;

    IPoolManager internal constant MAINNET_POOL_MANAGER = IPoolManager(0x000000000004444c5dc75cB358380D2e3dE08A90);
    // From xStocks API: https://docs.xstocks.fi/apis/openapi/assets/list_public_assets
    address internal constant SKHYX = 0x58100046a4Afcd4eE4faDbD4244f3f895a341c56;
    address internal constant WRAPPED_SKHYX = 0x6215a58ed045d71F2561AaAbe54f4C885C522998;
    address internal constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;

    // 100 USDC per wSKHYx. Currency1/currency0 is expressed in raw token units:
    // sqrt(100e6 / 1e18) * 2^96 = 2^96 / 1e5.
    uint160 internal constant MARKET_SQRT_PRICE_X96 = 792_281_625_142_643_375_935_439;
    uint24 internal constant MARKET_FEE = 500;
    int24 internal constant MARKET_TICK_SPACING = 10;
    int256 internal constant MARKET_LIQUIDITY = 1e15;

    IERC20 internal xStock;
    IERC4626 internal wrappedXStock;
    IERC20 internal usdc;
    ERC4626WrapperHook internal hook;
    TestRouter internal router;
    PoolKey internal wrapperPoolKey;
    PoolKey internal marketPoolKey;

    address internal lp = makeAddr("lp");
    address internal trader = makeAddr("trader");
    bool internal wrapZeroForOne;

    function setUp() public {
        string memory rpcUrl;
        try vm.envString("FORK_RPC_URL_1") returns (string memory r) {
            rpcUrl = r;
        } catch {
            vm.skip(true);
            return;
        }

        vm.createSelectFork(rpcUrl, MAINNET_FORK_BLOCK);

        manager = MAINNET_POOL_MANAGER;
        router = new TestRouter(manager);
        modifyLiquidityRouter = new PoolModifyLiquidityTest(manager);

        xStock = IERC20(SKHYX);
        wrappedXStock = IERC4626(WRAPPED_SKHYX);
        usdc = IERC20(USDC);

        vm.label(SKHYX, "SKHYx");
        vm.label(WRAPPED_SKHYX, "wSKHYx");
        vm.label(USDC, "USDC");

        uint160 flags = uint160(
            type(uint160).max & clearAllHookPermissionsMask | Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG
                | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG | Hooks.BEFORE_INITIALIZE_FLAG
        );
        hook = ERC4626WrapperHook(address(flags));
        deployCodeTo("ERC4626WrapperHook", abi.encode(manager, wrappedXStock), address(hook));
        vm.label(address(hook), "SKHYx ERC4626 wrapper hook");

        wrapZeroForOne = SKHYX < WRAPPED_SKHYX;
        (Currency wrapperCurrency0, Currency wrapperCurrency1) = wrapZeroForOne
            ? (Currency.wrap(SKHYX), Currency.wrap(WRAPPED_SKHYX))
            : (Currency.wrap(WRAPPED_SKHYX), Currency.wrap(SKHYX));

        wrapperPoolKey = PoolKey({
            currency0: wrapperCurrency0,
            currency1: wrapperCurrency1,
            fee: 0,
            tickSpacing: 60,
            hooks: IHooks(address(hook))
        });
        manager.initialize(wrapperPoolKey, SQRT_PRICE_1_1);

        assertLt(uint160(WRAPPED_SKHYX), uint160(USDC), "market price assumes wSKHYx is currency0");
        marketPoolKey = PoolKey({
            currency0: Currency.wrap(WRAPPED_SKHYX),
            currency1: Currency.wrap(USDC),
            fee: MARKET_FEE,
            tickSpacing: MARKET_TICK_SPACING,
            hooks: IHooks(address(0))
        });
        manager.initialize(marketPoolKey, MARKET_SQRT_PRICE_X96);
    }

    function test_fork_deploymentsAndPoolsUseLiveSKHYxWrapper() public view {
        assertEq(block.number, MAINNET_FORK_BLOCK, "unexpected fork block");
        assertGt(SKHYX.code.length, 0, "SKHYx is not deployed");
        assertGt(WRAPPED_SKHYX.code.length, 0, "wSKHYx is not deployed");
        assertEq(wrappedXStock.asset(), SKHYX, "wrapper asset is not SKHYx");
        assertEq(wrappedXStock.decimals(), 18, "unexpected wrapper decimals");
        assertEq(xStock.decimals(), 18, "unexpected SKHYx decimals");

        (uint160 wrapperSqrtPriceX96,,,) = manager.getSlot0(wrapperPoolKey.toId());
        (uint160 marketSqrtPriceX96,,,) = manager.getSlot0(marketPoolKey.toId());
        assertEq(wrapperSqrtPriceX96, SQRT_PRICE_1_1, "wrapper pool not initialized");
        assertEq(marketSqrtPriceX96, MARKET_SQRT_PRICE_X96, "market pool not initialized");
        assertEq(manager.getLiquidity(wrapperPoolKey.toId()), 0, "wrapper pool should not have LP liquidity");
    }

    function test_fork_e2e_wrapLPAddAndSwapThroughMarket() public {
        uint256 lpAssets = 1_000 ether;
        uint256 lpUsdc = 100_000e6;
        deal(SKHYX, lp, lpAssets);
        deal(USDC, lp, lpUsdc);

        uint256 expectedLpShares = wrappedXStock.previewDeposit(lpAssets);
        uint256 lpShares = _wrap(lp, lpAssets);
        assertEq(lpShares, expectedLpShares, "LP wrap output differs from ERC-4626 preview");
        assertEq(xStock.balanceOf(lp), 0, "LP retains SKHYx after wrapping");

        vm.startPrank(lp);
        wrappedXStock.approve(address(modifyLiquidityRouter), type(uint256).max);
        usdc.approve(address(modifyLiquidityRouter), type(uint256).max);
        BalanceDelta liquidityDelta = modifyLiquidityRouter.modifyLiquidity(
            marketPoolKey,
            ModifyLiquidityParams({
                tickLower: TickMath.minUsableTick(MARKET_TICK_SPACING),
                tickUpper: TickMath.maxUsableTick(MARKET_TICK_SPACING),
                liquidityDelta: MARKET_LIQUIDITY,
                salt: bytes32(0)
            }),
            ""
        );
        vm.stopPrank();

        assertLt(liquidityDelta.amount0(), 0, "LP did not supply wSKHYx");
        assertLt(liquidityDelta.amount1(), 0, "LP did not supply USDC");
        assertEq(
            manager.getLiquidity(marketPoolKey.toId()), uint128(uint256(MARKET_LIQUIDITY)), "market liquidity not added"
        );

        uint256 traderAssets = 10 ether;
        deal(SKHYX, trader, traderAssets);
        uint256 expectedTraderShares = wrappedXStock.previewDeposit(traderAssets);
        uint256 traderShares = _wrap(trader, traderAssets);
        assertEq(traderShares, expectedTraderShares, "trader wrap output differs from ERC-4626 preview");

        uint256 amountIn = 1 ether;
        uint256 usdcBefore = usdc.balanceOf(trader);
        uint256 sharesBefore = wrappedXStock.balanceOf(trader);

        vm.startPrank(trader);
        wrappedXStock.approve(address(router), amountIn);
        router.swap(
            marketPoolKey,
            SwapParams({
                zeroForOne: true, amountSpecified: -int256(amountIn), sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            ""
        );
        vm.stopPrank();

        assertEq(sharesBefore - wrappedXStock.balanceOf(trader), amountIn, "incorrect wSKHYx swap input");
        assertGt(usdc.balanceOf(trader) - usdcBefore, 0, "trader received no USDC");
        assertEq(manager.getLiquidity(wrapperPoolKey.toId()), 0, "wrapper pool unexpectedly gained liquidity");
        assertEq(wrappedXStock.balanceOf(address(hook)), 0, "hook retains wSKHYx");
        assertEq(xStock.balanceOf(address(hook)), 0, "hook retains SKHYx");
    }

    function _wrap(address account, uint256 assets) internal returns (uint256 sharesReceived) {
        uint256 sharesBefore = wrappedXStock.balanceOf(account);

        vm.startPrank(account);
        xStock.approve(address(router), assets);
        router.swap(
            wrapperPoolKey,
            SwapParams({
                zeroForOne: wrapZeroForOne,
                amountSpecified: -int256(assets),
                sqrtPriceLimitX96: wrapZeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            ""
        );
        vm.stopPrank();

        sharesReceived = wrappedXStock.balanceOf(account) - sharesBefore;
    }
}
