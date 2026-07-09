// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {CustomRevert} from "@uniswap/v4-core/src/libraries/CustomRevert.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {IV4Quoter} from "@uniswap/v4-periphery/src/interfaces/IV4Quoter.sol";
import {V4Quoter} from "@uniswap/v4-periphery/src/lens/V4Quoter.sol";
import {Deploy} from "@uniswap/v4-periphery/test/shared/Deploy.sol";

import {BaseTokenWrapperHook} from "../src/base/BaseTokenWrapperHook.sol";
import {ERC4626WrapperHook} from "../src/ERC4626WrapperHook.sol";
import {ERC4626RoutingHook} from "../src/ERC4626RoutingHook.sol";
import {MockRebasingERC20} from "./mocks/MockRebasingERC20.sol";
import {MockERC4626Vault} from "./mocks/MockERC4626Vault.sol";
import {TestRouter} from "./shared/TestRouter.sol";
import {ModifyLiquidityParams, SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";

contract ERC4626WrapperHookTest is Test, Deployers {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;

    ERC4626WrapperHook public hook;
    ERC4626RoutingHook public hookSim;
    MockRebasingERC20 public underlying;
    MockERC4626Vault public vault;
    TestRouter public router;
    IV4Quoter public quoter;

    PoolKey poolKey;
    PoolKey poolKeySim;
    uint160 initSqrtPriceX96;

    /// @notice true if the underlying (asset) is currency0, i.e. wrapping is a zeroForOne swap
    bool wrapZeroForOne;

    // Rebasing/vault rounding is at most a few raw-shares worth; scale a wei tolerance by the
    // multiplier so assertions stay meaningful across the fuzzed exchange-rate range.
    uint256 constant TOL = 100;

    address alice = makeAddr("alice");
    address bob = makeAddr("bob");

    function setUp() public {
        deployFreshManagerAndRouters();
        router = new TestRouter(manager);
        quoter = Deploy.v4Quoter(address(manager), hex"00");

        // Deploy a rebasing underlying and a standard-rounding ERC-4626 vault over it
        underlying = new MockRebasingERC20("Mock xStock", "AAPLx", 18);
        vault = new MockERC4626Vault(address(underlying), "Wrapped Mock xStock", "wAAPLx", 18);

        // Seed the vault with backing so totalSupply > 0 and shares are fully backed
        uint256 seed = 1_000_000 ether;
        underlying.mint(address(this), seed);
        underlying.approve(address(vault), type(uint256).max);
        vault.deposit(seed, address(this));

        // Deploy the wrapper hook and the routing (simulation) twin at flag-encoded addresses
        uint160 flags = uint160(
            type(uint160).max & clearAllHookPermissionsMask | Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG
                | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG | Hooks.BEFORE_INITIALIZE_FLAG
        );
        hook = ERC4626WrapperHook(address(flags));
        hookSim = ERC4626RoutingHook(address(flags & (type(uint160).max - 2 ** 156)));
        deployCodeTo("ERC4626WrapperHook", abi.encode(manager, IERC4626(address(vault))), address(hook));
        deployCodeTo("ERC4626RoutingHook", abi.encode(manager, IERC4626(address(vault))), address(hookSim));

        // Order currencies and record the wrap direction
        wrapZeroForOne = address(underlying) < address(vault);
        (Currency currency0, Currency currency1) = wrapZeroForOne
            ? (Currency.wrap(address(underlying)), Currency.wrap(address(vault)))
            : (Currency.wrap(address(vault)), Currency.wrap(address(underlying)));

        poolKey = PoolKey({currency0: currency0, currency1: currency1, fee: 0, tickSpacing: 60, hooks: IHooks(hook)});
        poolKeySim =
            PoolKey({currency0: currency0, currency1: currency1, fee: 0, tickSpacing: 60, hooks: IHooks(hookSim)});

        initSqrtPriceX96 = SQRT_PRICE_1_1;
        manager.initialize(poolKey, initSqrtPriceX96);
        manager.initialize(poolKeySim, initSqrtPriceX96);

        // Fund users generously; distribute vault shares from the seed deposit
        underlying.mint(alice, 1_000_000 ether);
        underlying.mint(bob, 1_000_000 ether);
        underlying.mint(address(this), 1_000_000 ether);
        vault.transfer(alice, 100_000 ether);
        vault.transfer(bob, 100_000 ether);

        // Seed the manager with a share buffer so the routing hook (which does not override
        // _withdraw) can be quoted: its simulated unwrap takes shares the manager must already
        // hold. On a real chain the manager holds ample balances; here we seed them explicitly.
        vault.transfer(address(manager), 500_000 ether);

        vm.startPrank(alice);
        underlying.approve(address(router), type(uint256).max);
        vault.approve(address(router), type(uint256).max);
        vm.stopPrank();

        _addUnrelatedLiquidity();
    }

    // ---------------------------------------------------------------------
    // Helpers
    // ---------------------------------------------------------------------

    /// @notice Rebase the underlying to a fuzzed multiplier (1e18 == 1.0x)
    function _rebase(uint256 rawMultiplier) internal returns (uint256 multiplier) {
        multiplier = bound(rawMultiplier, 0.1e18, 10e18);
        underlying.setMultiplier(multiplier);
    }

    function _limit(bool zeroForOne) internal pure returns (uint160) {
        return zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1;
    }

    /// @notice Perform an exact-input swap on `key` as `alice`
    function _swapExactIn(PoolKey memory key, bool zeroForOne, uint256 amountIn) internal {
        vm.prank(alice);
        router.swap(
            key,
            SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: -int256(amountIn),
                sqrtPriceLimitX96: _limit(zeroForOne)
            }),
            ""
        );
    }

    function _managerUnderlying() internal view returns (uint256) {
        return underlying.balanceOf(address(manager));
    }

    function _managerShares() internal view returns (uint256) {
        return vault.balanceOf(address(manager));
    }

    // ---------------------------------------------------------------------
    // Configuration
    // ---------------------------------------------------------------------

    function test_initialization() public view {
        assertEq(address(hook.vault()), address(vault));
        assertEq(Currency.unwrap(hook.wrapperCurrency()), address(vault));
        assertEq(Currency.unwrap(hook.underlyingCurrency()), address(underlying));
        assertEq(hook.wrapZeroForOne(), wrapZeroForOne);
    }

    // ---------------------------------------------------------------------
    // Wrapping / unwrapping (exact input, fuzzed amount + exchange rate)
    // ---------------------------------------------------------------------

    function testFuzz_wrap_exactInput(uint256 amount, uint256 rawMultiplier) public {
        _rebase(rawMultiplier);
        amount = bound(amount, 0.001 ether, 100_000 ether);

        uint256 aliceUnderlyingBefore = underlying.balanceOf(alice);
        uint256 aliceSharesBefore = vault.balanceOf(alice);
        uint256 managerUnderlyingBefore = _managerUnderlying();
        uint256 managerSharesBefore = _managerShares();

        _swapExactIn(poolKey, wrapZeroForOne, amount);

        // alice spent ~amount of underlying and received a positive amount of shares
        assertApproxEqAbs(aliceUnderlyingBefore - underlying.balanceOf(alice), amount, TOL, "underlying spent");
        assertGt(vault.balanceOf(alice) - aliceSharesBefore, 0, "no shares received");

        // pool solvency: shares are exact, and the manager is never left short of underlying
        assertEq(_managerShares(), managerSharesBefore, "manager shares not conserved");
        assertGe(_managerUnderlying(), managerUnderlyingBefore, "manager underlying drained");
    }

    function testFuzz_unwrap_exactInput(uint256 shares, uint256 rawMultiplier) public {
        _rebase(rawMultiplier);
        shares = bound(shares, 0.001 ether, 100_000 ether);

        uint256 aliceUnderlyingBefore = underlying.balanceOf(alice);
        uint256 aliceSharesBefore = vault.balanceOf(alice);
        uint256 managerUnderlyingBefore = _managerUnderlying();
        uint256 managerSharesBefore = _managerShares();

        uint256 expectedOut = vault.previewRedeem(shares);

        _swapExactIn(poolKey, !wrapZeroForOne, shares);

        // alice spent exactly `shares` (non-rebasing) and received ~previewRedeem underlying
        assertEq(aliceSharesBefore - vault.balanceOf(alice), shares, "shares spent");
        assertApproxEqAbs(underlying.balanceOf(alice) - aliceUnderlyingBefore, expectedOut, TOL, "underlying received");

        assertEq(_managerShares(), managerSharesBefore, "manager shares not conserved");
        assertGe(_managerUnderlying(), managerUnderlyingBefore, "manager underlying drained");
    }

    /// @notice Wrapping then unwrapping at a fixed rate must never return more than was put in
    function testFuzz_roundTrip_noValueCreation(uint256 amount, uint256 rawMultiplier) public {
        _rebase(rawMultiplier);
        amount = bound(amount, 0.001 ether, 100_000 ether);

        uint256 aliceUnderlyingBefore = underlying.balanceOf(alice);
        uint256 aliceSharesBefore = vault.balanceOf(alice);

        // wrap
        _swapExactIn(poolKey, wrapZeroForOne, amount);
        uint256 sharesReceived = vault.balanceOf(alice) - aliceSharesBefore;

        // unwrap everything received
        _swapExactIn(poolKey, !wrapZeroForOne, sharesReceived);
        uint256 underlyingBack = underlying.balanceOf(alice) - (aliceUnderlyingBefore - amount);

        assertLe(underlyingBack, amount, "round-trip created value");
        assertApproxEqAbs(underlyingBack, amount, TOL, "round-trip lost too much");
    }

    // ---------------------------------------------------------------------
    // Routing hook parity (unit-level, via the V4 Quoter)
    // ---------------------------------------------------------------------

    function testFuzz_routing_wrapQuoteMatchesSwap(uint256 amount, uint256 rawMultiplier) public {
        _rebase(rawMultiplier);
        amount = bound(amount, 0.001 ether, 100_000 ether);

        (uint256 quotedOut,) = quoter.quoteExactInputSingle(
            IV4Quoter.QuoteExactSingleParams({
                poolKey: poolKeySim,
                zeroForOne: wrapZeroForOne,
                exactAmount: uint128(amount),
                hookData: ""
            })
        );

        uint256 aliceSharesBefore = vault.balanceOf(alice);
        _swapExactIn(poolKey, wrapZeroForOne, amount);
        uint256 actualOut = vault.balanceOf(alice) - aliceSharesBefore;

        assertApproxEqAbs(quotedOut, actualOut, TOL, "wrap quote != swap");
    }

    function testFuzz_routing_unwrapQuoteMatchesSwap(uint256 shares, uint256 rawMultiplier) public {
        _rebase(rawMultiplier);
        shares = bound(shares, 0.001 ether, 100_000 ether);

        (uint256 quotedOut,) = quoter.quoteExactInputSingle(
            IV4Quoter.QuoteExactSingleParams({
                poolKey: poolKeySim,
                zeroForOne: !wrapZeroForOne,
                exactAmount: uint128(shares),
                hookData: ""
            })
        );

        uint256 aliceUnderlyingBefore = underlying.balanceOf(alice);
        _swapExactIn(poolKey, !wrapZeroForOne, shares);
        uint256 actualOut = underlying.balanceOf(alice) - aliceUnderlyingBefore;

        assertApproxEqAbs(quotedOut, actualOut, TOL, "unwrap quote != swap");
    }

    // ---------------------------------------------------------------------
    // Non-standard decimals
    // ---------------------------------------------------------------------

    function testFuzz_nonStandardDecimals(uint8 rawDecimals, uint256 amount, uint256 rawMultiplier) public {
        uint8 decimals = uint8(bound(rawDecimals, 6, 18));
        uint256 unit = 10 ** decimals;

        (MockRebasingERC20 u, MockERC4626Vault v, PoolKey memory key, bool zeroForOne) =
            _deployDecimalsEnv(decimals, bound(rawMultiplier, 0.1e18, 10e18));

        amount = bound(amount, unit / 1000, 100_000 * unit);

        uint256 managerUBefore = u.balanceOf(address(manager));
        uint256 aliceSharesBefore = v.balanceOf(alice);

        vm.prank(alice);
        router.swap(
            key,
            SwapParams({zeroForOne: zeroForOne, amountSpecified: -int256(amount), sqrtPriceLimitX96: _limit(zeroForOne)}),
            ""
        );

        assertGt(v.balanceOf(alice) - aliceSharesBefore, 0, "no shares received");
        assertGe(u.balanceOf(address(manager)), managerUBefore, "manager underlying drained");
    }

    /// @notice Deploys a fresh underlying/vault/hook/pool with the given decimals and funds alice
    function _deployDecimalsEnv(uint8 decimals, uint256 multiplier)
        internal
        returns (MockRebasingERC20 u, MockERC4626Vault v, PoolKey memory key, bool zeroForOne)
    {
        uint256 unit = 10 ** decimals;
        u = new MockRebasingERC20("Dec xStock", "DECx", decimals);
        v = new MockERC4626Vault(address(u), "Wrapped Dec", "wDECx", decimals);
        u.setMultiplier(multiplier);

        u.mint(address(this), 1_000_000 * unit);
        u.approve(address(v), type(uint256).max);
        v.deposit(1_000_000 * unit, address(this));

        uint160 flags = uint160(
            type(uint160).max & clearAllHookPermissionsMask | Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG
                | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG | Hooks.BEFORE_INITIALIZE_FLAG
        );
        ERC4626WrapperHook decHook = ERC4626WrapperHook(address(flags & (type(uint160).max - 2 ** 155)));
        deployCodeTo("ERC4626WrapperHook", abi.encode(manager, IERC4626(address(v))), address(decHook));

        zeroForOne = address(u) < address(v);
        (Currency c0, Currency c1) = zeroForOne
            ? (Currency.wrap(address(u)), Currency.wrap(address(v)))
            : (Currency.wrap(address(v)), Currency.wrap(address(u)));
        key = PoolKey({currency0: c0, currency1: c1, fee: 0, tickSpacing: 60, hooks: IHooks(decHook)});
        manager.initialize(key, SQRT_PRICE_1_1);

        // A wrap-only exact-input swap needs no pre-seeded manager reserves: the swapper's input
        // is settled into the manager before the hook takes it. So no unrelated liquidity here
        // (its 18-decimal liquidityDelta would not scale to low-decimal tokens).
        u.mint(alice, 1_000_000 * unit);
        v.transfer(alice, 100_000 * unit);
        vm.startPrank(alice);
        u.approve(address(router), type(uint256).max);
        v.approve(address(router), type(uint256).max);
        vm.stopPrank();
    }

    // ---------------------------------------------------------------------
    // Reverts / guards
    // ---------------------------------------------------------------------

    function test_revert_wrap_exactOutput() public {
        vm.startPrank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(
                CustomRevert.WrappedError.selector,
                address(hook),
                IHooks.beforeSwap.selector,
                abi.encodeWithSelector(BaseTokenWrapperHook.ExactOutputNotSupported.selector),
                abi.encodeWithSelector(Hooks.HookCallFailed.selector)
            )
        );
        router.swap(
            poolKey,
            SwapParams({zeroForOne: wrapZeroForOne, amountSpecified: 1 ether, sqrtPriceLimitX96: _limit(wrapZeroForOne)}),
            ""
        );
    }

    function test_revert_unwrap_exactOutput() public {
        vm.startPrank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(
                CustomRevert.WrappedError.selector,
                address(hook),
                IHooks.beforeSwap.selector,
                abi.encodeWithSelector(BaseTokenWrapperHook.ExactOutputNotSupported.selector),
                abi.encodeWithSelector(Hooks.HookCallFailed.selector)
            )
        );
        router.swap(
            poolKey,
            SwapParams({
                zeroForOne: !wrapZeroForOne,
                amountSpecified: 1 ether,
                sqrtPriceLimitX96: _limit(!wrapZeroForOne)
            }),
            ""
        );
    }

    /// @notice A zero-amount swap is rejected by the PoolManager before the hook runs
    function test_revert_zeroAmount() public {
        vm.startPrank(alice);
        vm.expectRevert(IPoolManager.SwapAmountCannotBeZero.selector);
        router.swap(
            poolKey,
            SwapParams({zeroForOne: wrapZeroForOne, amountSpecified: 0, sqrtPriceLimitX96: _limit(wrapZeroForOne)}),
            ""
        );
    }

    function test_revertAddLiquidity() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                CustomRevert.WrappedError.selector,
                address(hook),
                IHooks.beforeAddLiquidity.selector,
                abi.encodeWithSelector(BaseTokenWrapperHook.LiquidityNotAllowed.selector),
                abi.encodeWithSelector(Hooks.HookCallFailed.selector)
            )
        );
        modifyLiquidityRouter.modifyLiquidity(
            poolKey,
            ModifyLiquidityParams({tickLower: -120, tickUpper: 120, liquidityDelta: 1000e18, salt: bytes32(0)}),
            ""
        );
    }

    function test_revertInvalidPoolInitialization() public {
        // Non-zero fee
        (Currency c0, Currency c1) = wrapZeroForOne
            ? (Currency.wrap(address(underlying)), Currency.wrap(address(vault)))
            : (Currency.wrap(address(vault)), Currency.wrap(address(underlying)));
        PoolKey memory invalidKey =
            PoolKey({currency0: c0, currency1: c1, fee: 3000, tickSpacing: 60, hooks: IHooks(hook)});
        vm.expectRevert(
            abi.encodeWithSelector(
                CustomRevert.WrappedError.selector,
                address(hook),
                IHooks.beforeInitialize.selector,
                abi.encodeWithSelector(BaseTokenWrapperHook.InvalidPoolFee.selector),
                abi.encodeWithSelector(Hooks.HookCallFailed.selector)
            )
        );
        manager.initialize(invalidKey, initSqrtPriceX96);

        // Wrong token pair
        MockERC20 randomToken = new MockERC20("Random", "RND", 18);
        (Currency rc0, Currency rc1) = address(randomToken) < address(vault)
            ? (Currency.wrap(address(randomToken)), Currency.wrap(address(vault)))
            : (Currency.wrap(address(vault)), Currency.wrap(address(randomToken)));
        invalidKey = PoolKey({currency0: rc0, currency1: rc1, fee: 0, tickSpacing: 60, hooks: IHooks(hook)});
        vm.expectRevert(
            abi.encodeWithSelector(
                CustomRevert.WrappedError.selector,
                address(hook),
                IHooks.beforeInitialize.selector,
                abi.encodeWithSelector(BaseTokenWrapperHook.InvalidPoolToken.selector),
                abi.encodeWithSelector(Hooks.HookCallFailed.selector)
            )
        );
        manager.initialize(invalidKey, initSqrtPriceX96);
    }

    // ---------------------------------------------------------------------
    // Unrelated liquidity so the PoolManager holds real reserves of both tokens
    // ---------------------------------------------------------------------

    function _addUnrelatedLiquidity() internal {
        _addUnrelatedLiquidityFor(underlying, vault, wrapZeroForOne);
    }

    function _addUnrelatedLiquidityFor(MockRebasingERC20 u, MockERC4626Vault v, bool zeroForOne) internal {
        (Currency c0, Currency c1) = zeroForOne
            ? (Currency.wrap(address(u)), Currency.wrap(address(v)))
            : (Currency.wrap(address(v)), Currency.wrap(address(u)));
        PoolKey memory unrelatedPoolKey =
            PoolKey({currency0: c0, currency1: c1, fee: 100, tickSpacing: 60, hooks: IHooks(address(0))});
        manager.initialize(unrelatedPoolKey, SQRT_PRICE_1_1);

        u.approve(address(modifyLiquidityRouter), type(uint256).max);
        v.approve(address(modifyLiquidityRouter), type(uint256).max);
        modifyLiquidityRouter.modifyLiquidity(
            unrelatedPoolKey,
            ModifyLiquidityParams({tickLower: -120, tickUpper: 120, liquidityDelta: 1000e18, salt: bytes32(0)}),
            ""
        );
    }
}
