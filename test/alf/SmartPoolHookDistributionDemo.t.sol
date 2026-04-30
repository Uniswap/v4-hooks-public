// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test, console2} from "forge-std/Test.sol";
import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

import {SmartPoolHook} from "../../src/alf/SmartPoolHook.sol";
import {SmartPoolBase} from "../../src/alf/base/SmartPoolBase.sol";

/// @notice Demonstration tests showing JIT swap behavior under each of the
///         liquidity-distribution shapes documented in
///         `docs/technical/SmartPoolHook.md`. Run with
///         `forge test --match-path test/alf/SmartPoolHookDistributionDemo.t.sol -vv`
///         to see per-swap input/output/slippage/tick logs.
///
/// @dev Pools use no rehypothecation vault so reserves equal raw ERC-20 and
///      results reflect distribution shape alone, not vault accounting.
contract SmartPoolHookDistributionDemoTest is Test, Deployers {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    SmartPoolHook public hook;
    address owner = makeAddr("owner");

    MockERC20 token0;
    MockERC20 token1;

    uint24 constant BID_FEE_PIPS = 1_000; // 0.1% LP fee on token0 → token1 swaps
    uint24 constant ASK_FEE_PIPS = 1_000; // 0.1% LP fee on token1 → token0 swaps
    /// @dev Sized so the swap ladder (up to 5,000 t0) actually consumes a meaningful share
    ///      of pool depth and surfaces distribution-shape differences. With BOOTSTRAP_AMOUNT
    ///      at 1M, even 1k swaps register only the LP fee — not interesting for a demo.
    uint256 constant BOOTSTRAP_AMOUNT = 10_000 ether;

    function setUp() public {
        deployFreshManagerAndRouters();
        deployMintAndApprove2Currencies();
        token0 = MockERC20(Currency.unwrap(currency0));
        token1 = MockERC20(Currency.unwrap(currency1));

        uint160 flags = uint160(
            Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG
                | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG
        );
        hook = SmartPoolHook(address(uint160(uint256(type(uint160).max) & clearAllHookPermissionsMask | flags)));
        deployCodeTo("SmartPoolHook", abi.encode(manager, uint32(100_000), owner), address(hook));
    }

    // ═══════════════════════════════════════════════════════════════════════════
    //                          DISTRIBUTION DEMOS
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Conservative shape from the doc: most depth at the peg, tapering tails.
    ///         75% [-10, 10] / 15% [-30, 30] / 10% [-60, 60].
    function test_demo_conservative() public {
        SmartPoolHook.LiquidityBucket[] memory dist = new SmartPoolHook.LiquidityBucket[](3);
        dist[0] = SmartPoolHook.LiquidityBucket({tickLower: -10, tickUpper: 10, weightBps: 7_500});
        dist[1] = SmartPoolHook.LiquidityBucket({tickLower: -30, tickUpper: 30, weightBps: 1_500});
        dist[2] = SmartPoolHook.LiquidityBucket({tickLower: -60, tickUpper: 60, weightBps: 1_000});
        PoolKey memory key = _initWithDistribution(
            "Conservative (75/15/10 across [-10,10] [-30,30] [-60,60])", dist, 10
        );
        _runSwapSeries(key);
    }

    /// @notice Ultra-tight stable-pair shape: 45% [-1, 1] / 35% [-5, 5] / 15% [-20, 20] /
    ///         5% [-100, 100]. Capital-efficient on tiny swaps, fragile on bigger ones.
    function test_demo_ultraTight() public {
        SmartPoolHook.LiquidityBucket[] memory dist = new SmartPoolHook.LiquidityBucket[](4);
        dist[0] = SmartPoolHook.LiquidityBucket({tickLower: -1, tickUpper: 1, weightBps: 4_500});
        dist[1] = SmartPoolHook.LiquidityBucket({tickLower: -5, tickUpper: 5, weightBps: 3_500});
        dist[2] = SmartPoolHook.LiquidityBucket({tickLower: -20, tickUpper: 20, weightBps: 1_500});
        dist[3] = SmartPoolHook.LiquidityBucket({tickLower: -100, tickUpper: 100, weightBps: 500});
        PoolKey memory key = _initWithDistribution(
            "Ultra-tight (45/35/15/5 across [-1,1] [-5,5] [-20,20] [-100,100])", dist, 1
        );
        _runSwapSeries(key);
    }

    /// @notice Barbell shape: tight center plus far one-sided tails for shock absorption.
    ///         50% [-5, 5] / 20% [-25, 25] / 15% [-250, -50] / 15% [50, 250].
    function test_demo_barbell() public {
        SmartPoolHook.LiquidityBucket[] memory dist = new SmartPoolHook.LiquidityBucket[](4);
        dist[0] = SmartPoolHook.LiquidityBucket({tickLower: -5, tickUpper: 5, weightBps: 5_000});
        dist[1] = SmartPoolHook.LiquidityBucket({tickLower: -25, tickUpper: 25, weightBps: 2_000});
        dist[2] = SmartPoolHook.LiquidityBucket({tickLower: -250, tickUpper: -50, weightBps: 1_500});
        dist[3] = SmartPoolHook.LiquidityBucket({tickLower: 50, tickUpper: 250, weightBps: 1_500});
        PoolKey memory key = _initWithDistribution(
            "Barbell (50/20/15/15 with [-250,-50] and [50,250] tails)", dist, 5
        );
        _runSwapSeries(key);
    }

    /// @notice Inventory-skewed shape: maker is token0-heavy, places a sell wall above peg
    ///         to convert token0 into token1 as price rises.
    ///         35% [-10, 10] / 40% [10, 80] / 20% [-80, 80] / 5% [-200, -80].
    function test_demo_inventorySkewed() public {
        SmartPoolHook.LiquidityBucket[] memory dist = new SmartPoolHook.LiquidityBucket[](4);
        dist[0] = SmartPoolHook.LiquidityBucket({tickLower: -10, tickUpper: 10, weightBps: 3_500});
        dist[1] = SmartPoolHook.LiquidityBucket({tickLower: 10, tickUpper: 80, weightBps: 4_000});
        dist[2] = SmartPoolHook.LiquidityBucket({tickLower: -80, tickUpper: 80, weightBps: 2_000});
        dist[3] = SmartPoolHook.LiquidityBucket({tickLower: -200, tickUpper: -80, weightBps: 500});
        PoolKey memory key = _initWithDistribution(
            "Inventory-skewed (token0-heavy, upper sell wall [10,80])", dist, 10
        );
        _runSwapSeries(key);
    }

    /// @notice Peg-defense ladder: asymmetric, deeper support below the peg with a smaller
    ///         recovery band above. 30% [-8, 8] / 25% [-40, -8] / 25% [-120, -40] /
    ///         20% [8, 80].
    function test_demo_pegDefense() public {
        SmartPoolHook.LiquidityBucket[] memory dist = new SmartPoolHook.LiquidityBucket[](4);
        dist[0] = SmartPoolHook.LiquidityBucket({tickLower: -8, tickUpper: 8, weightBps: 3_000});
        dist[1] = SmartPoolHook.LiquidityBucket({tickLower: -40, tickUpper: -8, weightBps: 2_500});
        dist[2] = SmartPoolHook.LiquidityBucket({tickLower: -120, tickUpper: -40, weightBps: 2_500});
        dist[3] = SmartPoolHook.LiquidityBucket({tickLower: 8, tickUpper: 80, weightBps: 2_000});
        PoolKey memory key = _initWithDistribution(
            "Peg-defense ladder (asymmetric, deeper below peg)", dist, 8
        );
        _runSwapSeries(key);
    }

    /// @notice Volatility-adaptive rotation: same pool, swap once under a calm distribution,
    ///         rotate to a stressed distribution via setDistribution, swap the same size
    ///         again. Demonstrates how shape changes alone (constant reserves) move slippage.
    function test_demo_volatilityRotation() public {
        SmartPoolHook.LiquidityBucket[] memory calm = new SmartPoolHook.LiquidityBucket[](2);
        calm[0] = SmartPoolHook.LiquidityBucket({tickLower: -5, tickUpper: 5, weightBps: 8_000});
        calm[1] = SmartPoolHook.LiquidityBucket({tickLower: -30, tickUpper: 30, weightBps: 2_000});
        PoolKey memory key = _initWithDistribution(
            "Volatility-adaptive: CALM phase (80/20 across [-5,5] [-30,30])", calm, 5
        );

        _logSwap(key, true, -100 ether, "ZF1 size 100  t0   [calm]");
        _logSwap(key, true, -1_000 ether, "ZF1 size 1000 t0   [calm]");
        _logSwap(key, true, -5_000 ether, "ZF1 size 5000 t0   [calm]");

        // Rotate to stressed shape mid-life. Same reserves, much wider spread of liquidity.
        SmartPoolHook.LiquidityBucket[] memory stressed = new SmartPoolHook.LiquidityBucket[](3);
        stressed[0] = SmartPoolHook.LiquidityBucket({tickLower: -5, tickUpper: 5, weightBps: 2_500});
        stressed[1] = SmartPoolHook.LiquidityBucket({tickLower: -250, tickUpper: 250, weightBps: 5_000});
        stressed[2] = SmartPoolHook.LiquidityBucket({tickLower: 50, tickUpper: 500, weightBps: 2_500});
        vm.prank(owner);
        hook.setDistribution(key, stressed);
        console2.log("--- rotated distribution to STRESSED (25/50/25) ---");

        _logSwap(key, true, -100 ether, "ZF1 size 100  t0   [stressed]");
        _logSwap(key, true, -1_000 ether, "ZF1 size 1000 t0   [stressed]");
        _logSwap(key, true, -5_000 ether, "ZF1 size 5000 t0   [stressed]");
    }

    // ═══════════════════════════════════════════════════════════════════════════
    //                              HELPERS
    // ═══════════════════════════════════════════════════════════════════════════

    function _initWithDistribution(
        string memory name,
        SmartPoolHook.LiquidityBucket[] memory dist,
        int24 tickSpacing
    ) internal returns (PoolKey memory key) {
        key = PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: tickSpacing,
            hooks: IHooks(address(hook))
        });
        SmartPoolHook.PoolConfig memory cfg = SmartPoolHook.PoolConfig({
            sqrtPriceX96: TickMath.getSqrtPriceAtTick(0),
            pricing: SmartPoolBase.PricingState({bidFeePips: BID_FEE_PIPS, askFeePips: ASK_FEE_PIPS, live: true}),
            distribution: dist,
            allowExternalDeposits: false,
            // No vault: keeps assets as raw ERC-20 so logs reflect distribution alone.
            vault0: IERC4626(address(0)),
            vault1: IERC4626(address(0))
        });
        vm.prank(owner);
        hook.initializePool(key, cfg);

        token0.mint(owner, BOOTSTRAP_AMOUNT);
        token1.mint(owner, BOOTSTRAP_AMOUNT);
        vm.startPrank(owner);
        token0.approve(address(hook), BOOTSTRAP_AMOUNT);
        token1.approve(address(hook), BOOTSTRAP_AMOUNT);
        hook.bootstrap(key, BOOTSTRAP_AMOUNT, BOOTSTRAP_AMOUNT);
        vm.stopPrank();

        // Step a block so we are not literally inside the bootstrap tx.
        vm.roll(block.number + 1);

        console2.log("");
        console2.log("=========================================================");
        console2.log("  DISTRIBUTION:", name);
        console2.log("---------------------------------------------------------");
        console2.log(
            string.concat(
                "  tickSpacing=",
                vm.toString(int256(tickSpacing)),
                "  reserves=",
                vm.toString(BOOTSTRAP_AMOUNT / 1 ether),
                " token0/1 each"
            )
        );
        for (uint256 i; i < dist.length; i++) {
            console2.log(
                string.concat(
                    "  bucket[",
                    vm.toString(i),
                    "] weightBps=",
                    vm.toString(uint256(dist[i].weightBps)),
                    "  range=[",
                    vm.toString(int256(dist[i].tickLower)),
                    ",",
                    vm.toString(int256(dist[i].tickUpper)),
                    "]"
                )
            );
        }
        console2.log("---------------------------------------------------------");
    }

    /// @dev Size ladder: tiny → 1 → 10 → 100 → 500 → 1000 → 5000 t0.
    ///      With a 10k-ether pool, the larger sizes consume real depth and surface
    ///      distribution-shape impact rather than just the flat LP fee. Then a reverse
    ///      pair to show the ask side.
    function _runSwapSeries(PoolKey memory key) internal {
        _logSwap(key, true, -1e15, "ZF1 size 0.001 t0");
        _logSwap(key, true, -1 ether, "ZF1 size 1     t0");
        _logSwap(key, true, -10 ether, "ZF1 size 10    t0");
        _logSwap(key, true, -100 ether, "ZF1 size 100   t0");
        _logSwap(key, true, -500 ether, "ZF1 size 500   t0");
        _logSwap(key, true, -1_000 ether, "ZF1 size 1000  t0");
        _logSwap(key, true, -5_000 ether, "ZF1 size 5000  t0");
        // Reverse direction at tail end — tick will be sub-zero by now; this is a buy of t0.
        _logSwap(key, false, -100 ether, "1F0 size 100   t1");
        _logSwap(key, false, -1_000 ether, "1F0 size 1000  t1");
    }

    /// @dev Run a single swap and log size, in/out (in milli-token units = 1e15 wei),
    ///      slippage in pips (= ppm), and tick before/after.
    function _logSwap(PoolKey memory key, bool zeroForOne, int256 amountIn, string memory label) internal {
        (, int24 tickBefore,,) = manager.getSlot0(key.toId());
        BalanceDelta delta = swap(key, zeroForOne, amountIn, "");
        (, int24 tickAfter,,) = manager.getSlot0(key.toId());

        // From the swapper's perspective: input is the negative leg, output is the positive.
        int128 d0 = delta.amount0();
        int128 d1 = delta.amount1();
        uint256 inAbs = zeroForOne ? _abs(d0) : _abs(d1);
        uint256 outAbs = zeroForOne ? _abs(d1) : _abs(d0);

        // Slippage in pips (= ppm) = (in - out) / in, signed. Negative = favorable execution
        // for the swapper (price improved relative to 1:1 because the pool drifted in the
        // swapper's direction earlier). Both currencies are 18-decimal so the ratio is clean.
        bool favorable = outAbs > inAbs;
        uint256 absDiff = favorable ? outAbs - inAbs : inAbs - outAbs;
        uint256 slipPips = inAbs > 0 ? (absDiff * 1_000_000) / inAbs : 0;

        console2.log(
            string.concat(
                "  ",
                label,
                " | in=",
                vm.toString(inAbs / 1e15),
                "e15  out=",
                vm.toString(outAbs / 1e15),
                "e15  slip=",
                favorable ? "-" : "",
                vm.toString(slipPips),
                "pips  tick:",
                vm.toString(int256(tickBefore)),
                "->",
                vm.toString(int256(tickAfter))
            )
        );
    }

    function _abs(int128 x) private pure returns (uint256) {
        return x < 0 ? uint256(int256(-x)) : uint256(int256(x));
    }
}
