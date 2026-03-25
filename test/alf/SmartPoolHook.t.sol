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
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {SmartPoolHook} from "../../src/alf/SmartPoolHook.sol";
import {SpreadQuoterBase} from "../../src/alf/base/SpreadQuoterBase.sol";
import {MockERC4626} from "./mocks/MockERC4626.sol";

contract SmartPoolHookTest is Test, Deployers {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;
    using StateLibrary for IPoolManager;

    SmartPoolHook public hook;

    MockERC4626 public vault0;
    MockERC4626 public vault1;

    address owner = makeAddr("owner");
    address operator = makeAddr("operator");
    address alice = makeAddr("alice");

    PoolKey testPoolKey;
    PoolId testPoolId;

    MockERC20 token0;
    MockERC20 token1;

    uint24 constant BID_FEE_PIPS = 10_000; // 1%
    uint24 constant ASK_FEE_PIPS = 10_000; // 1%

    function setUp() public {
        deployFreshManagerAndRouters();
        deployMintAndApprove2Currencies();

        token0 = MockERC20(Currency.unwrap(currency0));
        token1 = MockERC20(Currency.unwrap(currency1));

        // Deploy mock ERC4626 vaults
        vault0 = new MockERC4626(ERC20(address(token0)));
        vault1 = new MockERC4626(ERC20(address(token1)));

        // Deploy hook at flag-mined address
        uint160 flags = uint160(
            Hooks.BEFORE_INITIALIZE_FLAG | Hooks.AFTER_INITIALIZE_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG
                | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG
        );
        hook = SmartPoolHook(address(uint160(uint256(type(uint160).max) & clearAllHookPermissionsMask | flags)));
        deployCodeTo(
            "SmartPoolHook",
            abi.encode(manager, uint32(100_000), owner),
            address(hook)
        );

        // Initialize pool through hook
        testPoolKey = PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: 10,
            hooks: IHooks(address(hook))
        });

        vm.startPrank(owner);
        hook.initializePool(
            testPoolKey,
            TickMath.getSqrtPriceAtTick(0), // 1:1 price
            SpreadQuoterBase.PricingState({bidFeePips: BID_FEE_PIPS, askFeePips: ASK_FEE_PIPS, attestedDiscountBps: 0, live: true}),
            -10, // tickLower
            10, // tickUpper
            operator,
            false // no external deposits
        );

        // Configure vaults
        hook.setVault(testPoolKey, currency0, IERC4626(address(vault0)));
        hook.setVault(testPoolKey, currency1, IERC4626(address(vault1)));

        // Set price signer (not used in basic tests but needed for completeness)
        hook.setPriceSigner(makeAddr("priceSigner"));
        vm.stopPrank();

        testPoolId = testPoolKey.toId();
    }

    // ──── Helpers ────

    function _depositAsOperator(uint256 amount) internal {
        // For first deposit: shares = amount, requires (amount, amount) of each token.
        // For subsequent deposits: shares convert proportionally.
        (uint256 need0, uint256 need1) = hook.previewAddLiquidity(testPoolKey, amount);
        token0.mint(operator, need0);
        token1.mint(operator, need1);
        vm.startPrank(operator);
        token0.approve(address(hook), need0);
        token1.approve(address(hook), need1);
        hook.addLiquidity(testPoolKey, amount);
        vm.stopPrank();
    }

    // ──── Pool Initialization ────

    function test_initializePool_setsConfig() public view {
        assertEq(hook.poolOperator(testPoolId), operator);
        assertEq(hook.poolTickLower(testPoolId), -10);
        assertEq(hook.poolTickUpper(testPoolId), 10);
        assertFalse(hook.externalDepositsEnabled(testPoolId));
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

    // ──── Vault Configuration ────

    function test_setVault_configuresVaults() public view {
        assertEq(address(hook.vaults(testPoolId, currency0)), address(vault0));
        assertEq(address(hook.vaults(testPoolId, currency1)), address(vault1));
    }

    // ──── LP Deposits & Withdrawals ────

    function test_addLiquidity_operatorCanDeposit() public {
        _depositAsOperator(1_000e18);

        assertEq(hook.totalShares(testPoolId), 1_000e18);
        assertEq(hook.userShares(testPoolId, operator), 1_000e18);

        // Tokens should be in vaults, not in hook
        assertEq(token0.balanceOf(address(hook)), 0);
        assertEq(token1.balanceOf(address(hook)), 0);
        assertGt(vault0.balanceOf(address(hook)), 0);
        assertGt(vault1.balanceOf(address(hook)), 0);
    }

    function test_addLiquidity_externalUserBlocked() public {
        token0.mint(alice, 1_000e18);
        token1.mint(alice, 1_000e18);
        vm.startPrank(alice);
        token0.approve(address(hook), 1_000e18);
        token1.approve(address(hook), 1_000e18);
        vm.expectRevert(SmartPoolHook.ExternalDepositsDisabled.selector);
        hook.addLiquidity(testPoolKey, 1_000e18);
        vm.stopPrank();
    }

    function test_addLiquidity_externalUserAllowedWhenEnabled() public {
        vm.prank(owner);
        hook.setExternalDeposits(testPoolKey, true);

        token0.mint(alice, 1_000e18);
        token1.mint(alice, 1_000e18);
        vm.startPrank(alice);
        token0.approve(address(hook), 1_000e18);
        token1.approve(address(hook), 1_000e18);
        hook.addLiquidity(testPoolKey, 1_000e18);
        vm.stopPrank();

        assertEq(hook.userShares(testPoolId, alice), 1_000e18);
    }

    function test_removeLiquidity_returnsTokens() public {
        _depositAsOperator(1_000e18);

        uint256 balBefore0 = token0.balanceOf(operator);
        uint256 balBefore1 = token1.balanceOf(operator);

        vm.prank(operator);
        hook.removeLiquidity(testPoolKey, 500e18);

        assertEq(hook.userShares(testPoolId, operator), 500e18);
        assertEq(hook.totalShares(testPoolId), 500e18);
        assertEq(token0.balanceOf(operator) - balBefore0, 500e18);
        assertEq(token1.balanceOf(operator) - balBefore1, 500e18);
    }

    function test_removeLiquidity_revertsInsufficientShares() public {
        _depositAsOperator(1_000e18);

        vm.prank(operator);
        vm.expectRevert(SmartPoolHook.InsufficientShares.selector);
        hook.removeLiquidity(testPoolKey, 2_000e18);
    }

    // ──── External LP Blocked ────

    function test_externalLP_addBlocked() public {
        vm.expectRevert();
        modifyLiquidityRouter.modifyLiquidity(
            testPoolKey,
            ModifyLiquidityParams({tickLower: -10, tickUpper: 10, liquidityDelta: 1000, salt: bytes32(0)}),
            ""
        );
    }

    // ──── JIT Swap Cycle ────

    function test_swap_executesJITCycle() public {
        _depositAsOperator(10_000e18);

        // Verify no LP in pool before swap
        (uint128 liquidityBefore) = manager.getLiquidity(testPoolId);
        assertEq(liquidityBefore, 0);

        // Execute a swap (zeroForOne)
        bool zeroForOne = true;
        int256 amountSpecified = -100e18; // exact input

        swap(testPoolKey, zeroForOne, amountSpecified, "");

        // Verify no LP remains in pool after swap
        (uint128 liquidityAfter) = manager.getLiquidity(testPoolId);
        assertEq(liquidityAfter, 0);

        // Hook should still have assets (slightly rebalanced after swap)
        (uint256 reserves0, uint256 reserves1) = hook.getReserves(testPoolKey);
        assertGt(reserves0 + reserves1, 0);
    }

    function test_swap_movesPrice() public {
        _depositAsOperator(10_000e18);

        (, int24 tickBefore,,) = manager.getSlot0(testPoolId);

        // Swap to move price
        swap(testPoolKey, true, -1_000e18, "");

        (, int24 tickAfter,,) = manager.getSlot0(testPoolId);

        // Price should have moved (tick decreased for zeroForOne)
        assertLt(tickAfter, tickBefore);
    }

    function test_swap_noopWithoutDeposits() public {
        // Swap on empty pool should not revert
        swap(testPoolKey, true, -100e18, "");
    }

    // ──── IHookStats ────

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

    // ──── Indicative Quotes ────

    function test_indicativeQuote_returnsNonZero() public {
        _depositAsOperator(10_000e18);

        uint256 quote = hook.getIndicativeQuote(testPoolKey, true, -100e18, "");
        assertGt(quote, 0);
    }

    function test_indicativeQuote_returnsZeroWhenEmpty() public view {
        uint256 quote = hook.getIndicativeQuote(testPoolKey, true, -100e18, "");
        assertEq(quote, 0);
    }

    // ──── Yield Accrual ────

    function test_yieldAccrual_increasesShareValue() public {
        _depositAsOperator(1_000e18);

        // Simulate yield in vaults
        vault0.simulateYield(100e18);
        vault1.simulateYield(100e18);

        // Preview withdrawal should show more than deposited
        (uint256 amount0, uint256 amount1) = hook.previewRemoveLiquidity(testPoolKey, 1_000e18);
        assertEq(amount0, 1_100e18);
        assertEq(amount1, 1_100e18);
    }

    // ──── No-Vault Currency ────

    function test_noVault_tokensHeldAsErc20() public {
        // Remove vault1 so currency1 has no vault
        vm.prank(owner);
        hook.setVault(testPoolKey, currency1, IERC4626(address(0)));

        _depositAsOperator(1_000e18);

        // currency0 should be in vault, currency1 as ERC-20
        assertGt(vault0.balanceOf(address(hook)), 0);
        assertEq(token1.balanceOf(address(hook)), 1_000e18);

        // Reserves should still report correctly
        (uint256 r0, uint256 r1) = hook.getReserves(testPoolKey);
        assertEq(r0, 1_000e18);
        assertEq(r1, 1_000e18);
    }

    // ──── Access Control ────

    function test_initializePool_onlyOwner() public {
        PoolKey memory key2 = PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: 20,
            hooks: IHooks(address(hook))
        });

        vm.prank(alice);
        vm.expectRevert();
        hook.initializePool(
            key2,
            TickMath.getSqrtPriceAtTick(0),
            SpreadQuoterBase.PricingState({bidFeePips: 100, askFeePips: 100, attestedDiscountBps: 0, live: true}),
            -20,
            20,
            operator,
            false
        );
    }

    function test_setVault_onlyOwner() public {
        vm.prank(alice);
        vm.expectRevert();
        hook.setVault(testPoolKey, currency0, IERC4626(address(0)));
    }

    // ──── View Functions ────

    function test_previewAddLiquidity_firstDeposit() public view {
        (uint256 a0, uint256 a1) = hook.previewAddLiquidity(testPoolKey, 500e18);
        assertEq(a0, 500e18);
        assertEq(a1, 500e18);
    }

    function test_sharesOf() public {
        _depositAsOperator(1_000e18);
        assertEq(hook.sharesOf(testPoolKey, operator), 1_000e18);
        assertEq(hook.sharesOf(testPoolKey, alice), 0);
    }
}
