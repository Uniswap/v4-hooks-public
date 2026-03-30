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
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {ERC20} from "solmate/src/tokens/ERC20.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {SmartPoolHook} from "../../src/alf/SmartPoolHook.sol";
import {SpreadQuoterBase} from "../../src/alf/base/SpreadQuoterBase.sol";
import {MockERC4626} from "./mocks/MockERC4626.sol";

/// @title SmartPoolHookQuoteFidelity
/// @notice Validates that getIndicativeQuote matches actual swap execution across
///         multi-range liquidity distributions at various swap sizes, directions,
///         and after price movements.
contract SmartPoolHookQuoteFidelityTest is Test, Deployers {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;
    using StateLibrary for IPoolManager;
    using BalanceDeltaLibrary for BalanceDelta;

    SmartPoolHook public hook;

    MockERC4626 public vault0;
    MockERC4626 public vault1;

    address owner = makeAddr("owner");

    PoolKey testPoolKey;
    PoolId testPoolId;

    MockERC20 token0;
    MockERC20 token1;

    // 5 bps bid/ask — meaningful but small enough for tight fidelity
    uint24 constant BID_FEE_PIPS = 500;
    uint24 constant ASK_FEE_PIPS = 500;

    // Tolerance: 1 wei absolute. The virtual tick walk mirrors the CLAMM exactly, so
    // quotes should match to the wei. Using absolute rather than relative tolerance to
    // catch even trivial regressions.
    uint256 constant ABS_TOLERANCE = 1;

    function setUp() public {
        deployFreshManagerAndRouters();
        deployMintAndApprove2Currencies();

        token0 = MockERC20(Currency.unwrap(currency0));
        token1 = MockERC20(Currency.unwrap(currency1));

        vault0 = new MockERC4626(ERC20(address(token0)));
        vault1 = new MockERC4626(ERC20(address(token1)));

        // Deploy hook at flag-mined address
        uint160 flags = uint160(
            Hooks.BEFORE_INITIALIZE_FLAG | Hooks.AFTER_INITIALIZE_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG
                | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG
        );
        hook = SmartPoolHook(address(uint160(uint256(type(uint160).max) & clearAllHookPermissionsMask | flags)));
        deployCodeTo("SmartPoolHook", abi.encode(manager, uint32(100_000), owner), address(hook));

        // Initialize pool with 3-bucket distribution at tick 0 (1:1 stablecoin price)
        testPoolKey = PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: 10,
            hooks: IHooks(address(hook))
        });

        vm.startPrank(owner);
        hook.initializePool(testPoolKey, _multiBucketConfig());
        vm.stopPrank();

        testPoolId = testPoolKey.toId();

        // Deposit large amount so swaps of various sizes exercise different buckets
        _depositAsOperator(10_000e18);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    //                        SYMMETRIC DISTRIBUTION TESTS
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Small swap stays within the tight bucket [-10,10]. No boundary crossings.
    function test_quoteFidelity_smallSwap_zeroForOne() public {
        _assertQuoteFidelity(true, -100e18);
    }

    /// @notice Medium swap pushes through the tight bucket into the medium range [-30,30].
    function test_quoteFidelity_mediumSwap_zeroForOne() public {
        _assertQuoteFidelity(true, -3_000e18);
    }

    /// @notice Large swap pushes through tight and medium into the wide range [-60,60].
    function test_quoteFidelity_largeSwap_zeroForOne() public {
        _assertQuoteFidelity(true, -8_000e18);
    }

    /// @notice Very large swap nearly exhausts all liquidity across all ranges.
    function test_quoteFidelity_veryLargeSwap_zeroForOne() public {
        _assertQuoteFidelity(true, -9_500e18);
    }

    // ──── Both Directions ────

    /// @notice Small swap in the oneForZero direction.
    function test_quoteFidelity_smallSwap_oneForZero() public {
        _assertQuoteFidelity(false, -100e18);
    }

    /// @notice Medium swap in the oneForZero direction.
    function test_quoteFidelity_mediumSwap_oneForZero() public {
        _assertQuoteFidelity(false, -3_000e18);
    }

    // ──── Exact Output ────

    /// @notice Exact output swap: positive amountSpecified means exact output.
    ///         getIndicativeQuote returns the filled output amount for exact-output.
    ///         Verify it matches the actual output from the swap delta.
    function test_quoteFidelity_exactOutput_zeroForOne() public {
        _assertQuoteFidelity(true, 100e18);
    }

    /// @notice Exact output in oneForZero direction.
    function test_quoteFidelity_exactOutput_oneForZero() public {
        _assertQuoteFidelity(false, 100e18);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    //                        ASYMMETRIC DISTRIBUTION TESTS
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Verify quote accuracy with an asymmetric distribution:
    ///         50% in [-60,-10], 30% in [-10,10], 20% in [10,60].
    function test_quoteFidelity_asymmetricDistribution() public {
        // Reconfigure to asymmetric distribution
        SmartPoolHook.LiquidityBucket[] memory dist = new SmartPoolHook.LiquidityBucket[](3);
        dist[0] = SmartPoolHook.LiquidityBucket({tickLower: -60, tickUpper: -10, weightBps: 5000});
        dist[1] = SmartPoolHook.LiquidityBucket({tickLower: -10, tickUpper: 10, weightBps: 3000});
        dist[2] = SmartPoolHook.LiquidityBucket({tickLower: 10, tickUpper: 60, weightBps: 2000});

        vm.prank(owner);
        hook.setDistribution(testPoolKey, dist);

        // Snapshot state after distribution change so each sub-test starts fresh
        uint256 snap = vm.snapshotState();

        _assertQuoteFidelity(true, -100e18);
        vm.revertToState(snap);

        _assertQuoteFidelity(true, -3_000e18);
        vm.revertToState(snap);

        _assertQuoteFidelity(false, -100e18);
        vm.revertToState(snap);

        _assertQuoteFidelity(false, -3_000e18);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    //                        POST-PRICE-MOVEMENT TESTS
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice After a large swap moves the price to ~ tick -25, verify quote accuracy
    ///         for a subsequent swap at the new price.
    function test_quoteFidelity_afterPriceMovement() public {
        // Move price with a large zeroForOne swap
        swap(testPoolKey, true, -5_000e18, "");

        (, int24 tickAfter,,) = manager.getSlot0(testPoolId);
        // Sanity: price has moved significantly
        assertLt(tickAfter, -5, "Price should have moved down");

        // Snapshot at the new price
        uint256 snap = vm.snapshotState();

        // Verify fidelity at the new price for subsequent swaps
        _assertQuoteFidelity(true, -500e18);
        vm.revertToState(snap);

        _assertQuoteFidelity(false, -500e18);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    //                        HELPERS
    // ═══════════════════════════════════════════════════════════════════════════

    /// @dev Core fidelity assertion: compare indicative quote to actual swap output.
    ///
    ///      getIndicativeQuote always returns the *output* side of the swap:
    ///        - Exact input  (amountSpecified < 0): returns the estimated output received
    ///        - Exact output (amountSpecified > 0): returns the filled output amount
    ///
    ///      We extract the corresponding output from the actual swap's BalanceDelta.
    function _assertQuoteFidelity(bool zeroForOne, int256 amountSpecified) internal {
        // 1. Get indicative quote
        uint256 quoted = hook.getIndicativeQuote(testPoolKey, zeroForOne, amountSpecified, "");
        assertGt(quoted, 0, "Quote should be non-zero");

        // 2. Execute actual swap
        BalanceDelta delta = swap(testPoolKey, zeroForOne, amountSpecified, "");

        // 3. Extract the actual output amount from the swap delta.
        //    Deployers.swap returns deltas from the swapper's perspective:
        //      zeroForOne: amount0 < 0 (input paid), amount1 > 0 (output received)
        //      oneForZero: amount1 < 0 (input paid), amount0 > 0 (output received)
        //    The output is always the positive side.
        uint256 actual;
        if (zeroForOne) {
            actual = uint256(int256(delta.amount1()));
        } else {
            actual = uint256(int256(delta.amount0()));
        }

        // 4. Assert within tolerance (1 wei absolute — the virtual tick walk is exact)
        assertApproxEqAbs(quoted, actual, ABS_TOLERANCE, "Quote/actual mismatch");

        console2.log("Direction:", zeroForOne ? "zeroForOne" : "oneForZero");
        console2.log("Amount specified:", amountSpecified < 0 ? "exact-in" : "exact-out");
        console2.log("Quoted:", quoted);
        console2.log("Actual:", actual);
    }

    // ──── Config Helpers ────

    function _multiBucketConfig() internal view returns (SmartPoolHook.PoolConfig memory) {
        SmartPoolHook.LiquidityBucket[] memory dist = new SmartPoolHook.LiquidityBucket[](3);
        dist[0] = SmartPoolHook.LiquidityBucket({tickLower: -10, tickUpper: 10, weightBps: 7500});
        dist[1] = SmartPoolHook.LiquidityBucket({tickLower: -30, tickUpper: 30, weightBps: 1500});
        dist[2] = SmartPoolHook.LiquidityBucket({tickLower: -60, tickUpper: 60, weightBps: 1000});
        return SmartPoolHook.PoolConfig({
            sqrtPriceX96: TickMath.getSqrtPriceAtTick(0),
            pricing: SpreadQuoterBase.PricingState({bidFeePips: BID_FEE_PIPS, askFeePips: ASK_FEE_PIPS, live: true}),
            distribution: dist,
            allowExternalDeposits: false,
            vault0: IERC4626(address(vault0)),
            vault1: IERC4626(address(vault1))
        });
    }

    function _depositAsOperator(uint256 amount) internal {
        (uint256 need0, uint256 need1) = hook.previewDeposit(testPoolKey, amount);
        token0.mint(owner, need0);
        token1.mint(owner, need1);
        vm.startPrank(owner);
        token0.approve(address(hook), need0);
        token1.approve(address(hook), need1);
        hook.addLiquidity(testPoolKey, amount);
        vm.stopPrank();
    }
}
