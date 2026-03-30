// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test, console2} from "forge-std/Test.sol";
import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {LiquidityAmounts} from "@uniswap/v4-periphery/src/libraries/LiquidityAmounts.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {ERC20} from "solmate/src/tokens/ERC20.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {SmartPoolHook} from "../../src/alf/SmartPoolHook.sol";
import {SpreadQuoterBase} from "../../src/alf/base/SpreadQuoterBase.sol";
import {MockERC4626} from "./mocks/MockERC4626.sol";

/// @title SmartPoolHookBenchmark
/// @notice Gas benchmarks for SmartPoolHook swaps at various sizes and bucket configs.
///         Compare against a vanilla v4 pool with equivalent liquidity.
contract SmartPoolHookBenchmarkTest is Test, Deployers {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;
    using StateLibrary for IPoolManager;

    SmartPoolHook public hook;
    MockERC4626 public vault0;
    MockERC4626 public vault1;
    MockERC20 token0;
    MockERC20 token1;

    address owner = makeAddr("owner");

    // SmartPool keys
    PoolKey smartPoolKey_1bucket;
    PoolKey smartPoolKey_3bucket;

    // Vanilla v4 pool (no hook, static LP) for baseline comparison
    PoolKey vanillaPoolKey;

    uint24 constant FEE_PIPS = 500; // 5 bps

    function setUp() public {
        deployFreshManagerAndRouters();
        deployMintAndApprove2Currencies();

        token0 = MockERC20(Currency.unwrap(currency0));
        token1 = MockERC20(Currency.unwrap(currency1));

        vault0 = new MockERC4626(ERC20(address(token0)));
        vault1 = new MockERC4626(ERC20(address(token1)));

        // ── Deploy SmartPoolHook ──
        uint160 flags = uint160(
            Hooks.BEFORE_INITIALIZE_FLAG | Hooks.AFTER_INITIALIZE_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG
                | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG
        );
        hook = SmartPoolHook(address(uint160(uint256(type(uint160).max) & clearAllHookPermissionsMask | flags)));
        deployCodeTo("SmartPoolHook", abi.encode(manager, uint32(100_000), owner), address(hook));

        // ── 1-bucket SmartPool ──
        smartPoolKey_1bucket = PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: 10,
            hooks: IHooks(address(hook))
        });

        SmartPoolHook.LiquidityBucket[] memory dist1 = new SmartPoolHook.LiquidityBucket[](1);
        dist1[0] = SmartPoolHook.LiquidityBucket({tickLower: -60, tickUpper: 60, weightBps: 10_000});

        vm.startPrank(owner);
        hook.initializePool(smartPoolKey_1bucket, SmartPoolHook.PoolConfig({
            sqrtPriceX96: TickMath.getSqrtPriceAtTick(0),
            pricing: SpreadQuoterBase.PricingState({bidFeePips: FEE_PIPS, askFeePips: FEE_PIPS, live: true}),
            distribution: dist1,
            allowExternalDeposits: false,
            vault0: IERC4626(address(vault0)),
            vault1: IERC4626(address(vault1))
        }));
        vm.stopPrank();

        _deposit(smartPoolKey_1bucket, 10_000e18);

        // ── 3-bucket SmartPool ──
        // Need a second hook instance at a different address for the second pool
        SmartPoolHook hook2 = SmartPoolHook(
            address(uint160((uint256(type(uint160).max) - (1 << 14)) & clearAllHookPermissionsMask | flags))
        );
        deployCodeTo("SmartPoolHook", abi.encode(manager, uint32(100_000), owner), address(hook2));

        smartPoolKey_3bucket = PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: 10,
            hooks: IHooks(address(hook2))
        });

        SmartPoolHook.LiquidityBucket[] memory dist3 = new SmartPoolHook.LiquidityBucket[](3);
        dist3[0] = SmartPoolHook.LiquidityBucket({tickLower: -10, tickUpper: 10, weightBps: 7500});
        dist3[1] = SmartPoolHook.LiquidityBucket({tickLower: -30, tickUpper: 30, weightBps: 1500});
        dist3[2] = SmartPoolHook.LiquidityBucket({tickLower: -60, tickUpper: 60, weightBps: 1000});

        vm.startPrank(owner);
        hook2.initializePool(smartPoolKey_3bucket, SmartPoolHook.PoolConfig({
            sqrtPriceX96: TickMath.getSqrtPriceAtTick(0),
            pricing: SpreadQuoterBase.PricingState({bidFeePips: FEE_PIPS, askFeePips: FEE_PIPS, live: true}),
            distribution: dist3,
            allowExternalDeposits: false,
            vault0: IERC4626(address(new MockERC4626(ERC20(address(token0))))),
            vault1: IERC4626(address(new MockERC4626(ERC20(address(token1)))))
        }));
        vm.stopPrank();

        _deposit(smartPoolKey_3bucket, 10_000e18);

        // ── Vanilla v4 pool (no hook, static LP at [-60, 60]) ──
        vanillaPoolKey = PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: FEE_PIPS,
            tickSpacing: 10,
            hooks: IHooks(address(0))
        });
        manager.initialize(vanillaPoolKey, TickMath.getSqrtPriceAtTick(0));

        // Seed static LP equivalent to ~10_000e18 each
        token0.mint(address(this), 10_000e18);
        token1.mint(address(this), 10_000e18);
        token0.approve(address(modifyLiquidityRouter), type(uint256).max);
        token1.approve(address(modifyLiquidityRouter), type(uint256).max);

        uint128 liq = LiquidityAmounts.getLiquidityForAmounts(
            TickMath.getSqrtPriceAtTick(0),
            TickMath.getSqrtPriceAtTick(-60),
            TickMath.getSqrtPriceAtTick(60),
            10_000e18,
            10_000e18
        );
        modifyLiquidityRouter.modifyLiquidity(
            vanillaPoolKey,
            ModifyLiquidityParams({tickLower: -60, tickUpper: 60, liquidityDelta: int256(uint256(liq)), salt: 0}),
            ""
        );
    }

    // ═══════════════════════════════════════════════════════════════════════════
    //                        BENCHMARKS: 1-BUCKET SMARTPOOL
    // ═══════════════════════════════════════════════════════════════════════════

    function test_benchmark_1bucket_100e18() public {
        uint256 gas = _benchmarkSwap(smartPoolKey_1bucket, 100e18);
        console2.log("1-bucket | 100e18 swap:", gas, "gas");
    }

    function test_benchmark_1bucket_1000e18() public {
        uint256 gas = _benchmarkSwap(smartPoolKey_1bucket, 1_000e18);
        console2.log("1-bucket | 1_000e18 swap:", gas, "gas");
    }

    function test_benchmark_1bucket_5000e18() public {
        uint256 gas = _benchmarkSwap(smartPoolKey_1bucket, 5_000e18);
        console2.log("1-bucket | 5_000e18 swap:", gas, "gas");
    }

    function test_benchmark_1bucket_9000e18() public {
        uint256 gas = _benchmarkSwap(smartPoolKey_1bucket, 9_000e18);
        console2.log("1-bucket | 9_000e18 swap:", gas, "gas");
    }

    // ═══════════════════════════════════════════════════════════════════════════
    //                        BENCHMARKS: 3-BUCKET SMARTPOOL
    // ═══════════════════════════════════════════════════════════════════════════

    function test_benchmark_3bucket_100e18() public {
        uint256 gas = _benchmarkSwap(smartPoolKey_3bucket, 100e18);
        console2.log("3-bucket | 100e18 swap:", gas, "gas");
    }

    function test_benchmark_3bucket_1000e18() public {
        uint256 gas = _benchmarkSwap(smartPoolKey_3bucket, 1_000e18);
        console2.log("3-bucket | 1_000e18 swap:", gas, "gas");
    }

    function test_benchmark_3bucket_5000e18() public {
        uint256 gas = _benchmarkSwap(smartPoolKey_3bucket, 5_000e18);
        console2.log("3-bucket | 5_000e18 swap:", gas, "gas");
    }

    function test_benchmark_3bucket_9000e18() public {
        uint256 gas = _benchmarkSwap(smartPoolKey_3bucket, 9_000e18);
        console2.log("3-bucket | 9_000e18 swap:", gas, "gas");
    }

    // ═══════════════════════════════════════════════════════════════════════════
    //                        BENCHMARKS: VANILLA V4 (BASELINE)
    // ═══════════════════════════════════════════════════════════════════════════

    function test_benchmark_vanilla_100e18() public {
        uint256 gas = _benchmarkSwap(vanillaPoolKey, 100e18);
        console2.log("vanilla  | 100e18 swap:", gas, "gas");
    }

    function test_benchmark_vanilla_1000e18() public {
        uint256 gas = _benchmarkSwap(vanillaPoolKey, 1_000e18);
        console2.log("vanilla  | 1_000e18 swap:", gas, "gas");
    }

    function test_benchmark_vanilla_5000e18() public {
        uint256 gas = _benchmarkSwap(vanillaPoolKey, 5_000e18);
        console2.log("vanilla  | 5_000e18 swap:", gas, "gas");
    }

    function test_benchmark_vanilla_9000e18() public {
        uint256 gas = _benchmarkSwap(vanillaPoolKey, 9_000e18);
        console2.log("vanilla  | 9_000e18 swap:", gas, "gas");
    }

    // ═══════════════════════════════════════════════════════════════════════════
    //                        BENCHMARK: SECOND SWAP (WARM STATE)
    // ═══════════════════════════════════════════════════════════════════════════

    function test_benchmark_3bucket_secondSwap() public {
        // First swap warms storage and creates claims
        swap(smartPoolKey_3bucket, true, -100e18, "");

        // Second swap is the interesting one — claims exist, vaults partially depleted
        uint256 gas = _benchmarkSwap(smartPoolKey_3bucket, 100e18);
        console2.log("3-bucket | 100e18 2nd swap (warm):", gas, "gas");
    }

    // ═══════════════════════════════════════════════════════════════════════════
    //                              HELPERS
    // ═══════════════════════════════════════════════════════════════════════════

    function _benchmarkSwap(PoolKey memory key, uint256 amount) internal returns (uint256 gasUsed) {
        uint256 gasBefore = gasleft();
        swap(key, true, -int256(amount), "");
        gasUsed = gasBefore - gasleft();
    }

    function _deposit(PoolKey memory key, uint256 amount) internal {
        SmartPoolHook h = SmartPoolHook(address(key.hooks));
        (uint256 need0, uint256 need1) = h.previewDeposit(key, amount);
        token0.mint(owner, need0);
        token1.mint(owner, need1);
        vm.startPrank(owner);
        token0.approve(address(h), need0);
        token1.approve(address(h), need1);
        h.addLiquidity(key, amount);
        vm.stopPrank();
    }
}
