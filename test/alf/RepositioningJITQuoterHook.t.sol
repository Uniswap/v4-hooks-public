// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {console2} from "forge-std/console2.sol";
import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {Constants} from "@uniswap/v4-core/test/utils/Constants.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {RepositioningJITQuoterHook} from "../../src/alf/RepositioningJITQuoterHook.sol";

contract RepositioningJITQuoterHookTest is Test, Deployers {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;
    using StateLibrary for IPoolManager;

    RepositioningJITQuoterHook public hook;

    address owner = makeAddr("owner");

    PoolKey testPoolKey;

    uint24 constant BID_FEE_PIPS = 20_000; // 2%
    uint24 constant ASK_FEE_PIPS = 50_000; // 5%
    int24 constant TICK_WIDTH = 120;
    uint128 constant REPO_LIQUIDITY = 100_000e18;
    int24 constant TARGET_TICK = 0;

    function setUp() public {
        deployFreshManagerAndRouters();
        deployMintAndApprove2Currencies();

        // Deploy hook at flag-mined address
        uint160 flags = uint160(
            Hooks.AFTER_INITIALIZE_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG
                | Hooks.BEFORE_SWAP_FLAG
        );
        hook = RepositioningJITQuoterHook(
            address(uint160(uint256(type(uint160).max) & clearAllHookPermissionsMask | flags))
        );
        deployCodeTo("RepositioningJITQuoterHook", abi.encode(manager, uint32(100_000), owner), address(hook));

        // Create pool key
        testPoolKey = PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: 60,
            hooks: IHooks(address(hook))
        });

        // Initialize pool (afterInitialize registers in index)
        manager.initialize(testPoolKey, Constants.SQRT_PRICE_1_1);

        // Fund hook with ERC-20 tokens via owner deposit
        MockERC20 token0 = MockERC20(Currency.unwrap(currency0));
        MockERC20 token1 = MockERC20(Currency.unwrap(currency1));

        token0.transfer(owner, 1_000_000e18);
        token1.transfer(owner, 1_000_000e18);

        vm.startPrank(owner);
        token0.approve(address(hook), type(uint256).max);
        token1.approve(address(hook), type(uint256).max);
        hook.deposit(currency0, 500_000e18);
        hook.deposit(currency1, 500_000e18);

        // Set config
        hook.updateConfig(
            testPoolKey,
            RepositioningJITQuoterHook.RepositioningConfig({
                targetTick: TARGET_TICK,
                tickWidth: TICK_WIDTH,
                liquidity: REPO_LIQUIDITY,
                bidFeePips: BID_FEE_PIPS,
                askFeePips: ASK_FEE_PIPS,
                bidCoefficient: 0.98e18,
                askCoefficient: 0.95e18,
                live: true
            })
        );
        vm.stopPrank();
    }

    // ══════════════════════════════════════════════════════════════════════
    // afterInitialize — Index Registration
    // ══════════════════════════════════════════════════════════════════════

    // (registry test removed — ALFQuoterRegistry no longer exists)

    // ══════════════════════════════════════════════════════════════════════
    // Indicative Quotes
    // ══════════════════════════════════════════════════════════════════════

    function test_getIndicativeQuote_zeroForOne() public view {
        uint256 quote = hook.getIndicativeQuote(testPoolKey, true, -1e18, "");
        // bidCoefficient = 0.98e18 → 1e18 * 0.98e18 / 1e18 = 0.98e18
        assertEq(quote, 0.98e18);
    }

    function test_getIndicativeQuote_oneForZero() public view {
        uint256 quote = hook.getIndicativeQuote(testPoolKey, false, -1e18, "");
        // askCoefficient = 0.95e18
        assertEq(quote, 0.95e18);
    }

    function test_getIndicativeQuote_unlivePool_returnsZero() public {
        vm.prank(owner);
        hook.setPoolLive(testPoolKey, false);

        uint256 quote = hook.getIndicativeQuote(testPoolKey, true, -1e18, "");
        assertEq(quote, 0);
    }

    // ══════════════════════════════════════════════════════════════════════
    // Swap Lifecycle — Position Creation & Repositioning
    // ══════════════════════════════════════════════════════════════════════

    function test_firstSwap_createsPosition() public {
        // Before swap, no active position
        (,, uint128 liqBefore) = hook.activePosition(testPoolKey.toId());
        assertEq(liqBefore, 0);

        // Execute swap — triggers beforeSwap which creates position
        swap(testPoolKey, true, -1e18, "");

        // Active position should now exist
        (int24 tickLower, int24 tickUpper, uint128 liqAfter) = hook.activePosition(testPoolKey.toId());
        assertEq(liqAfter, REPO_LIQUIDITY);
        assertEq(tickLower, -120);
        assertEq(tickUpper, 120);
    }

    function test_LP_persistsAfterSwap() public {
        swap(testPoolKey, true, -1e18, "");

        // Pool should have non-zero liquidity from the hook's position
        uint128 poolLiq = manager.getLiquidity(testPoolKey.toId());
        assertGt(poolLiq, 0, "pool should have liquidity after swap");
    }

    function test_swap_producesOutput() public {
        BalanceDelta delta = swap(testPoolKey, true, -1e18, "");
        assertEq(delta.amount0(), -1e18, "should spend token0");
        assertApproxEqAbs(delta.amount1(), 0.98e18, 1e14, "should receive token1");
    }

    function test_swap_feeOverride_zeroForOne() public {
        // BID_FEE_PIPS = 20_000 (2%)
        // With 1e18 exact input, we expect ~0.98e18 output (minus fee)
        BalanceDelta delta = swap(testPoolKey, true, -1e18, "");
        uint256 output = uint256(int256(delta.amount1()));
        assertApproxEqAbs(output, 0.98e18, 1e14, "output should be ~0.98e18 (2% fee) minus price impact");
    }

    function test_consecutiveSwaps_repositionLP() public {
        // First swap creates position
        swap(testPoolKey, true, -1e18, "");
        (int24 tl1, int24 tu1,) = hook.activePosition(testPoolKey.toId());

        // Update target tick
        vm.prank(owner);
        hook.updateConfig(
            testPoolKey,
            RepositioningJITQuoterHook.RepositioningConfig({
                targetTick: 60,
                tickWidth: TICK_WIDTH,
                liquidity: REPO_LIQUIDITY,
                bidFeePips: BID_FEE_PIPS,
                askFeePips: ASK_FEE_PIPS,
                bidCoefficient: 0.98e18,
                askCoefficient: 0.95e18,
                live: true
            })
        );

        // Second swap repositions to new target
        swap(testPoolKey, true, -1e18, "");
        (int24 tl2, int24 tu2,) = hook.activePosition(testPoolKey.toId());

        // Position should have moved
        assertGt(tl2, tl1, "tickLower should increase with higher target");
        assertGt(tu2, tu1, "tickUpper should increase with higher target");
        // New center: targetTick=60, tickWidth=120 → [-60, 180]
        assertEq(tl2, -60);
        assertEq(tu2, 180);
    }

    function test_unlivePool_noRepositioning() public {
        vm.prank(owner);
        hook.setPoolLive(testPoolKey, false);

        // Swap should succeed but hook returns ZERO_DELTA (no LP, no fee override)
        (,, uint128 liqBefore) = hook.activePosition(testPoolKey.toId());
        assertEq(liqBefore, 0);

        // Pool has no liquidity → swap will be a no-op (zero output)
        BalanceDelta delta = swap(testPoolKey, true, -1e18, "");
        // No LP → no output
        assertEq(delta.amount1(), 0, "no output when unlive");

        (,, uint128 liqAfter) = hook.activePosition(testPoolKey.toId());
        assertEq(liqAfter, 0, "no position created when unlive");
    }

    // ══════════════════════════════════════════════════════════════════════
    // LP Access Control
    // ══════════════════════════════════════════════════════════════════════

    function test_blocksExternalLP_add() public {
        // Hook's LiquidityNotAllowed is wrapped by PM's WrappedError
        vm.expectRevert();
        modifyLiquidityRouter.modifyLiquidity(
            testPoolKey, ModifyLiquidityParams({tickLower: -60, tickUpper: 60, liquidityDelta: 1e18, salt: 0}), ""
        );
    }

    function test_blocksExternalLP_remove() public {
        vm.expectRevert();
        modifyLiquidityRouter.modifyLiquidity(
            testPoolKey, ModifyLiquidityParams({tickLower: -60, tickUpper: 60, liquidityDelta: -1e18, salt: 0}), ""
        );
    }

    // ══════════════════════════════════════════════════════════════════════
    // Inventory Management
    // ══════════════════════════════════════════════════════════════════════

    function test_deposit_withdraw() public {
        MockERC20 token0 = MockERC20(Currency.unwrap(currency0));
        uint256 hookBalBefore = token0.balanceOf(address(hook));

        // Withdraw some
        vm.prank(owner);
        hook.withdraw(currency0, 100e18);
        assertEq(token0.balanceOf(address(hook)), hookBalBefore - 100e18);
        assertEq(token0.balanceOf(owner), 500_000e18 + 100e18); // owner had 1M - 500K deposited = 500K, + 100

        // Deposit back
        vm.prank(owner);
        hook.deposit(currency0, 100e18);
        assertEq(token0.balanceOf(address(hook)), hookBalBefore);
    }

    function test_emergencyWithdrawPosition() public {
        // First swap creates position
        swap(testPoolKey, true, -1e18, "");
        (,, uint128 liqBefore) = hook.activePosition(testPoolKey.toId());
        assertGt(liqBefore, 0, "position should exist");

        // Emergency withdraw
        vm.prank(owner);
        hook.emergencyWithdrawPosition(testPoolKey);

        // Position cleared
        (,, uint128 liqAfter) = hook.activePosition(testPoolKey.toId());
        assertEq(liqAfter, 0, "position should be cleared");

        // Pool should have no liquidity
        uint128 poolLiq = manager.getLiquidity(testPoolKey.toId());
        assertEq(poolLiq, 0, "pool should have no liquidity after emergency withdrawal");
    }

    // ══════════════════════════════════════════════════════════════════════
    // Owner Functions
    // ══════════════════════════════════════════════════════════════════════

    function test_updateConfig_onlyOwner() public {
        RepositioningJITQuoterHook.RepositioningConfig memory config = RepositioningJITQuoterHook.RepositioningConfig({
            targetTick: 0,
            tickWidth: 60,
            liquidity: 1e18,
            bidFeePips: 1000,
            askFeePips: 1000,
            bidCoefficient: 1e18,
            askCoefficient: 1e18,
            live: true
        });

        vm.expectRevert();
        hook.updateConfig(testPoolKey, config);
    }

    function test_setPoolLive_onlyOwner() public {
        vm.expectRevert();
        hook.setPoolLive(testPoolKey, false);
    }

    function test_setPriceSigner_onlyOwner() public {
        vm.expectRevert();
        hook.setPriceSigner(address(1));
    }

    function test_deposit_onlyOwner() public {
        vm.expectRevert();
        hook.deposit(currency0, 1e18);
    }

    function test_withdraw_onlyOwner() public {
        vm.expectRevert();
        hook.withdraw(currency0, 1e18);
    }

    function test_emergencyWithdrawPosition_onlyOwner() public {
        vm.expectRevert();
        hook.emergencyWithdrawPosition(testPoolKey);
    }

    // ══════════════════════════════════════════════════════════════════════
    // Settlement & Balance Tracking
    // ══════════════════════════════════════════════════════════════════════

    function test_hookSettlement_firstSwapReducesBalance() public {
        MockERC20 token0 = MockERC20(Currency.unwrap(currency0));
        MockERC20 token1 = MockERC20(Currency.unwrap(currency1));
        uint256 bal0Before = token0.balanceOf(address(hook));
        uint256 bal1Before = token1.balanceOf(address(hook));

        // First swap — hook adds LP (should spend tokens)
        swap(testPoolKey, true, -1e18, "");

        uint256 bal0After = token0.balanceOf(address(hook));
        uint256 bal1After = token1.balanceOf(address(hook));

        // Hook should have spent tokens to fund the LP position
        assertLt(bal0After + bal1After, bal0Before + bal1Before, "hook should spend tokens for LP");
    }

    function test_hookSettlement_repositionNetDelta() public {
        MockERC20 token0 = MockERC20(Currency.unwrap(currency0));
        MockERC20 token1 = MockERC20(Currency.unwrap(currency1));

        // First swap creates position
        swap(testPoolKey, true, -1e18, "");
        uint256 bal0After1 = token0.balanceOf(address(hook));
        uint256 bal1After1 = token1.balanceOf(address(hook));

        // Second swap repositions (same target, so net delta should be small)
        swap(testPoolKey, false, -1e18, "");
        uint256 bal0After2 = token0.balanceOf(address(hook));
        uint256 bal1After2 = token1.balanceOf(address(hook));

        // Balance change from repositioning should be relatively small
        // (remove returns ~same as what add costs, plus fees earned)
        uint256 totalBefore = bal0After1 + bal1After1;
        uint256 totalAfter = bal0After2 + bal1After2;
        // The hook should have gained some fees from the first swap's LP
        assertGe(totalAfter, totalBefore - 1e18, "repositioning should have small net cost");
    }

    // ══════════════════════════════════════════════════════════════════════
    // EIP-712 Signed Curve Updates
    // ══════════════════════════════════════════════════════════════════════

    // ══════════════════════════════════════════════════════════════════════
    // Explicit Amount Assertions — Multiple Price Points
    // ══════════════════════════════════════════════════════════════════════

    /// @dev Deploy a new pool at a given sqrtPrice with the hook configured.
    function _setupPoolAtPrice(uint160 sqrtPrice, int24 targetTick, int24 tickSpacing_, int24 tickWidth_)
        internal
        returns (PoolKey memory poolKey)
    {
        poolKey = PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: tickSpacing_,
            hooks: IHooks(address(hook))
        });

        manager.initialize(poolKey, sqrtPrice);

        vm.prank(owner);
        hook.updateConfig(
            poolKey,
            RepositioningJITQuoterHook.RepositioningConfig({
                targetTick: targetTick,
                tickWidth: tickWidth_,
                liquidity: REPO_LIQUIDITY,
                bidFeePips: BID_FEE_PIPS,
                askFeePips: ASK_FEE_PIPS,
                bidCoefficient: 0.98e18,
                askCoefficient: 0.95e18,
                live: true
            })
        );
    }

    // ── 1:1 Price — oneForZero (askFee = 5%) ──

    function test_swap_1_1_oneForZero_output() public {
        // At 1:1 price, selling token1 for token0, 5% ask fee
        // output ≈ input * (1 - 0.05) = 0.95e18
        BalanceDelta delta = swap(testPoolKey, false, -1e18, "");
        assertEq(delta.amount1(), -1e18, "should spend 1 token1");
        uint256 output = uint256(int256(delta.amount0()));
        assertApproxEqAbs(output, 0.95e18, 1e14, "output ~0.95 at 1:1 with 5% ask fee");
    }

    // ── 2:1 Price — 1 token0 = 2 token1 ──

    function test_swap_2_1_zeroForOne_output() public {
        PoolKey memory key21 = _setupPoolAtPrice(Constants.SQRT_PRICE_2_1, int24(6960), int24(120), TICK_WIDTH);

        BalanceDelta delta = swap(key21, true, -1e18, "");
        assertEq(delta.amount0(), -1e18, "should spend 1 token0");
        uint256 output = uint256(int256(delta.amount1()));
        // output ≈ 1 * 2 * (1 - 0.02) = 1.96e18
        assertApproxEqAbs(output, 1.96e18, 5e14, "output ~1.96 at 2:1 with 2% bid fee");
    }

    function test_swap_2_1_oneForZero_output() public {
        PoolKey memory key21 = _setupPoolAtPrice(Constants.SQRT_PRICE_2_1, int24(6960), int24(120), TICK_WIDTH);

        BalanceDelta delta = swap(key21, false, -1e18, "");
        assertEq(delta.amount1(), -1e18, "should spend 1 token1");
        uint256 output = uint256(int256(delta.amount0()));
        // output ≈ 1 / 2 * (1 - 0.05) = 0.475e18
        assertApproxEqAbs(output, 0.475e18, 5e14, "output ~0.475 at 2:1 with 5% ask fee");
    }

    function test_swap_2_1_positionRange() public {
        PoolKey memory key21 = _setupPoolAtPrice(Constants.SQRT_PRICE_2_1, int24(6960), int24(120), TICK_WIDTH);
        swap(key21, true, -1e18, "");

        (int24 tickLower, int24 tickUpper, uint128 liq) = hook.activePosition(key21.toId());
        assertEq(liq, REPO_LIQUIDITY);
        // _computeTickRange(6960, 120, 120): lower = (6840/120)*120 = 6840, upper = (7080/120)*120 = 7080
        assertEq(tickLower, int24(6840));
        assertEq(tickUpper, int24(7080));
    }

    // ── 4:1 Price — 1 token0 = 4 token1 ──

    function test_swap_4_1_zeroForOne_output() public {
        // tickSpacing=10 so range [13740,13980] contains initial tick ~13863
        PoolKey memory key41 = _setupPoolAtPrice(Constants.SQRT_PRICE_4_1, int24(13860), int24(10), TICK_WIDTH);

        BalanceDelta delta = swap(key41, true, -1e18, "");
        assertEq(delta.amount0(), -1e18, "should spend 1 token0");
        uint256 output = uint256(int256(delta.amount1()));
        // output ≈ 1 * 4 * (1 - 0.02) = 3.92e18
        assertApproxEqAbs(output, 3.92e18, 5e14, "output ~3.92 at 4:1 with 2% bid fee");
    }

    function test_swap_4_1_oneForZero_output() public {
        PoolKey memory key41 = _setupPoolAtPrice(Constants.SQRT_PRICE_4_1, int24(13860), int24(10), TICK_WIDTH);

        BalanceDelta delta = swap(key41, false, -1e18, "");
        assertEq(delta.amount1(), -1e18, "should spend 1 token1");
        uint256 output = uint256(int256(delta.amount0()));
        // output ≈ 1 / 4 * (1 - 0.05) = 0.2375e18
        assertApproxEqAbs(output, 0.2375e18, 5e14, "output ~0.2375 at 4:1 with 5% ask fee");
    }

    function test_swap_4_1_positionRange() public {
        PoolKey memory key41 = _setupPoolAtPrice(Constants.SQRT_PRICE_4_1, int24(13860), int24(10), TICK_WIDTH);
        swap(key41, true, -1e18, "");

        (int24 tickLower, int24 tickUpper, uint128 liq) = hook.activePosition(key41.toId());
        assertEq(liq, REPO_LIQUIDITY);
        // _computeTickRange(13860, 120, 10): lower = (13740/10)*10 = 13740, upper = (13980/10)*10 = 13980
        assertEq(tickLower, int24(13740));
        assertEq(tickUpper, int24(13980));
    }

    // ── 1:2 Price — 1 token0 = 0.5 token1 ──

    function test_swap_1_2_zeroForOne_output() public {
        // tickSpacing=30 so we get unique PoolId
        PoolKey memory key12 = _setupPoolAtPrice(Constants.SQRT_PRICE_1_2, int24(-6930), int24(30), TICK_WIDTH);

        BalanceDelta delta = swap(key12, true, -1e18, "");
        assertEq(delta.amount0(), -1e18, "should spend 1 token0");
        uint256 output = uint256(int256(delta.amount1()));
        // output ≈ 1 * 0.5 * (1 - 0.02) = 0.49e18
        assertApproxEqAbs(output, 0.49e18, 5e14, "output ~0.49 at 1:2 with 2% bid fee");
    }

    function test_swap_1_2_oneForZero_output() public {
        PoolKey memory key12 = _setupPoolAtPrice(Constants.SQRT_PRICE_1_2, int24(-6930), int24(30), TICK_WIDTH);

        BalanceDelta delta = swap(key12, false, -1e18, "");
        assertEq(delta.amount1(), -1e18, "should spend 1 token1");
        uint256 output = uint256(int256(delta.amount0()));
        // output ≈ 1 * 2 * (1 - 0.05) = 1.9e18
        assertApproxEqAbs(output, 1.9e18, 5e14, "output ~1.9 at 1:2 with 5% ask fee");
    }

    // ══════════════════════════════════════════════════════════════════════
    // EIP-712 Signed Curve Updates
    // ══════════════════════════════════════════════════════════════════════

    function test_curveUpdate_expired_reverts() public {
        // First do a swap to have a live pool
        swap(testPoolKey, true, -1e18, "");

        // Try expired update via hookData
        RepositioningJITQuoterHook.RepositioningConfig memory newConfig = RepositioningJITQuoterHook.RepositioningConfig({
            targetTick: 60,
            tickWidth: TICK_WIDTH,
            liquidity: REPO_LIQUIDITY,
            bidFeePips: BID_FEE_PIPS,
            askFeePips: ASK_FEE_PIPS,
            bidCoefficient: 0.98e18,
            askCoefficient: 0.95e18,
            live: true
        });

        uint256 expiredDeadline = block.timestamp - 1;
        bytes memory curveUpdateData = abi.encode(newConfig, testPoolKey.toId(), expiredDeadline, bytes("fake_sig"));

        // Encode as ALFHookData (attestationData, curveUpdateData)
        bytes memory hookData = abi.encode(bytes(""), curveUpdateData);

        // ExpiredUpdate is wrapped by PM's WrappedError
        vm.expectRevert();
        swap(testPoolKey, true, -0.1e18, hookData);
    }
}
