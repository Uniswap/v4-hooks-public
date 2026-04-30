// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {ERC20} from "solmate/src/tokens/ERC20.sol";

import {SmartPoolHook} from "../../src/alf/SmartPoolHook.sol";
import {SmartPoolBase} from "../../src/alf/base/SmartPoolBase.sol";
import {PoolVault} from "../../src/alf/base/PoolVault.sol";
import {ALFHookData} from "../../src/alf/interfaces/IALFHook.sol";
import {MockERC4626} from "./mocks/MockERC4626.sol";

/// @title SmartPoolHookTest
/// @notice End-to-end tests for SmartPoolHook covering pool lifecycle, JIT execution,
///         token compatibility, multi-pool isolation, reentrancy, pricing-state syncing,
///         and quote-vs-execution fidelity.
contract SmartPoolHookTest is Test, Deployers {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;
    using StateLibrary for IPoolManager;
    using BalanceDeltaLibrary for BalanceDelta;

    SmartPoolHook public hook;

    MockERC4626 public vault0;
    MockERC4626 public vault1;

    address owner = makeAddr("owner");
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address charlie = makeAddr("charlie");

    PoolKey testPoolKey;
    PoolId testPoolId;

    MockERC20 token0;
    MockERC20 token1;

    uint24 constant BID_FEE_PIPS = 1_000; // 0.1%
    uint24 constant ASK_FEE_PIPS = 1_000;

    /// @dev Exact-output spot checks still assert to the wei; broad quote/execution tests use
    ///      a small relative tolerance because SmartPool now uses a compact indicative quote.
    uint256 constant ABS_TOLERANCE = 1;
    uint256 constant INDICATIVE_REL_TOLERANCE = 5e14; // 5 bps

    function setUp() public {
        deployFreshManagerAndRouters();
        deployMintAndApprove2Currencies();

        token0 = MockERC20(Currency.unwrap(currency0));
        token1 = MockERC20(Currency.unwrap(currency1));

        vault0 = new MockERC4626(ERC20(address(token0)));
        vault1 = new MockERC4626(ERC20(address(token1)));

        // Deploy hook at flag-mined address.
        uint160 flags = uint160(
            Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG
                | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG
        );
        hook = SmartPoolHook(address(uint160(uint256(type(uint160).max) & clearAllHookPermissionsMask | flags)));
        deployCodeTo("SmartPoolHook", abi.encode(manager, uint32(100_000), owner), address(hook));

        testPoolKey = PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: 10,
            hooks: IHooks(address(hook))
        });

        vm.prank(owner);
        hook.initializePool(testPoolKey, _defaultConfig());

        testPoolId = testPoolKey.toId();
    }

    // ═══════════════════════════════════════════════════════════════════════════
    //                              HELPERS
    // ═══════════════════════════════════════════════════════════════════════════

    function _defaultConfig() internal view returns (SmartPoolHook.PoolConfig memory) {
        SmartPoolHook.LiquidityBucket[] memory dist = new SmartPoolHook.LiquidityBucket[](1);
        dist[0] = SmartPoolHook.LiquidityBucket({tickLower: -10, tickUpper: 10, weightBps: 10_000});
        return SmartPoolHook.PoolConfig({
            sqrtPriceX96: TickMath.getSqrtPriceAtTick(0),
            pricing: SmartPoolBase.PricingState({bidFeePips: BID_FEE_PIPS, askFeePips: ASK_FEE_PIPS, live: true}),
            distribution: dist,
            allowExternalDeposits: false,
            vault0: IERC4626(address(vault0)),
            vault1: IERC4626(address(vault1))
        });
    }

    /// @dev Bootstrap-or-deposit. Bootstraps with `(amount, amount)` if the pool is empty;
    ///      otherwise mints `amount` shares proportionally. Advances one block at the end so
    ///      the same-block-withdraw guard does not block immediate `removeLiquidity` in tests.
    function _depositAsOperator(uint256 amount) internal {
        if (hook.totalShares(testPoolId) == 0) {
            // sqrt(amount * amount) = amount → matching-amount bootstrap shares == amount.
            // MINIMUM_SHARES is locked at address(0); the rest goes to the owner.
            token0.mint(owner, amount);
            token1.mint(owner, amount);
            vm.startPrank(owner);
            token0.approve(address(hook), amount);
            token1.approve(address(hook), amount);
            hook.bootstrap(testPoolKey, amount, amount);
            vm.stopPrank();
            vm.roll(block.number + 1);
            return;
        }
        (uint256 need0, uint256 need1) = hook.previewDeposit(testPoolKey, amount);
        token0.mint(owner, need0);
        token1.mint(owner, need1);
        vm.startPrank(owner);
        token0.approve(address(hook), need0);
        token1.approve(address(hook), need1);
        hook.addLiquidity(testPoolKey, amount, type(uint256).max, type(uint256).max, block.timestamp);
        vm.stopPrank();
        vm.roll(block.number + 1);
    }

    /// @dev Initialize a second pool sharing the same currencies but with a different
    ///      tickSpacing (so it has a distinct PoolId). Used by cross-pool isolation tests.
    function _initSecondaryPool(bool vaulted, uint256 bootstrapAmount)
        internal
        returns (PoolKey memory key, PoolId id)
    {
        SmartPoolHook.LiquidityBucket[] memory dist = new SmartPoolHook.LiquidityBucket[](1);
        dist[0] = SmartPoolHook.LiquidityBucket({tickLower: -60, tickUpper: 60, weightBps: 10_000});
        key = PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: 60,
            hooks: IHooks(address(hook))
        });
        id = key.toId();

        SmartPoolHook.PoolConfig memory cfg = SmartPoolHook.PoolConfig({
            sqrtPriceX96: TickMath.getSqrtPriceAtTick(0),
            pricing: SmartPoolBase.PricingState({bidFeePips: BID_FEE_PIPS, askFeePips: ASK_FEE_PIPS, live: true}),
            distribution: dist,
            allowExternalDeposits: true,
            vault0: vaulted ? IERC4626(address(vault0)) : IERC4626(address(0)),
            vault1: vaulted ? IERC4626(address(vault1)) : IERC4626(address(0))
        });
        vm.prank(owner);
        hook.initializePool(key, cfg);

        if (bootstrapAmount > 0) {
            token0.mint(owner, bootstrapAmount);
            token1.mint(owner, bootstrapAmount);
            vm.startPrank(owner);
            token0.approve(address(hook), bootstrapAmount);
            token1.approve(address(hook), bootstrapAmount);
            hook.bootstrap(key, bootstrapAmount, bootstrapAmount);
            vm.stopPrank();
            vm.roll(block.number + 1);
        }
    }

    /// @dev Mint `amount` shares to `user` on `key`. Requires the pool to be bootstrapped and
    ///      `externalDepositsEnabled` (or `user == owner`). Advances one block at the end.
    function _externalDeposit(PoolKey memory key, address user, uint256 amount) internal {
        (uint256 need0, uint256 need1) = hook.previewDeposit(key, amount);
        token0.mint(user, need0);
        token1.mint(user, need1);
        vm.startPrank(user);
        token0.approve(address(hook), need0);
        token1.approve(address(hook), need1);
        hook.addLiquidity(key, amount, type(uint256).max, type(uint256).max, block.timestamp);
        vm.stopPrank();
        vm.roll(block.number + 1);
    }

    /// @dev Per-pool reserves match what the pool can actually pay out, AND the sum across
    ///      pools never exceeds the contract's physical backing. Captures both "pool A is
    ///      solvent on its own" and "pool A and pool B are jointly solvent" invariants.
    ///
    ///      Backing = raw ERC-20 balance + ERC4626 vault assets + ERC-6909 claims on PM.
    ///      Claims are part of backing because positive JIT deltas mint them via PM, and they
    ///      become ERC-20 again on the next swap's `_redeemPoolClaims`.
    function _assertCrossPoolSolvency(PoolKey memory keyA, PoolKey memory keyB) internal view {
        (uint256 a0, uint256 a1) = hook.getReserves(keyA);
        (uint256 b0, uint256 b1) = hook.getReserves(keyB);
        uint256 backing0 = token0.balanceOf(address(hook))
            + vault0.convertToAssets(vault0.balanceOf(address(hook)))
            + manager.balanceOf(address(hook), currency0.toId());
        uint256 backing1 = token1.balanceOf(address(hook))
            + vault1.convertToAssets(vault1.balanceOf(address(hook)))
            + manager.balanceOf(address(hook), currency1.toId());

        assertLe(a0 + b0, backing0, "currency0 solvency: pools claim more than backed");
        assertLe(a1 + b1, backing1, "currency1 solvency: pools claim more than backed");
    }

    /// @dev Replace the pool's distribution with the canonical 3-bucket fixture used by
    ///      quote-fidelity tests: 75% tight, 15% medium, 10% wide — all symmetric around 0.
    function _useMultiBucketDistribution() internal {
        SmartPoolHook.LiquidityBucket[] memory dist = new SmartPoolHook.LiquidityBucket[](3);
        dist[0] = SmartPoolHook.LiquidityBucket({tickLower: -10, tickUpper: 10, weightBps: 7500});
        dist[1] = SmartPoolHook.LiquidityBucket({tickLower: -30, tickUpper: 30, weightBps: 1500});
        dist[2] = SmartPoolHook.LiquidityBucket({tickLower: -60, tickUpper: 60, weightBps: 1000});
        vm.prank(owner);
        hook.setDistribution(testPoolKey, dist);
    }

    /// @dev Compares `getIndicativeQuote` output to actual swap execution. SmartPool uses a
    ///      compact current-liquidity quote so the deployable hook keeps its composability
    ///      surface without carrying the full virtual tick-walk simulator.
    ///
    ///      Per IALFHook: for exact-input (amountSpecified < 0), the quote returns the
    ///      *output* side. For exact-output (amountSpecified > 0), the quote returns the
    ///      *required input* — assert against the input leg accordingly.
    function _assertQuoteFidelity(bool zeroForOne, int256 amountSpecified) internal {
        uint256 quoted = hook.getIndicativeQuote(testPoolKey, zeroForOne, amountSpecified, "");
        assertGt(quoted, 0, "Quote should be non-zero");

        BalanceDelta delta = swap(testPoolKey, zeroForOne, amountSpecified, "");

        // Deployers.swap returns deltas from the swapper:
        //   zeroForOne: amount0 < 0 (input), amount1 > 0 (output)
        //   oneForZero: amount1 < 0 (input), amount0 > 0 (output)
        uint256 actual;
        if (amountSpecified < 0) {
            actual = zeroForOne ? uint256(int256(delta.amount1())) : uint256(int256(delta.amount0()));
        } else {
            actual = zeroForOne ? uint256(-int256(delta.amount0())) : uint256(-int256(delta.amount1()));
        }

        assertApproxEqRel(quoted, actual, INDICATIVE_REL_TOLERANCE, "Quote/execution mismatch");
    }

    // ═══════════════════════════════════════════════════════════════════════════
    //                          POOL INITIALIZATION
    // ═══════════════════════════════════════════════════════════════════════════

    function test_initializePool_setsConfig() public view {
        assertFalse(hook.externalDepositsEnabled(testPoolId));
        SmartPoolHook.LiquidityBucket[] memory dist = hook.getDistribution(testPoolId);
        assertEq(dist.length, 1);
        assertEq(dist[0].tickLower, -10);
        assertEq(dist[0].tickUpper, 10);
        assertEq(dist[0].weightBps, 10_000);
    }

    function test_initializePool_revertsOnDirectInit() public {
        PoolKey memory key2 = PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: 20,
            hooks: IHooks(address(hook))
        });
        vm.expectRevert();
        manager.initialize(key2, TickMath.getSqrtPriceAtTick(0));
    }

    function test_initializePool_onlyOwner() public {
        PoolKey memory key2 = PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: 20,
            hooks: IHooks(address(hook))
        });
        SmartPoolHook.LiquidityBucket[] memory dist = new SmartPoolHook.LiquidityBucket[](1);
        dist[0] = SmartPoolHook.LiquidityBucket({tickLower: -20, tickUpper: 20, weightBps: 10_000});

        vm.prank(alice);
        vm.expectRevert();
        hook.initializePool(
            key2,
            SmartPoolHook.PoolConfig({
                sqrtPriceX96: TickMath.getSqrtPriceAtTick(0),
                pricing: SmartPoolBase.PricingState({bidFeePips: 100, askFeePips: 100, live: true}),
                distribution: dist,
                allowExternalDeposits: false,
                vault0: IERC4626(address(vault0)),
                vault1: IERC4626(address(vault1))
            })
        );
    }

    function test_initializePool_revertsOnNativeCurrency0() public {
        SmartPoolHook.LiquidityBucket[] memory dist = new SmartPoolHook.LiquidityBucket[](1);
        dist[0] = SmartPoolHook.LiquidityBucket({tickLower: -10, tickUpper: 10, weightBps: 10_000});

        PoolKey memory nativeKey = PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: currency1,
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: 10,
            hooks: IHooks(address(hook))
        });
        SmartPoolHook.PoolConfig memory cfg = SmartPoolHook.PoolConfig({
            sqrtPriceX96: TickMath.getSqrtPriceAtTick(0),
            pricing: SmartPoolBase.PricingState({bidFeePips: BID_FEE_PIPS, askFeePips: ASK_FEE_PIPS, live: true}),
            distribution: dist,
            allowExternalDeposits: false,
            vault0: IERC4626(address(0)),
            vault1: IERC4626(address(0))
        });
        vm.prank(owner);
        vm.expectRevert(SmartPoolHook.NativeNotSupported.selector);
        hook.initializePool(nativeKey, cfg);
    }

    /// @dev Ordering normally puts native ETH at currency0; we test currency1=native defensively.
    function test_initializePool_revertsOnNativeCurrency1() public {
        SmartPoolHook.LiquidityBucket[] memory dist = new SmartPoolHook.LiquidityBucket[](1);
        dist[0] = SmartPoolHook.LiquidityBucket({tickLower: -10, tickUpper: 10, weightBps: 10_000});

        PoolKey memory weirdKey = PoolKey({
            currency0: currency0,
            currency1: Currency.wrap(address(0)),
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: 10,
            hooks: IHooks(address(hook))
        });
        SmartPoolHook.PoolConfig memory cfg = SmartPoolHook.PoolConfig({
            sqrtPriceX96: TickMath.getSqrtPriceAtTick(0),
            pricing: SmartPoolBase.PricingState({bidFeePips: BID_FEE_PIPS, askFeePips: ASK_FEE_PIPS, live: true}),
            distribution: dist,
            allowExternalDeposits: false,
            vault0: IERC4626(address(0)),
            vault1: IERC4626(address(0))
        });
        vm.prank(owner);
        vm.expectRevert(SmartPoolHook.NativeNotSupported.selector);
        hook.initializePool(weirdKey, cfg);
    }

    function test_initializePool_revertsAboveMaxLPFee() public {
        SmartPoolHook.LiquidityBucket[] memory dist = new SmartPoolHook.LiquidityBucket[](1);
        dist[0] = SmartPoolHook.LiquidityBucket({tickLower: -60, tickUpper: 60, weightBps: 10_000});
        PoolKey memory key2 = PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: 60,
            hooks: IHooks(address(hook))
        });
        SmartPoolHook.PoolConfig memory bad = SmartPoolHook.PoolConfig({
            sqrtPriceX96: TickMath.getSqrtPriceAtTick(0),
            pricing: SmartPoolBase.PricingState({
                bidFeePips: LPFeeLibrary.MAX_LP_FEE + 1,
                askFeePips: BID_FEE_PIPS,
                live: true
            }),
            distribution: dist,
            allowExternalDeposits: false,
            vault0: IERC4626(address(0)),
            vault1: IERC4626(address(0))
        });
        vm.prank(owner);
        vm.expectRevert(bytes4(keccak256("FeeOutOfBounds()")));
        hook.initializePool(key2, bad);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    //                          VAULT CONFIGURATION
    // ═══════════════════════════════════════════════════════════════════════════

    function test_vaultsConfiguredAtInit() public view {
        assertEq(address(hook.vaults(testPoolId, currency0)), address(vault0));
        assertEq(address(hook.vaults(testPoolId, currency1)), address(vault1));
    }

    // ═══════════════════════════════════════════════════════════════════════════
    //                              BOOTSTRAP
    // ═══════════════════════════════════════════════════════════════════════════

    function test_bootstrap_onlyOwner() public {
        token0.mint(alice, 1_000e18);
        token1.mint(alice, 1_000e18);
        vm.startPrank(alice);
        token0.approve(address(hook), 1_000e18);
        token1.approve(address(hook), 1_000e18);
        vm.expectRevert();
        hook.bootstrap(testPoolKey, 1_000e18, 1_000e18);
        vm.stopPrank();
    }

    function test_bootstrap_rejectsAmountsBelowMinimumShares() public {
        // sqrt(1 * 1) = 1, well below MINIMUM_SHARES (1000).
        token0.mint(owner, 1);
        token1.mint(owner, 1);
        vm.startPrank(owner);
        token0.approve(address(hook), 1);
        token1.approve(address(hook), 1);
        vm.expectRevert(PoolVault.InsufficientBootstrap.selector);
        hook.bootstrap(testPoolKey, 1, 1);
        vm.stopPrank();
    }

    function test_addLiquidity_revertsBeforeBootstrap() public {
        // Use a fresh pool that isn't bootstrapped yet.
        (PoolKey memory key,) = _initSecondaryPool({vaulted: false, bootstrapAmount: 0});

        token0.mint(alice, 100e18);
        token1.mint(alice, 100e18);
        vm.startPrank(alice);
        token0.approve(address(hook), 100e18);
        token1.approve(address(hook), 100e18);
        vm.expectRevert(PoolVault.PoolNotBootstrapped.selector);
        hook.addLiquidity(key, 100e18, type(uint256).max, type(uint256).max, block.timestamp);
        vm.stopPrank();
    }

    function test_bootstrap_supportsAsymmetricAmounts() public {
        // Fresh unvaulted pool; bootstrap with mismatched scales (think USDC-6dp vs WETH-18dp).
        (PoolKey memory key, PoolId id) = _initSecondaryPool({vaulted: false, bootstrapAmount: 0});

        uint256 a0 = 2000e6; // pretend 6dp
        uint256 a1 = 1e18; // pretend 18dp
        token0.mint(owner, a0);
        token1.mint(owner, a1);
        vm.startPrank(owner);
        token0.approve(address(hook), a0);
        token1.approve(address(hook), a1);
        uint256 shares = hook.bootstrap(key, a0, a1);
        vm.stopPrank();

        // sqrt(2000e6 * 1e18) ≈ 4.47e13; bootstrap shares are independent of decimal scale.
        assertGt(shares, hook.MINIMUM_SHARES());
        assertEq(hook.totalShares(id), shares);
        assertEq(hook.userShares(id, address(0)), hook.MINIMUM_SHARES());
        // Initial ratio reflects what the owner deposited, not 1:1.
        (uint256 r0, uint256 r1) = hook.getReserves(key);
        assertEq(r0, a0);
        assertEq(r1, a1);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    //                       LP DEPOSITS & WITHDRAWALS
    // ═══════════════════════════════════════════════════════════════════════════

    function test_addLiquidity_ownerCanDeposit() public {
        _depositAsOperator(1_000e18);

        // Bootstrap: total shares == sqrt(1000e18 * 1000e18) == 1000e18.
        // MINIMUM_SHARES locked at address(0), the rest credited to the owner.
        assertEq(hook.totalShares(testPoolId), 1_000e18);
        assertEq(hook.userShares(testPoolId, owner), 1_000e18 - hook.MINIMUM_SHARES());
        assertEq(hook.userShares(testPoolId, address(0)), hook.MINIMUM_SHARES());

        // Tokens routed into vaults.
        assertEq(token0.balanceOf(address(hook)), 0);
        assertEq(token1.balanceOf(address(hook)), 0);
        assertGt(vault0.balanceOf(address(hook)), 0);
        assertGt(vault1.balanceOf(address(hook)), 0);
    }

    function test_addLiquidity_externalUserBlocked() public {
        _depositAsOperator(1_000e18);

        token0.mint(alice, 1_000e18);
        token1.mint(alice, 1_000e18);
        vm.startPrank(alice);
        token0.approve(address(hook), 1_000e18);
        token1.approve(address(hook), 1_000e18);
        vm.expectRevert(bytes4(keccak256("Unauthorized()")));
        hook.addLiquidity(testPoolKey, 1_000e18, type(uint256).max, type(uint256).max, block.timestamp);
        vm.stopPrank();
    }

    function test_addLiquidity_externalUserAllowedWhenEnabled() public {
        _depositAsOperator(1_000e18);

        vm.prank(owner);
        hook.setExternalDeposits(testPoolKey, true);

        token0.mint(alice, 1_000e18);
        token1.mint(alice, 1_000e18);
        vm.startPrank(alice);
        token0.approve(address(hook), 1_000e18);
        token1.approve(address(hook), 1_000e18);
        hook.addLiquidity(testPoolKey, 1_000e18, type(uint256).max, type(uint256).max, block.timestamp);
        vm.stopPrank();

        assertEq(hook.userShares(testPoolId, alice), 1_000e18);
    }

    function test_removeLiquidity_returnsTokens() public {
        _depositAsOperator(1_000e18);

        uint256 balBefore0 = token0.balanceOf(owner);
        uint256 balBefore1 = token1.balanceOf(owner);
        uint256 ownerSharesBefore = hook.userShares(testPoolId, owner);

        vm.prank(owner);
        hook.removeLiquidity(testPoolKey, 500e18, 0, 0, block.timestamp);

        assertEq(hook.userShares(testPoolId, owner), ownerSharesBefore - 500e18);
        assertEq(hook.totalShares(testPoolId), 1_000e18 - 500e18);
        assertEq(token0.balanceOf(owner) - balBefore0, 500e18);
        assertEq(token1.balanceOf(owner) - balBefore1, 500e18);
    }

    function test_removeLiquidity_revertsInsufficientShares() public {
        _depositAsOperator(1_000e18);

        vm.prank(owner);
        vm.expectRevert(PoolVault.InsufficientShares.selector);
        hook.removeLiquidity(testPoolKey, 2_000e18, 0, 0, block.timestamp);
    }

    /// @dev Atomic deposit-then-withdraw in the same block is rejected — defends against
    ///      atomic JIT-fee/yield sniping.
    function test_removeLiquidity_revertsInSameBlockAsDeposit() public {
        _depositAsOperator(1_000e18); // bootstrap (advances block)
        vm.prank(owner);
        hook.setExternalDeposits(testPoolKey, true);

        token0.mint(bob, 100e18);
        token1.mint(bob, 100e18);
        vm.startPrank(bob);
        token0.approve(address(hook), 100e18);
        token1.approve(address(hook), 100e18);
        hook.addLiquidity(testPoolKey, 100e18, type(uint256).max, type(uint256).max, block.timestamp);

        vm.expectRevert(PoolVault.SameBlockWithdraw.selector);
        hook.removeLiquidity(testPoolKey, 100e18, 0, 0, block.timestamp);
        vm.stopPrank();
    }

    function test_removeLiquidity_succeedsNextBlock() public {
        _depositAsOperator(1_000e18);
        vm.prank(owner);
        hook.setExternalDeposits(testPoolKey, true);

        token0.mint(bob, 100e18);
        token1.mint(bob, 100e18);
        vm.startPrank(bob);
        token0.approve(address(hook), 100e18);
        token1.approve(address(hook), 100e18);
        hook.addLiquidity(testPoolKey, 100e18, type(uint256).max, type(uint256).max, block.timestamp);
        vm.stopPrank();

        vm.roll(block.number + 1);
        vm.prank(bob);
        hook.removeLiquidity(testPoolKey, 100e18, 0, 0, block.timestamp);
    }

    /// @dev External actors cannot touch v4 LP positions directly — only the hook may.
    function test_externalLP_addBlocked() public {
        vm.expectRevert();
        modifyLiquidityRouter.modifyLiquidity(
            testPoolKey,
            ModifyLiquidityParams({tickLower: -10, tickUpper: 10, liquidityDelta: 1000, salt: bytes32(0)}),
            ""
        );
    }

    // ═══════════════════════════════════════════════════════════════════════════
    //                          JIT SWAP CYCLE
    // ═══════════════════════════════════════════════════════════════════════════

    function test_swap_executesJITCycle() public {
        _depositAsOperator(10_000e18);

        // No LP in the v4 pool before the swap.
        uint128 liquidityBefore = manager.getLiquidity(testPoolId);
        assertEq(liquidityBefore, 0);

        swap(testPoolKey, true, -100e18, "");

        // No LP after the swap either — JIT positions were torn down.
        uint128 liquidityAfter = manager.getLiquidity(testPoolId);
        assertEq(liquidityAfter, 0);

        // Hook still has assets (slightly rebalanced).
        (uint256 reserves0, uint256 reserves1) = hook.getReserves(testPoolKey);
        assertGt(reserves0 + reserves1, 0);
    }

    function test_swap_movesPrice() public {
        _depositAsOperator(10_000e18);

        (, int24 tickBefore,,) = manager.getSlot0(testPoolId);
        swap(testPoolKey, true, -1_000e18, "");
        (, int24 tickAfter,,) = manager.getSlot0(testPoolId);

        assertLt(tickAfter, tickBefore, "zeroForOne should drop tick");
    }

    function test_swap_noopWithoutDeposits() public {
        // No bootstrap → swap must not revert (just produces no output).
        swap(testPoolKey, true, -100e18, "");
    }

    // ═══════════════════════════════════════════════════════════════════════════
    //                        RESERVES & QUOTE VIEWS
    // ═══════════════════════════════════════════════════════════════════════════

    function test_getReserves_returnsVaultBalances() public {
        _depositAsOperator(5_000e18);
        (uint256 r0, uint256 r1) = hook.getReserves(testPoolKey);
        assertEq(r0, 5_000e18);
        assertEq(r1, 5_000e18);
    }

    function test_getEffectiveLiquidity_matchesReserves() public {
        _depositAsOperator(5_000e18);
        (uint256 r0, uint256 r1) = hook.getReserves(testPoolKey);
        (uint256 e0, uint256 e1) = hook.getEffectiveLiquidity(testPoolKey);
        assertEq(r0, e0);
        assertEq(r1, e1);
    }

    function test_indicativeQuote_returnsNonZero() public {
        _depositAsOperator(10_000e18);
        uint256 quote = hook.getIndicativeQuote(testPoolKey, true, -100e18, "");
        assertGt(quote, 0);
    }

    function test_indicativeQuote_returnsZeroWhenEmpty() public view {
        uint256 quote = hook.getIndicativeQuote(testPoolKey, true, -100e18, "");
        assertEq(quote, 0);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    //              hookData IGNORED BY SmartPoolHook (BY DESIGN)
    // ═══════════════════════════════════════════════════════════════════════════
    //
    //  SmartPoolHook overrides `_beforeSwap`, `getIndicativeQuote`, and `swapToPrice`
    //  to ignore hookData entirely — pricing is fully owner-controlled. The hook has
    //  no signed curve-update path. These tests pin that behavior.

    function test_swap_ignoresHookDataCurveUpdate() public {
        _depositAsOperator(10_000e18);

        SmartPoolBase.PricingState memory bogus = SmartPoolBase.PricingState({
            bidFeePips: 999_000, // ~99.9% — would be catastrophic if applied
            askFeePips: 999_000,
            live: true
        });
        bytes memory curveUpdateData = abi.encode(bogus, testPoolId, block.timestamp + 1, bytes(""));
        bytes memory hookData = abi.encode(ALFHookData({attestationData: bytes(""), curveUpdateData: curveUpdateData}));

        (uint24 storedBidBefore, uint24 storedAskBefore, bool storedLiveBefore) = hook.pricingState(testPoolId);
        swap(testPoolKey, true, -1e18, hookData);
        (uint24 storedBidAfter, uint24 storedAskAfter, bool storedLiveAfter) = hook.pricingState(testPoolId);

        assertEq(storedBidAfter, storedBidBefore, "stored bid unchanged");
        assertEq(storedAskAfter, storedAskBefore, "stored ask unchanged");
        assertEq(storedLiveAfter, storedLiveBefore, "stored live unchanged");
    }

    function test_indicativeQuote_ignoresHookData() public {
        _depositAsOperator(10_000e18);

        SmartPoolBase.PricingState memory bogus = SmartPoolBase.PricingState({
            bidFeePips: 999_000,
            askFeePips: 999_000,
            live: true
        });
        bytes memory curveUpdateData = abi.encode(bogus, testPoolId, block.timestamp + 1, bytes(""));
        bytes memory hookData = abi.encode(ALFHookData({attestationData: bytes(""), curveUpdateData: curveUpdateData}));

        uint256 quoteWithBogus = hook.getIndicativeQuote(testPoolKey, true, -1e18, hookData);
        uint256 quoteWithEmpty = hook.getIndicativeQuote(testPoolKey, true, -1e18, "");
        assertEq(quoteWithBogus, quoteWithEmpty, "hookData has no effect on quote");
    }

    // ═══════════════════════════════════════════════════════════════════════════
    //                          YIELD ACCRUAL
    // ═══════════════════════════════════════════════════════════════════════════

    function test_yieldAccrual_increasesShareValue() public {
        _depositAsOperator(1_000e18);

        vault0.simulateYield(100e18);
        vault1.simulateYield(100e18);

        (uint256 amount0, uint256 amount1) = hook.previewWithdraw(testPoolKey, 1_000e18);
        assertEq(amount0, 1_100e18);
        assertEq(amount1, 1_100e18);
    }

    /// @dev Late entrants must not extract yield that accrued before they joined. Bob deposits
    ///      AFTER a yield event; he pays the post-yield (higher) share price; when he withdraws
    ///      at the same price he should break even (modulo wei-level integer rounding). Alice,
    ///      who deposited before the yield, captures her proportional share.
    function test_yield_lateEntrantBreaksEven() public {
        _depositAsOperator(1_000e18);
        vm.prank(owner);
        hook.setExternalDeposits(testPoolKey, true);

        // Alice deposits BEFORE yield (1:1 share price).
        _externalDeposit(testPoolKey, alice, 1_000e18);

        // Yield accrues — pool is now (2100, 2100) at supply 2000.
        vault0.simulateYield(100e18);
        vault1.simulateYield(100e18);

        // Bob deposits AFTER yield, paying the higher share price (~1050 each).
        (uint256 bobPaid0, uint256 bobPaid1) = hook.previewDeposit(testPoolKey, 1_000e18);
        assertApproxEqAbs(bobPaid0, 1_050e18, 1, "bob pays post-yield share price");
        assertEq(bobPaid0, bobPaid1);
        _externalDeposit(testPoolKey, bob, 1_000e18);

        (uint256 aliceOut0, uint256 aliceOut1) = _exitAll(alice);
        (uint256 bobOut0, uint256 bobOut1) = _exitAll(bob);

        // Alice's slice of yield: 1000 / (1000 + 1000) = 50% → ~50e18 profit per side.
        assertGt(aliceOut0, 1_000e18, "alice profited on currency0");
        assertGt(aliceOut1, 1_000e18, "alice profited on currency1");
        assertApproxEqAbs(aliceOut0 - 1_000e18, 50e18, 1, "alice captured half of currency0 yield");
        assertApproxEqAbs(aliceOut1 - 1_000e18, 50e18, 1, "alice captured half of currency1 yield");

        // Bob breaks even within rounding (deposit rounds up + withdraw rounds down → 1-2 wei).
        assertApproxEqAbs(bobOut0, bobPaid0, 10, "bob breaks even on currency0");
        assertApproxEqAbs(bobOut1, bobPaid1, 10, "bob breaks even on currency1");
    }

    /// @dev Three depositors enter at three different times, with yield accruing between each.
    ///      Each captures yield proportional to how long they were a shareholder during yield
    ///      events. With same share size for all three:
    ///        alice in -> yield Y1 -> bob in -> yield Y2 -> charlie in (no yield) -> all exit
    ///      Expected ordering: profit(alice) > profit(bob) > profit(charlie) ~ 0.
    function test_yield_proportionalToTimeOfDeposit() public {
        _depositAsOperator(1_000e18);
        vm.prank(owner);
        hook.setExternalDeposits(testPoolKey, true);

        // Alice in at 1:1.
        _externalDeposit(testPoolKey, alice, 1_000e18);

        // Yield Y1 — only alice + owner share it.
        vault0.simulateYield(100e18);
        vault1.simulateYield(100e18);

        // Bob in at the post-Y1 price.
        (uint256 bobPaid0,) = hook.previewDeposit(testPoolKey, 1_000e18);
        _externalDeposit(testPoolKey, bob, 1_000e18);

        // Yield Y2 — alice + bob + owner all share.
        vault0.simulateYield(100e18);
        vault1.simulateYield(100e18);

        // Charlie in at the post-Y2 price.
        (uint256 charliePaid0,) = hook.previewDeposit(testPoolKey, 1_000e18);
        _externalDeposit(testPoolKey, charlie, 1_000e18);

        // No further yield — charlie holds during zero yield events.

        (uint256 aliceOut0,) = _exitAll(alice);
        (uint256 bobOut0,) = _exitAll(bob);
        (uint256 charlieOut0,) = _exitAll(charlie);

        uint256 aliceProfit = aliceOut0 - 1_000e18;
        uint256 bobProfit = bobOut0 - bobPaid0;

        // Profits ordered by time-held during yield events: alice > bob > charlie ~ 0.
        assertApproxEqAbs(charlieOut0, charliePaid0, 10, "charlie breaks even (held no yield)");
        assertGt(aliceProfit, bobProfit, "alice (held longer) profits more than bob");
        assertGt(bobProfit, 10, "bob captured part of Y2");
        assertGt(aliceProfit, 50e18, "alice captured part of Y1 + Y2 (>=50e18 from Y1 alone)");
    }

    /// @dev Helper: `user` removes ALL their `testPoolKey` shares. Returns (currency0, currency1)
    ///      received this call. Advances one block to satisfy the same-block-withdraw guard so
    ///      callers can chain further deposits/withdrawals in the same test.
    function _exitAll(address user) internal returns (uint256 out0, uint256 out1) {
        uint256 shares = hook.userShares(testPoolId, user);
        uint256 t0Before = token0.balanceOf(user);
        uint256 t1Before = token1.balanceOf(user);
        vm.prank(user);
        hook.removeLiquidity(testPoolKey, shares, 0, 0, block.timestamp);
        vm.roll(block.number + 1);
        out0 = token0.balanceOf(user) - t0Before;
        out1 = token1.balanceOf(user) - t1Before;
    }

    // ═══════════════════════════════════════════════════════════════════════════
    //                       CROSS-POOL ISOLATION
    // ═══════════════════════════════════════════════════════════════════════════
    //
    //  Two pools sharing currency0/currency1 must not contaminate each other.
    //  The test exercises the worst case: one pool vaulted, the other unvaulted —
    //  the unvaulted pool's tokens physically sit in the hook contract.

    function test_crossPool_swapDoesNotConsumeOtherPoolsUnvaultedERC20() public {
        // Bootstrap the primary (vaulted) pool — its tokens are in the vault, not the hook.
        _depositAsOperator(1_000e18);

        // A second unvaulted pool with 500e18 of each currency parked in the hook.
        (PoolKey memory keyB,) = _initSecondaryPool({vaulted: false, bootstrapAmount: 500e18});

        // Pool B's untracked-by-vault ERC-20 sits in the hook.
        assertEq(token0.balanceOf(address(hook)), 500e18);
        assertEq(token1.balanceOf(address(hook)), 500e18);
        (uint256 b0_before, uint256 b1_before) = hook.getReserves(keyB);
        assertEq(b0_before, 500e18);
        assertEq(b1_before, 500e18);

        // Swap on the primary pool. afterSwap → _depositAllToVaults must NOT sweep pool B's tokens.
        swap(testPoolKey, true, -10e18, "");

        (uint256 b0_after, uint256 b1_after) = hook.getReserves(keyB);
        assertEq(b0_after, 500e18, "Pool B currency0 untouched");
        assertEq(b1_after, 500e18, "Pool B currency1 untouched");
        assertEq(token0.balanceOf(address(hook)), 500e18, "Pool B's currency0 still in hook");
        assertEq(token1.balanceOf(address(hook)), 500e18, "Pool B's currency1 still in hook");
    }

    function test_crossPool_unvaultedPoolCanStillWithdrawAfterOtherPoolsSwap() public {
        _depositAsOperator(1_000e18);

        (PoolKey memory keyB, PoolId idB) = _initSecondaryPool({vaulted: false, bootstrapAmount: 500e18});

        // External LP into pool B.
        token0.mint(alice, 100e18);
        token1.mint(alice, 100e18);
        vm.startPrank(alice);
        token0.approve(address(hook), 100e18);
        token1.approve(address(hook), 100e18);
        hook.addLiquidity(keyB, 100e18, type(uint256).max, type(uint256).max, block.timestamp);
        vm.stopPrank();
        vm.roll(block.number + 1);

        // Swap on primary pool.
        swap(testPoolKey, true, -10e18, "");

        // Alice withdraws fully from pool B at proportional value.
        uint256 aliceShares = hook.userShares(idB, alice);
        assertEq(aliceShares, 100e18);
        uint256 t0_before = token0.balanceOf(alice);
        uint256 t1_before = token1.balanceOf(alice);
        vm.prank(alice);
        hook.removeLiquidity(keyB, aliceShares, 0, 0, block.timestamp);
        assertGt(token0.balanceOf(alice), t0_before);
        assertGt(token1.balanceOf(alice), t1_before);
    }

    /// @dev Worst-case interleaving: pool A is vaulted, pool B is unvaulted, both share
    ///      currency0 and currency1. Pool B's tokens physically sit in the hook contract
    ///      while pool A's are in the vault — the exact configuration where any global
    ///      `balanceOf` read in the hook would have leaked B's funds into A. This test
    ///      sequences ~12 deposits, swaps, yield events, and withdrawals across both
    ///      pools and asserts solvency after every state-changing op.
    function test_crossPool_interleavedOperations_oneVaultedOneUnvaulted() public {
        _depositAsOperator(1_000e18); // pool A (vaulted)
        (PoolKey memory keyB, PoolId idB) = _initSecondaryPool({vaulted: false, bootstrapAmount: 500e18});

        vm.prank(owner);
        hook.setExternalDeposits(testPoolKey, true);
        _assertCrossPoolSolvency(testPoolKey, keyB);
        // Hook holds only pool B's unvaulted tokens; pool A's are all in the vault.
        assertEq(token0.balanceOf(address(hook)), 500e18);
        assertEq(token1.balanceOf(address(hook)), 500e18);

        _externalDeposit(testPoolKey, alice, 200e18);
        _externalDeposit(keyB, bob, 100e18);
        _assertCrossPoolSolvency(testPoolKey, keyB);
        // Hook now holds 600e18 of each (500 bootstrap + 100 bob).
        assertEq(token0.balanceOf(address(hook)), 600e18);
        assertEq(token1.balanceOf(address(hook)), 600e18);

        // Each swap must leave the OTHER pool's reserves untouched.
        _swapAndAssertOtherPoolUnchanged(testPoolKey, keyB, true, -50e18);
        _swapAndAssertOtherPoolUnchanged(keyB, testPoolKey, false, -30e18);

        // Yield on the shared vault — pool B is unvaulted, so it must NOT bleed in.
        _accrueVaultYieldAndAssertOnlyPoolACaptures(keyB);

        // Mid-life: another deposit, then alice partially exits.
        _externalDeposit(testPoolKey, charlie, 100e18);
        _assertCrossPoolSolvency(testPoolKey, keyB);
        _partialExit(testPoolKey, alice, 2);
        _assertCrossPoolSolvency(testPoolKey, keyB);

        // Two swaps on B in opposite directions.
        swap(keyB, true, -10e18, "");
        swap(keyB, false, -10e18, "");
        _assertCrossPoolSolvency(testPoolKey, keyB);

        // Full exits.
        _fullExit(keyB, bob);
        _assertCrossPoolSolvency(testPoolKey, keyB);
        _fullExit(testPoolKey, charlie);
        _assertCrossPoolSolvency(testPoolKey, keyB);

        // One more swap on A, then alice exits her remainder.
        swap(testPoolKey, false, -25e18, "");
        _fullExit(testPoolKey, alice);
        _assertCrossPoolSolvency(testPoolKey, keyB);

        // After everyone except owner + dead shares has exited:
        //   pool A shares == owner_A + MINIMUM_SHARES
        //   pool B shares == owner_B + MINIMUM_SHARES
        assertEq(
            hook.totalShares(testPoolId),
            hook.userShares(testPoolId, owner) + hook.MINIMUM_SHARES(),
            "pool A share supply matches owner + dead shares"
        );
        assertEq(
            hook.totalShares(idB),
            hook.userShares(idB, owner) + hook.MINIMUM_SHARES(),
            "pool B share supply matches owner + dead shares"
        );
    }

    /// @dev Helper: swap on `subject`, assert `bystander`'s reserves are unchanged.
    function _swapAndAssertOtherPoolUnchanged(
        PoolKey memory subject,
        PoolKey memory bystander,
        bool zeroForOne,
        int256 amountSpecified
    ) internal {
        (uint256 b0_pre, uint256 b1_pre) = hook.getReserves(bystander);
        swap(subject, zeroForOne, amountSpecified, "");
        (uint256 b0_post, uint256 b1_post) = hook.getReserves(bystander);
        assertEq(b0_post, b0_pre, "bystander pool currency0 untouched");
        assertEq(b1_post, b1_pre, "bystander pool currency1 untouched");
        _assertCrossPoolSolvency(subject, bystander);
    }

    /// @dev Helper: accrue yield on the shared vault; assert pool A grew, unvaulted pool B didn't.
    function _accrueVaultYieldAndAssertOnlyPoolACaptures(PoolKey memory keyB) internal {
        (uint256 a0_pre, uint256 a1_pre) = hook.getReserves(testPoolKey);
        (uint256 b0_pre, uint256 b1_pre) = hook.getReserves(keyB);
        vault0.simulateYield(50e18);
        vault1.simulateYield(50e18);
        (uint256 a0_post, uint256 a1_post) = hook.getReserves(testPoolKey);
        (uint256 b0_post, uint256 b1_post) = hook.getReserves(keyB);
        assertGt(a0_post, a0_pre, "pool A captured currency0 yield");
        assertGt(a1_post, a1_pre, "pool A captured currency1 yield");
        assertEq(b0_post, b0_pre, "vault yield must not credit pool B");
        assertEq(b1_post, b1_pre, "vault yield must not credit pool B");
        _assertCrossPoolSolvency(testPoolKey, keyB);
    }

    /// @dev Helper: `user` removes `1/divisor` of their shares from `key`. Asserts both
    ///      tokens flowed back to the user.
    function _partialExit(PoolKey memory key, address user, uint256 divisor) internal {
        uint256 shares = hook.userShares(key.toId(), user);
        uint256 t0_before = token0.balanceOf(user);
        uint256 t1_before = token1.balanceOf(user);
        vm.prank(user);
        hook.removeLiquidity(key, shares / divisor, 0, 0, block.timestamp);
        vm.roll(block.number + 1);
        assertGt(token0.balanceOf(user), t0_before, "partial-exit returned currency0");
        assertGt(token1.balanceOf(user), t1_before, "partial-exit returned currency1");
    }

    /// @dev Helper: `user` removes ALL their shares from `key`. Asserts both tokens flowed back.
    function _fullExit(PoolKey memory key, address user) internal {
        uint256 shares = hook.userShares(key.toId(), user);
        uint256 t0_before = token0.balanceOf(user);
        uint256 t1_before = token1.balanceOf(user);
        vm.prank(user);
        hook.removeLiquidity(key, shares, 0, 0, block.timestamp);
        vm.roll(block.number + 1);
        assertGt(token0.balanceOf(user), t0_before, "full-exit returned currency0");
        assertGt(token1.balanceOf(user), t1_before, "full-exit returned currency1");
    }

    /// @dev Both pools share the SAME ERC4626 vault contracts. Tests that `_vaultShares`
    ///      isolation prevents one pool from redeeming another pool's vault stake even
    ///      though they sit in a single underlying ERC4626 supply.
    function test_crossPool_interleavedOperations_sharedVault() public {
        _depositAsOperator(1_000e18); // pool A (vaulted)
        (PoolKey memory keyB, PoolId idB) = _initSecondaryPool({vaulted: true, bootstrapAmount: 500e18});

        vm.prank(owner);
        hook.setExternalDeposits(testPoolKey, true);

        _assertCrossPoolSolvency(testPoolKey, keyB);
        // No raw ERC-20 in the hook — both pools' tokens are in the shared vault.
        assertEq(token0.balanceOf(address(hook)), 0);
        assertEq(token1.balanceOf(address(hook)), 0);

        // ─── Interleaved deposits + swaps ────────────────────────────────────────
        _externalDeposit(testPoolKey, alice, 300e18);
        _externalDeposit(keyB, bob, 200e18);
        swap(testPoolKey, true, -100e18, "");
        swap(keyB, false, -75e18, "");
        _assertCrossPoolSolvency(testPoolKey, keyB);

        // ─── Yield on shared vault — both pools must grow ────────────────────────
        _assertSharedVaultYieldDistributesToBothPools(keyB);
        _assertCrossPoolSolvency(testPoolKey, keyB);

        // ─── Alice exits A — must NOT eat into pool B's vault stake ──────────────
        _exitAndAssertNoCrossContamination(keyB);
        _assertCrossPoolSolvency(testPoolKey, keyB);

        // ─── Bob exits B fully — must succeed despite the shared vault ───────────
        vm.roll(block.number + 10);
        vm.warp(block.timestamp + 1);
        uint256 bobShares_B = hook.userShares(idB, bob);
        uint256 t0_bobBefore = token0.balanceOf(bob);
        uint256 t1_bobBefore = token1.balanceOf(bob);
        vm.prank(bob);
        hook.removeLiquidity(keyB, bobShares_B, 0, 0, block.timestamp);
        vm.roll(block.number + 1);
        assertGt(token0.balanceOf(bob), t0_bobBefore);
        assertGt(token1.balanceOf(bob), t1_bobBefore);
        _assertCrossPoolSolvency(testPoolKey, keyB);
    }

    /// @dev Helper extracted from the shared-vault test to keep the stack shallow:
    ///      simulate yield on the shared vault, assert both pools' reserves grew.
    function _assertSharedVaultYieldDistributesToBothPools(PoolKey memory keyB) internal {
        (uint256 a0_pre, uint256 a1_pre) = hook.getReserves(testPoolKey);
        (uint256 b0_pre, uint256 b1_pre) = hook.getReserves(keyB);
        vault0.simulateYield(100e18);
        vault1.simulateYield(100e18);
        (uint256 a0_post, uint256 a1_post) = hook.getReserves(testPoolKey);
        (uint256 b0_post, uint256 b1_post) = hook.getReserves(keyB);
        assertGt(a0_post, a0_pre, "pool A captured currency0 yield");
        assertGt(a1_post, a1_pre, "pool A captured currency1 yield");
        assertGt(b0_post, b0_pre, "pool B captured currency0 yield");
        assertGt(b1_post, b1_pre, "pool B captured currency1 yield");
    }

    /// @dev Helper: alice exits her pool A position; assert pool B's vault stake is intact.
    ///      Allows up to 1 wei downward rounding from `convertToAssets` integer division
    ///      after the vault's total supply/assets change — that's not contamination, just
    ///      ERC4626 share-price rounding noise.
    function _exitAndAssertNoCrossContamination(PoolKey memory keyB) internal {
        (uint256 b0_pre, uint256 b1_pre) = hook.getReserves(keyB);
        uint256 aliceShares = hook.userShares(testPoolId, alice);
        uint256 t0_aliceBefore = token0.balanceOf(alice);
        vm.prank(alice);
        hook.removeLiquidity(testPoolKey, aliceShares, 0, 0, block.timestamp);
        vm.roll(block.number + 1);
        assertGt(token0.balanceOf(alice), t0_aliceBefore, "alice received currency0");

        (uint256 b0_post, uint256 b1_post) = hook.getReserves(keyB);
        assertApproxEqAbs(b0_post, b0_pre, 1, "pool B currency0 reserves not materially eroded");
        assertApproxEqAbs(b1_post, b1_pre, 1, "pool B currency1 reserves not materially eroded");
    }

    // ═══════════════════════════════════════════════════════════════════════════
    //                       TOKEN COMPATIBILITY
    // ═══════════════════════════════════════════════════════════════════════════

    /// @dev Inbound transfers go through `SafeERC20.safeTransferFrom`; outbound through
    ///      `Currency.transfer`. Both tolerate USDT-style tokens that don't return a bool.
    ///      Routed through an unvaulted pool — vault implementations vary in their own
    ///      USDT compatibility (vault-selection concern, not the hook's).
    function test_supportsTokensWithNoReturnData_USDTLike() public {
        NoReturnToken usdt0 = new NoReturnToken();
        NoReturnToken usdt1 = new NoReturnToken();
        if (address(usdt0) > address(usdt1)) (usdt0, usdt1) = (usdt1, usdt0);

        PoolKey memory keyU = PoolKey({
            currency0: Currency.wrap(address(usdt0)),
            currency1: Currency.wrap(address(usdt1)),
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: 10,
            hooks: IHooks(address(hook))
        });

        SmartPoolHook.LiquidityBucket[] memory dist = new SmartPoolHook.LiquidityBucket[](1);
        dist[0] = SmartPoolHook.LiquidityBucket({tickLower: -10, tickUpper: 10, weightBps: 10_000});
        SmartPoolHook.PoolConfig memory cfg = SmartPoolHook.PoolConfig({
            sqrtPriceX96: TickMath.getSqrtPriceAtTick(0),
            pricing: SmartPoolBase.PricingState({bidFeePips: BID_FEE_PIPS, askFeePips: ASK_FEE_PIPS, live: true}),
            distribution: dist,
            allowExternalDeposits: false,
            vault0: IERC4626(address(0)),
            vault1: IERC4626(address(0))
        });

        vm.startPrank(owner);
        hook.initializePool(keyU, cfg);
        usdt0.mint(owner, 1000e18);
        usdt1.mint(owner, 1000e18);
        usdt0.approve(address(hook), 1000e18);
        usdt1.approve(address(hook), 1000e18);
        hook.bootstrap(keyU, 1000e18, 1000e18);
        vm.stopPrank();
        vm.roll(block.number + 1);

        uint256 ownerShares = hook.userShares(keyU.toId(), owner);
        uint256 t0Before = usdt0.balanceOf(owner);
        uint256 t1Before = usdt1.balanceOf(owner);
        vm.prank(owner);
        hook.removeLiquidity(keyU, ownerShares / 2, 0, 0, block.timestamp);
        assertGt(usdt0.balanceOf(owner), t0Before, "USDT-like currency0 returned");
        assertGt(usdt1.balanceOf(owner), t1Before, "USDT-like currency1 returned");
    }

    // ═══════════════════════════════════════════════════════════════════════════
    //                          VAULT OUTAGE
    // ═══════════════════════════════════════════════════════════════════════════
    //
    //  Pool uptime depends on vault uptime. When the vault rejects deposits or
    //  withdrawals, swaps and `removeLiquidity` revert. This is a documented
    //  operational tradeoff — the hook delegates to the vault and surfaces the
    //  failure cleanly rather than silently degrading.

    function test_vaultRevertOnDeposit_swapFails() public {
        _depositAsOperator(1_000e18);

        PausableVault paused = new PausableVault();
        vm.etch(address(vault0), address(paused).code);
        PausableVault(address(vault0)).pause();

        // afterSwap → _depositAllToVault(currency0) → vault.deposit reverts → swap reverts.
        vm.expectRevert();
        swap(testPoolKey, true, -1e18, "");
    }

    function test_vaultRevertOnWithdraw_removeLiquidityFails() public {
        _depositAsOperator(1_000e18);

        PausableVault paused = new PausableVault();
        vm.etch(address(vault0), address(paused).code);
        PausableVault(address(vault0)).pause();

        uint256 ownerShares = hook.userShares(testPoolId, owner);
        vm.prank(owner);
        vm.expectRevert();
        hook.removeLiquidity(testPoolKey, ownerShares, 0, 0, block.timestamp);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    //                      REENTRANCY VIA VAULT
    // ═══════════════════════════════════════════════════════════════════════════
    //
    //  An owner-configured ERC4626 vault is an external dependency. If a malicious
    //  vault re-enters the hook from inside `vault.deposit` (called during JIT
    //  teardown), the JIT lock prevents the inner LP entry-point from succeeding.

    function test_vaultReentryIntoAddLiquidity_rejected() public {
        _depositAsOperator(1_000e18);
        vm.prank(owner);
        hook.setExternalDeposits(testPoolKey, true);

        ReentrantVault evil = new ReentrantVault();
        vm.etch(address(vault0), address(evil).code);
        ReentrantVault(address(vault0)).configure(address(hook), testPoolKey);

        // Swap → afterSwap → vault.deposit → reentrant addLiquidity → JIT lock revert.
        vm.expectRevert();
        swap(testPoolKey, true, -1e18, "");
    }

    function test_vaultReentryIntoSetDistribution_rejected() public {
        _depositAsOperator(1_000e18);

        ReentrantVault evil = new ReentrantVault();
        vm.etch(address(vault0), address(evil).code);
        ReentrantVault(address(vault0)).configureSetDistribution(address(hook), testPoolKey);

        vm.expectRevert();
        swap(testPoolKey, true, -1e18, "");
    }

    // ═══════════════════════════════════════════════════════════════════════════
    //                   PRICING STATE & FEE BOUNDS
    // ═══════════════════════════════════════════════════════════════════════════

    function test_updatePricingState_revertsAboveMaxLPFee() public {
        SmartPoolBase.PricingState memory bad = SmartPoolBase.PricingState({
            bidFeePips: LPFeeLibrary.MAX_LP_FEE + 1,
            askFeePips: BID_FEE_PIPS,
            live: true
        });
        vm.prank(owner);
        vm.expectRevert(bytes4(keccak256("FeeOutOfBounds()")));
        hook.updatePricingState(testPoolKey, bad);

        // Symmetric for askFeePips.
        bad.bidFeePips = BID_FEE_PIPS;
        bad.askFeePips = LPFeeLibrary.MAX_LP_FEE + 1;
        vm.prank(owner);
        vm.expectRevert(bytes4(keccak256("FeeOutOfBounds()")));
        hook.updatePricingState(testPoolKey, bad);
    }

    function test_updatePricingState_atMaxIsAccepted() public {
        SmartPoolBase.PricingState memory edge = SmartPoolBase.PricingState({
            bidFeePips: LPFeeLibrary.MAX_LP_FEE,
            askFeePips: LPFeeLibrary.MAX_LP_FEE,
            live: true
        });
        vm.prank(owner);
        hook.updatePricingState(testPoolKey, edge);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    //                       PM DYNAMIC FEE SYNC
    // ═══════════════════════════════════════════════════════════════════════════
    //
    //  Every write to `pricingState` flows through `_commitPricingState`, which
    //  syncs the PM's stored dynamic LP fee to `max(bidFeePips, askFeePips)` when
    //  live, or 0 when not live. The actual per-swap fee is still set via the
    //  `_beforeSwap` override (direction-aware). The stored value is for off-chain
    //  consumers reading `getSlot0`.

    function test_pmFeeSync_initializePool_setsRepresentativeFee() public view {
        (,,, uint24 lpFee) = manager.getSlot0(testPoolId);
        assertEq(lpFee, BID_FEE_PIPS, "PM fee == max(bid, ask) after init");
    }

    function test_pmFeeSync_updatePricingState_updatesPMFee() public {
        SmartPoolBase.PricingState memory newState = SmartPoolBase.PricingState({
            bidFeePips: 250,
            askFeePips: 5_000,
            live: true
        });
        vm.prank(owner);
        hook.updatePricingState(testPoolKey, newState);
        (,,, uint24 lpFee) = manager.getSlot0(testPoolId);
        assertEq(lpFee, 5_000, "PM fee tracks max(bid, ask)");
    }

    function test_pmFeeSync_setPoolLiveFalse_zeroesPMFee() public {
        vm.prank(owner);
        hook.setPoolLive(testPoolKey, false);
        (,,, uint24 lpFee) = manager.getSlot0(testPoolId);
        assertEq(lpFee, 0, "PM fee == 0 when pool not live");
    }

    function test_pmFeeSync_setPoolLiveTrue_restoresRepresentativeFee() public {
        vm.startPrank(owner);
        hook.setPoolLive(testPoolKey, false);
        hook.setPoolLive(testPoolKey, true);
        vm.stopPrank();
        (,,, uint24 lpFee) = manager.getSlot0(testPoolId);
        assertEq(lpFee, BID_FEE_PIPS, "PM fee restored when live again");
    }

    // ═══════════════════════════════════════════════════════════════════════════
    //                    setActiveTick DISABLED
    // ═══════════════════════════════════════════════════════════════════════════

    /// @dev SmartPoolHook deploys multi-bucket distributions rather than a single
    ///      active tick, so the compatibility setter is present but disabled.
    function test_setActiveTick_reverts() public {
        vm.prank(owner);
        vm.expectRevert(SmartPoolHook.SetActiveTickDisabled.selector);
        hook.setActiveTick(testPoolKey, 0);
    }

    /// @dev `setActiveTick` is `pure` and reverts for any caller, not just non-owners.
    function test_setActiveTick_revertsEvenForNonOwner() public {
        vm.prank(makeAddr("notOwner"));
        vm.expectRevert(SmartPoolHook.SetActiveTickDisabled.selector);
        hook.setActiveTick(testPoolKey, 0);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    //                          VIEW FUNCTIONS
    // ═══════════════════════════════════════════════════════════════════════════

    function test_previewAddLiquidity_revertsBeforeBootstrap() public {
        // Fresh pool that hasn't been bootstrapped.
        (PoolKey memory key,) = _initSecondaryPool({vaulted: false, bootstrapAmount: 0});
        vm.expectRevert(PoolVault.PoolNotBootstrapped.selector);
        hook.previewDeposit(key, 500e18);
    }

    function test_previewAddLiquidity_proportionalAfterBootstrap() public {
        _depositAsOperator(1_000e18);
        (uint256 a0, uint256 a1) = hook.previewDeposit(testPoolKey, 500e18);
        // total0 = total1 = 1000e18, supply = 1000e18 → 500e18 shares costs 500e18 of each.
        assertEq(a0, 500e18);
        assertEq(a1, 500e18);
    }

    function test_sharesOf() public {
        _depositAsOperator(1_000e18);
        assertEq(hook.sharesOf(testPoolKey, owner), 1_000e18 - hook.MINIMUM_SHARES());
        assertEq(hook.sharesOf(testPoolKey, alice), 0);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    //                   QUOTE / EXECUTION FIDELITY
    // ═══════════════════════════════════════════════════════════════════════════
    //
    //  Validates `getIndicativeQuote` stays close to actual swap execution across
    //  multi-range distributions, both directions, exact-input vs exact-output, and
    //  after price movements. The deployed hook uses a compact current-liquidity
    //  quote, not the removed full virtual tick-walk simulator.

    function test_quoteFidelity_smallSwap_zeroForOne() public {
        _depositAsOperator(10_000e18);
        _useMultiBucketDistribution();
        _assertQuoteFidelity(true, -100e18);
    }

    function test_quoteFidelity_mediumSwap_zeroForOne() public {
        _depositAsOperator(10_000e18);
        _useMultiBucketDistribution();
        _assertQuoteFidelity(true, -3_000e18);
    }

    function test_quoteFidelity_largeSwap_zeroForOne() public {
        _depositAsOperator(10_000e18);
        _useMultiBucketDistribution();
        _assertQuoteFidelity(true, -8_000e18);
    }

    function test_quoteFidelity_veryLargeSwap_zeroForOne() public {
        _depositAsOperator(10_000e18);
        _useMultiBucketDistribution();
        _assertQuoteFidelity(true, -9_500e18);
    }

    function test_quoteFidelity_smallSwap_oneForZero() public {
        _depositAsOperator(10_000e18);
        _useMultiBucketDistribution();
        _assertQuoteFidelity(false, -100e18);
    }

    function test_quoteFidelity_mediumSwap_oneForZero() public {
        _depositAsOperator(10_000e18);
        _useMultiBucketDistribution();
        _assertQuoteFidelity(false, -3_000e18);
    }

    function test_quoteFidelity_exactOutput_zeroForOne() public {
        _depositAsOperator(10_000e18);
        _useMultiBucketDistribution();
        _assertQuoteFidelity(true, 100e18);
    }

    function test_quoteFidelity_exactOutput_oneForZero() public {
        _depositAsOperator(10_000e18);
        _useMultiBucketDistribution();
        _assertQuoteFidelity(false, 100e18);
    }

    /// @dev Asymmetric distribution: 50% in [-60,-10], 30% in [-10,10], 20% in [10,60].
    function test_quoteFidelity_asymmetricDistribution() public {
        _depositAsOperator(10_000e18);

        SmartPoolHook.LiquidityBucket[] memory dist = new SmartPoolHook.LiquidityBucket[](3);
        dist[0] = SmartPoolHook.LiquidityBucket({tickLower: -60, tickUpper: -10, weightBps: 5000});
        dist[1] = SmartPoolHook.LiquidityBucket({tickLower: -10, tickUpper: 10, weightBps: 3000});
        dist[2] = SmartPoolHook.LiquidityBucket({tickLower: 10, tickUpper: 60, weightBps: 2000});
        vm.prank(owner);
        hook.setDistribution(testPoolKey, dist);

        uint256 snap = vm.snapshotState();

        _assertQuoteFidelity(true, -100e18);
        vm.revertToState(snap);

        _assertQuoteFidelity(true, -3_000e18);
        vm.revertToState(snap);

        _assertQuoteFidelity(false, -100e18);
        vm.revertToState(snap);

        _assertQuoteFidelity(false, -3_000e18);
    }

    function test_quoteFidelity_afterPriceMovement() public {
        _depositAsOperator(10_000e18);
        _useMultiBucketDistribution();

        // Move price with a large zeroForOne swap.
        swap(testPoolKey, true, -5_000e18, "");
        (, int24 tickAfter,,) = manager.getSlot0(testPoolId);
        assertLt(tickAfter, -5, "price should have moved");

        uint256 snap = vm.snapshotState();
        _assertQuoteFidelity(true, -500e18);
        vm.revertToState(snap);
        _assertQuoteFidelity(false, -500e18);
    }

    /// @dev Single-bucket distribution — the simplest possible JIT shape.
    function test_quoteFidelity_singleBucket_zeroForOne() public {
        _depositAsOperator(10_000e18);
        // Default config is already a single bucket [-10, 10] @ 10_000 bps; no setDistribution.
        _assertQuoteFidelity(true, -100e18);
    }

    function test_quoteFidelity_singleBucket_oneForZero() public {
        _depositAsOperator(10_000e18);
        _assertQuoteFidelity(false, -100e18);
    }

    /// @dev Adjacent buckets sharing a tick boundary.
    function test_quoteFidelity_tickBoundary_sharedAtZero() public {
        _depositAsOperator(10_000e18);

        SmartPoolHook.LiquidityBucket[] memory dist = new SmartPoolHook.LiquidityBucket[](2);
        dist[0] = SmartPoolHook.LiquidityBucket({tickLower: -10, tickUpper: 0, weightBps: 5000});
        dist[1] = SmartPoolHook.LiquidityBucket({tickLower: 0, tickUpper: 10, weightBps: 5000});
        vm.prank(owner);
        hook.setDistribution(testPoolKey, dist);

        uint256 snap = vm.snapshotState();
        // Small swap (stays well inside the bucket): exercises base case.
        _assertQuoteFidelity(true, -100e18);
        vm.revertToState(snap);

        // Large swap that crosses the shared tick boundary at 0.
        _assertQuoteFidelity(true, -2_000e18);
        vm.revertToState(snap);

        _assertQuoteFidelity(false, -2_000e18);
    }

    /// @dev MAX_BUCKETS = 8 distribution. Exercises the upper bound on distribution
    ///      iteration and validates indicative quotes for a multi-bucket shape.
    function test_quoteFidelity_maxBuckets() public {
        _depositAsOperator(10_000e18);

        SmartPoolHook.LiquidityBucket[] memory dist = new SmartPoolHook.LiquidityBucket[](8);
        dist[0] = SmartPoolHook.LiquidityBucket({tickLower: -80, tickUpper: -60, weightBps: 1250});
        dist[1] = SmartPoolHook.LiquidityBucket({tickLower: -60, tickUpper: -40, weightBps: 1250});
        dist[2] = SmartPoolHook.LiquidityBucket({tickLower: -40, tickUpper: -20, weightBps: 1250});
        dist[3] = SmartPoolHook.LiquidityBucket({tickLower: -20, tickUpper: 0, weightBps: 1250});
        dist[4] = SmartPoolHook.LiquidityBucket({tickLower: 0, tickUpper: 20, weightBps: 1250});
        dist[5] = SmartPoolHook.LiquidityBucket({tickLower: 20, tickUpper: 40, weightBps: 1250});
        dist[6] = SmartPoolHook.LiquidityBucket({tickLower: 40, tickUpper: 60, weightBps: 1250});
        dist[7] = SmartPoolHook.LiquidityBucket({tickLower: 60, tickUpper: 80, weightBps: 1250});
        vm.prank(owner);
        hook.setDistribution(testPoolKey, dist);

        uint256 snap = vm.snapshotState();
        _assertQuoteFidelity(true, -100e18); // small, stays inside bucket [0, 20]
        vm.revertToState(snap);
        _assertQuoteFidelity(true, -3_000e18); // medium, crosses several boundaries
        vm.revertToState(snap);
        _assertQuoteFidelity(false, -100e18);
        vm.revertToState(snap);
        _assertQuoteFidelity(false, -3_000e18);
    }

    /// @dev Asymmetric-decimal pair (6-decimal USDC-like + 18-decimal WETH-like). The bootstrap
    ///      math (`sqrt(amount0 * amount1)`), `_convertToAmounts` (Solady `fullMulDiv`), and the
    ///      tick-schedule allocation are all unit-agnostic — verify they remain so under
    ///      realistic decimal asymmetry.
    function test_quoteFidelity_asymmetricDecimals() public {
        // Deploy USDC-like (6 decimals) and WETH-like (18 decimals); order by address so they
        // map to currency0/currency1 cleanly without fighting PoolKey ordering rules.
        MockERC20 stable = new MockERC20("USDC", "USDC", 6);
        MockERC20 weth = new MockERC20("WETH", "WETH", 18);

        (Currency c0, Currency c1, MockERC20 t0, MockERC20 t1) = address(stable) < address(weth)
            ? (Currency.wrap(address(stable)), Currency.wrap(address(weth)), stable, weth)
            : (Currency.wrap(address(weth)), Currency.wrap(address(stable)), weth, stable);

        MockERC4626 v0 = new MockERC4626(ERC20(address(t0)));
        MockERC4626 v1 = new MockERC4626(ERC20(address(t1)));

        PoolKey memory key = PoolKey({
            currency0: c0,
            currency1: c1,
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: 10,
            hooks: IHooks(address(hook))
        });

        SmartPoolHook.LiquidityBucket[] memory dist = new SmartPoolHook.LiquidityBucket[](1);
        dist[0] = SmartPoolHook.LiquidityBucket({tickLower: -10, tickUpper: 10, weightBps: 10_000});

        SmartPoolHook.PoolConfig memory cfg = SmartPoolHook.PoolConfig({
            sqrtPriceX96: TickMath.getSqrtPriceAtTick(0),
            pricing: SmartPoolBase.PricingState({
                bidFeePips: BID_FEE_PIPS,
                askFeePips: ASK_FEE_PIPS,
                live: true
            }),
            distribution: dist,
            allowExternalDeposits: false,
            vault0: IERC4626(address(v0)),
            vault1: IERC4626(address(v1))
        });

        vm.prank(owner);
        hook.initializePool(key, cfg);

        // Bootstrap with realistic units. Whichever currency is t0/t1 by address, deposit
        // enough decimal-equivalent value on each side so liquidity is non-degenerate.
        // 1_000 stable @ 1e6 = 1e9 ; 1 WETH @ 1e18 = 1e18 ; sqrt(1e27) ~ 3.16e13 >> MINIMUM_SHARES.
        uint256 amtStable = 1_000e6;
        uint256 amtWeth = 1e18;
        (uint256 amt0, uint256 amt1) = address(t0) == address(stable) ? (amtStable, amtWeth) : (amtWeth, amtStable);

        t0.mint(owner, amt0);
        t1.mint(owner, amt1);
        vm.startPrank(owner);
        t0.approve(address(hook), amt0);
        t1.approve(address(hook), amt1);
        hook.bootstrap(key, amt0, amt1);
        vm.stopPrank();
        vm.roll(block.number + 1);

        // Approve swap router for the new tokens (deployed by Deployers in setUp).
        t0.mint(address(this), 1e18);
        t1.mint(address(this), 1e18);
        t0.approve(address(swapRouter), type(uint256).max);
        t1.approve(address(swapRouter), type(uint256).max);

        // Direct fidelity assertion — `_assertQuoteFidelity` is hard-coded to `testPoolKey`,
        // so this test inlines the comparison for the asymmetric-decimal pool.
        // Use a tiny exact-input swap so the swap stays well inside the [-10, 10] bucket
        // regardless of which side has 6 vs 18 decimals.
        int256 amountSpecified = -1e6;
        uint256 quoted = hook.getIndicativeQuote(key, true, amountSpecified, "");
        assertGt(quoted, 0, "Quote should be non-zero for asymmetric-decimal pool");

        BalanceDelta delta = swap(key, true, amountSpecified, "");
        uint256 actual = uint256(int256(delta.amount1()));

        assertApproxEqAbs(quoted, actual, ABS_TOLERANCE, "asymmetric-decimal quote/exec mismatch");
    }

    // ═══════════════════════════════════════════════════════════════════════════
    //                  QUOTE / SLIPPAGE / VALIDATION GUARDS
    // ═══════════════════════════════════════════════════════════════════════════

    /// @dev For exact-output, `getIndicativeQuote` returns required INPUT, not output.
    function test_exactOutputQuote_returnsRequiredInput() public {
        _depositAsOperator(10_000e18);

        int256 amountSpecified = 100e18; // exact output
        uint256 quoted = hook.getIndicativeQuote(testPoolKey, true, amountSpecified, "");
        BalanceDelta delta = swap(testPoolKey, true, amountSpecified, "");

        uint256 actualInput = uint256(-int256(delta.amount0()));
        uint256 actualOutput = uint256(int256(delta.amount1()));

        assertApproxEqAbs(quoted, actualInput, ABS_TOLERANCE, "exact-output quote should equal input");
        assertGt(actualInput, actualOutput, "input should exceed output (fees + spread)");
    }

    /// @dev `getEffectiveLiquidity` caps vault contribution at `maxWithdraw`; `getReserves` does not.
    function test_effectiveLiquidity_capsAtMaxWithdraw() public {
        _depositAsOperator(10_000e18);

        // With healthy vault: effective == reserves.
        (uint256 r0, uint256 r1) = hook.getReserves(testPoolKey);
        (uint256 e0, uint256 e1) = hook.getEffectiveLiquidity(testPoolKey);
        assertEq(e0, r0, "healthy vault: effective0 == reserves0");
        assertEq(e1, r1, "healthy vault: effective1 == reserves1");

        // Swap a CappedVault in for vault0 — caps maxWithdraw at 1e18 while convertToAssets
        // still reports the full balance. Effective should drop, reserves should not.
        CappedVault capped = new CappedVault(ERC20(address(token0)), 1e18);
        vm.etch(address(vault0), address(capped).code);
        // Re-store the cap variable in the etched contract.
        CappedVault(address(vault0)).setCap(1e18);

        (uint256 r0_after,) = hook.getReserves(testPoolKey);
        (uint256 e0_after,) = hook.getEffectiveLiquidity(testPoolKey);
        assertEq(r0_after, r0, "reserves unaffected by maxWithdraw cap");
        assertLt(e0_after, r0, "effective should be capped below reserves");
    }

    /// @dev `addLiquidity` reverts when actual amount exceeds `maxAmount{0,1}` bound.
    function test_addLiquidity_revertsOnSlippageExceeded() public {
        _depositAsOperator(1_000e18);
        vm.prank(owner);
        hook.setExternalDeposits(testPoolKey, true);

        (uint256 want0, uint256 want1) = hook.previewDeposit(testPoolKey, 100e18);
        token0.mint(alice, want0);
        token1.mint(alice, want1);
        vm.startPrank(alice);
        token0.approve(address(hook), want0);
        token1.approve(address(hook), want1);
        // Set max < actual required → revert.
        vm.expectRevert(SmartPoolHook.SlippageExceeded.selector);
        hook.addLiquidity(testPoolKey, 100e18, want0 - 1, want1, block.timestamp);
        vm.stopPrank();
    }

    /// @dev `addLiquidity` reverts when `block.timestamp > deadline`.
    function test_addLiquidity_revertsOnDeadlineExpired() public {
        _depositAsOperator(1_000e18);
        vm.prank(owner);
        hook.setExternalDeposits(testPoolKey, true);

        token0.mint(alice, 100e18);
        token1.mint(alice, 100e18);
        vm.startPrank(alice);
        token0.approve(address(hook), 100e18);
        token1.approve(address(hook), 100e18);
        vm.expectRevert(SmartPoolHook.DeadlineExpired.selector);
        hook.addLiquidity(testPoolKey, 100e18, type(uint256).max, type(uint256).max, block.timestamp - 1);
        vm.stopPrank();
    }

    /// @dev `removeLiquidity` reverts when actual amount falls below `minAmount{0,1}` bound.
    function test_removeLiquidity_revertsOnSlippageExceeded() public {
        _depositAsOperator(1_000e18);
        uint256 ownerShares = hook.sharesOf(testPoolKey, owner);
        (uint256 expect0, uint256 expect1) = hook.previewWithdraw(testPoolKey, ownerShares);

        vm.prank(owner);
        // Require strictly more than will be returned → revert.
        vm.expectRevert(SmartPoolHook.SlippageExceeded.selector);
        hook.removeLiquidity(testPoolKey, ownerShares, expect0 + 1, expect1, block.timestamp);
    }

    /// @dev `initializePool` reverts if `vault.asset() != currency`.
    function test_initializePool_revertsOnVaultAssetMismatch() public {
        // Vault wrapping token1 paired with currency0 — mismatch.
        MockERC4626 wrongVault = new MockERC4626(ERC20(address(token1)));
        PoolKey memory key = PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: 60,
            hooks: IHooks(address(hook))
        });
        SmartPoolHook.LiquidityBucket[] memory dist = new SmartPoolHook.LiquidityBucket[](1);
        dist[0] = SmartPoolHook.LiquidityBucket({tickLower: -60, tickUpper: 60, weightBps: 10_000});

        vm.prank(owner);
        vm.expectRevert(SmartPoolHook.VaultAssetMismatch.selector);
        hook.initializePool(key, SmartPoolHook.PoolConfig({
            sqrtPriceX96: TickMath.getSqrtPriceAtTick(0),
            pricing: SmartPoolBase.PricingState({bidFeePips: BID_FEE_PIPS, askFeePips: ASK_FEE_PIPS, live: true}),
            distribution: dist,
            allowExternalDeposits: false,
            vault0: IERC4626(address(wrongVault)),
            vault1: IERC4626(address(vault1))
        }));
    }

    /// @dev `setDistribution` reverts when a tick is outside `[MIN_TICK, MAX_TICK]`.
    function test_setDistribution_revertsOnTickOutOfRange() public {
        // tickLower below MIN_TICK with valid spacing alignment.
        int24 belowMin = ((TickMath.MIN_TICK - 100) / 10) * 10; // aligned to tickSpacing 10
        SmartPoolHook.LiquidityBucket[] memory bad = new SmartPoolHook.LiquidityBucket[](1);
        bad[0] = SmartPoolHook.LiquidityBucket({tickLower: belowMin, tickUpper: 10, weightBps: 10_000});
        vm.prank(owner);
        vm.expectRevert(bytes4(keccak256("InvalidTickRange()")));
        hook.setDistribution(testPoolKey, bad);

        // tickUpper above MAX_TICK.
        int24 aboveMax = ((TickMath.MAX_TICK + 100) / 10) * 10;
        SmartPoolHook.LiquidityBucket[] memory bad2 = new SmartPoolHook.LiquidityBucket[](1);
        bad2[0] = SmartPoolHook.LiquidityBucket({tickLower: -10, tickUpper: aboveMax, weightBps: 10_000});
        vm.prank(owner);
        vm.expectRevert(bytes4(keccak256("InvalidTickRange()")));
        hook.setDistribution(testPoolKey, bad2);
    }
}

// ═══════════════════════════════════════════════════════════════════════════════
//                                  MOCKS
// ═══════════════════════════════════════════════════════════════════════════════

/// @dev USDT-style ERC-20 — `transfer`, `transferFrom`, `approve` return nothing.
///      Standard `IERC20` callers fail to ABI-decode the empty returndata; SafeERC20
///      tolerates it.
contract NoReturnToken {
    string public name = "No Return USDT-like";
    string public symbol = "NRT";
    uint8 public decimals = 18;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    event Transfer(address indexed from, address indexed to, uint256 amount);
    event Approval(address indexed owner, address indexed spender, uint256 amount);

    function mint(address to, uint256 amount) external {
        totalSupply += amount;
        balanceOf[to] += amount;
        emit Transfer(address(0), to, amount);
    }

    function transfer(address to, uint256 amount) external {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        emit Transfer(msg.sender, to, amount);
    }

    function transferFrom(address from, address to, uint256 amount) external {
        uint256 a = allowance[from][msg.sender];
        if (a != type(uint256).max) allowance[from][msg.sender] = a - amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        emit Transfer(from, to, amount);
    }

    function approve(address spender, uint256 amount) external {
        allowance[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
    }
}

/// @dev ERC4626-shaped vault that always reverts when paused. Used to simulate vault
///      outage scenarios (deposit/withdraw failures bricking the pool).
contract PausableVault {
    bool public paused;

    function pause() external {
        paused = true;
    }

    function deposit(uint256, address) external view returns (uint256) {
        if (paused) revert("vault paused");
        return 0;
    }

    function withdraw(uint256, address, address) external view returns (uint256) {
        if (paused) revert("vault paused");
        return 0;
    }

    function redeem(uint256, address, address) external view returns (uint256) {
        if (paused) revert("vault paused");
        return 0;
    }

    function maxWithdraw(address) external view returns (uint256) {
        if (paused) revert("vault paused");
        return 0;
    }

    function maxRedeem(address) external view returns (uint256) {
        if (paused) revert("vault paused");
        return 0;
    }

    function previewWithdraw(uint256) external view returns (uint256) {
        if (paused) revert("vault paused");
        return 0;
    }

    function convertToAssets(uint256) external view returns (uint256) {
        if (paused) revert("vault paused");
        return 0;
    }
}

/// @dev ERC4626-shaped vault that re-enters the hook from inside `deposit`. Configurable
///      to call `addLiquidity` or `setDistribution` for testing the JIT lock.
contract ReentrantVault {
    address public targetHook;
    PoolKey public targetKey;
    bytes4 public mode; // 0xaaaaaaaa = addLiquidity, 0xbbbbbbbb = setDistribution

    function configure(address hook, PoolKey calldata key) external {
        targetHook = hook;
        targetKey = key;
        mode = 0xaaaaaaaa;
    }

    function configureSetDistribution(address hook, PoolKey calldata key) external {
        targetHook = hook;
        targetKey = key;
        mode = 0xbbbbbbbb;
    }

    function deposit(uint256, address) external returns (uint256) {
        if (mode == 0xaaaaaaaa) {
            SmartPoolHook(targetHook).addLiquidity(targetKey, 1, type(uint256).max, type(uint256).max, type(uint256).max);
        } else if (mode == 0xbbbbbbbb) {
            SmartPoolHook.LiquidityBucket[] memory dist = new SmartPoolHook.LiquidityBucket[](1);
            dist[0] = SmartPoolHook.LiquidityBucket({tickLower: -10, tickUpper: 10, weightBps: 10_000});
            SmartPoolHook(targetHook).setDistribution(targetKey, dist);
        }
        return 0;
    }

    function withdraw(uint256, address, address) external pure returns (uint256) {
        return 0;
    }

    function redeem(uint256, address, address) external pure returns (uint256) {
        return 0;
    }

    function maxWithdraw(address) external pure returns (uint256) {
        return type(uint256).max;
    }

    function maxRedeem(address) external pure returns (uint256) {
        return type(uint256).max;
    }

    function previewWithdraw(uint256 a) external pure returns (uint256) {
        return a;
    }

    function convertToAssets(uint256 s) external pure returns (uint256) {
        return s;
    }
}

/// @dev ERC-4626-like mock that reports a fixed `maxWithdraw` cap regardless of share balance.
///      Used to validate that `getEffectiveLiquidity` is bounded by `maxWithdraw` while
///      `getReserves` reports the full `convertToAssets` total.
contract CappedVault {
    ERC20 public asset;
    uint256 public cap;
    mapping(address => uint256) public balanceOf;

    constructor(ERC20 _asset, uint256 _cap) {
        asset = _asset;
        cap = _cap;
    }

    function setCap(uint256 _cap) external {
        cap = _cap;
    }

    function maxWithdraw(address) external view returns (uint256) {
        return cap;
    }

    function maxRedeem(address owner_) external view returns (uint256) {
        return balanceOf[owner_];
    }

    function convertToAssets(uint256 s) external pure returns (uint256) {
        return s;
    }

    function convertToShares(uint256 a) external pure returns (uint256) {
        return a;
    }

    function previewWithdraw(uint256 a) external pure returns (uint256) {
        return a;
    }

    function deposit(uint256, address) external pure returns (uint256) {
        return 0;
    }

    function withdraw(uint256, address, address) external pure returns (uint256) {
        return 0;
    }

    function redeem(uint256, address, address) external pure returns (uint256) {
        return 0;
    }
}
