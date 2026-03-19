// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {Constants} from "@uniswap/v4-core/test/utils/Constants.sol";
import {CustomRevert} from "@uniswap/v4-core/src/libraries/CustomRevert.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {LiquidityAmounts} from "@uniswap/v4-core/test/utils/LiquidityAmounts.sol";
import {AaveRehypothecatingSpreadQuoterHook} from "../../src/alf/AaveRehypothecatingSpreadQuoterHook.sol";
import {SpreadQuoterBase} from "../../src/alf/base/SpreadQuoterBase.sol";
import {AttestationRegistry} from "../../src/alf/AttestationRegistry.sol";
import {IAttestationRegistry, Attestation} from "../../src/alf/interfaces/IAttestationRegistry.sol";
import {MockAttestationSigner} from "./mocks/MockAttestationSigner.sol";
import {MockAavePool} from "./mocks/MockAavePool.sol";
import {IAavePool} from "../../src/alf/interfaces/IAavePool.sol";
import {ALFHookData} from "../../src/alf/interfaces/IALFHook.sol";

contract AaveRehypothecatingSpreadQuoterHookTest is Test, Deployers {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;
    using StateLibrary for IPoolManager;

    AttestationRegistry public attestationRegistry;
    AaveRehypothecatingSpreadQuoterHook public hook;
    MockAavePool public mockAave;

    address owner = makeAddr("owner");
    uint256 attesterPk;
    address attester;

    PoolKey testPoolKey;

    MockERC20 token0;
    MockERC20 token1;
    address aToken0;
    address aToken1;

    uint24 constant BID_FEE_PIPS = 20_000; // 2%
    uint24 constant ASK_FEE_PIPS = 50_000; // 5%
    uint24 constant TARGET_UTILIZATION = 800_000; // 80%
    uint24 constant REBALANCE_THRESHOLD = 50_000; // 5%

    function setUp() public {
        deployFreshManagerAndRouters();
        deployMintAndApprove2Currencies();

        token0 = MockERC20(Currency.unwrap(currency0));
        token1 = MockERC20(Currency.unwrap(currency1));

        attestationRegistry = new AttestationRegistry(owner);

        (attester, attesterPk) = makeAddrAndKey("attester");
        vm.prank(owner);
        attestationRegistry.addAttester(attester);

        // Deploy mock Aave pool
        mockAave = new MockAavePool();
        aToken0 = mockAave.addAsset(address(token0));
        aToken1 = mockAave.addAsset(address(token1));
        token0.mint(address(mockAave), 100_000e18);
        token1.mint(address(mockAave), 100_000e18);

        // Deploy hook at flag-mined address
        uint160 flags = uint160(
            Hooks.AFTER_INITIALIZE_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG
                | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG
        );
        hook = AaveRehypothecatingSpreadQuoterHook(
            address(uint160(uint256(type(uint160).max) & clearAllHookPermissionsMask | flags))
        );
        deployCodeTo(
            "AaveRehypothecatingSpreadQuoterHook",
            abi.encode(
                manager,
                address(attestationRegistry),
                uint32(100_000),
                owner,
                address(mockAave),
                TARGET_UTILIZATION,
                REBALANCE_THRESHOLD
            ),
            address(hook)
        );

        // Dynamic fee pool with tickSpacing 60
        testPoolKey = PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: 60,
            hooks: IHooks(address(hook))
        });

        // Initialize at tick 30 → inside LP range [0,60) for both swap directions
        manager.initialize(testPoolKey, TickMath.getSqrtPriceAtTick(30));

        // Configure Aave tokens
        vm.startPrank(owner);
        hook.configureAaveToken(address(token0), aToken0);
        hook.configureAaveToken(address(token1), aToken1);

        // Set pricing state
        hook.updatePricingState(
            testPoolKey,
            SpreadQuoterBase.PricingState({
                bidFeePips: BID_FEE_PIPS, askFeePips: ASK_FEE_PIPS, attestedDiscountBps: 5, live: true
            })
        );

        // Deposit inventory into hook
        token0.mint(owner, 10_000e18);
        token1.mint(owner, 10_000e18);
        token0.approve(address(hook), type(uint256).max);
        token1.approve(address(hook), type(uint256).max);
        hook.deposit(currency0, 10_000e18);
        hook.deposit(currency1, 10_000e18);
        vm.stopPrank();
    }

    // ──── Helpers ────

    function _deployLP(uint128 liquidity) internal {
        vm.prank(owner);
        hook.deployLiquidity(testPoolKey, liquidity);
    }

    function _computeLiquidity(uint256 amount0, uint256 amount1) internal view returns (uint128) {
        int24 activeTick = hook.activeLowerTick(testPoolKey.toId());
        (uint160 sqrtPriceX96,,,) = manager.getSlot0(testPoolKey.toId());
        return LiquidityAmounts.getLiquidityForAmounts(
            sqrtPriceX96,
            TickMath.getSqrtPriceAtTick(activeTick),
            TickMath.getSqrtPriceAtTick(activeTick + testPoolKey.tickSpacing),
            amount0,
            amount1
        );
    }

    function test_afterInitialize_setsActiveLowerTick() public view {
        // Init tick 30, tickSpacing 60 → floor(30/60)*60 = 0
        assertEq(hook.activeLowerTick(testPoolKey.toId()), int24(0));
    }

    // ──── External LP blocked ────

    function test_addLiquidity_blocked() public {
        vm.expectRevert();
        modifyLiquidityRouter.modifyLiquidity(
            testPoolKey,
            ModifyLiquidityParams({tickLower: 0, tickUpper: 60, liquidityDelta: 1e18, salt: bytes32(0)}),
            ""
        );
    }

    function test_removeLiquidity_blocked() public {
        vm.expectRevert();
        modifyLiquidityRouter.modifyLiquidity(
            testPoolKey,
            ModifyLiquidityParams({tickLower: 0, tickUpper: 60, liquidityDelta: -1e18, salt: bytes32(0)}),
            ""
        );
    }

    // ──── Deploy LP ────

    function test_deployLiquidity_addsLPAtActiveTick() public {
        uint128 liq = _computeLiquidity(5_000e18, 5_000e18);
        _deployLP(liq);

        (int24 tickLower, int24 tickUpper, uint128 liquidity) = hook.activePosition(testPoolKey.toId());
        assertEq(tickLower, int24(0));
        assertEq(tickUpper, int24(60));
        assertEq(liquidity, liq);
    }

    function test_deployLiquidity_consumesTokens() public {
        uint256 hook0Before = token0.balanceOf(address(hook));
        uint256 hook1Before = token1.balanceOf(address(hook));

        uint128 liq = _computeLiquidity(1_000e18, 1_000e18);
        _deployLP(liq);

        // Hook should have less ERC-20 (some went to pool as LP)
        assertTrue(token0.balanceOf(address(hook)) < hook0Before);
        assertTrue(token1.balanceOf(address(hook)) < hook1Before);
    }

    function test_deployLiquidity_onlyOwner() public {
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, address(this)));
        hook.deployLiquidity(testPoolKey, 1e18);
    }

    function test_deployLiquidity_revertIfAlreadyActive() public {
        uint128 liq = _computeLiquidity(1_000e18, 1_000e18);
        _deployLP(liq);

        vm.prank(owner);
        vm.expectRevert(AaveRehypothecatingSpreadQuoterHook.PositionAlreadyActive.selector);
        hook.deployLiquidity(testPoolKey, liq);
    }

    // ──── Remove LP ────

    function test_removeLiquidity_returnsTokens() public {
        uint128 liq = _computeLiquidity(1_000e18, 1_000e18);
        _deployLP(liq);

        uint256 hook0Before = token0.balanceOf(address(hook));
        uint256 hook1Before = token1.balanceOf(address(hook));

        vm.prank(owner);
        hook.removeLiquidity(testPoolKey);

        // Tokens returned to hook
        assertTrue(token0.balanceOf(address(hook)) > hook0Before);
        assertTrue(token1.balanceOf(address(hook)) > hook1Before);

        // Position cleared
        (,, uint128 liquidity) = hook.activePosition(testPoolKey.toId());
        assertEq(liquidity, 0);
    }

    function test_removeLiquidity_revertIfNoPosition() public {
        vm.prank(owner);
        vm.expectRevert(AaveRehypothecatingSpreadQuoterHook.NoActivePosition.selector);
        hook.removeLiquidity(testPoolKey);
    }

    // ──── Swap with LP ────

    function test_swap_zeroForOne_withBidFee() public {
        uint128 liq = _computeLiquidity(5_000e18, 5_000e18);
        _deployLP(liq);

        BalanceDelta delta = swap(testPoolKey, true, -1e18, "");
        assertEq(delta.amount0(), -1e18);
        int128 output = delta.amount1();
        assertTrue(output > 0);
        // 2% bid fee → ~0.98e18 output
        assertApproxEqRel(uint256(int256(output)), 0.98e18, 0.01e18);
    }

    function test_swap_oneForZero_withAskFee() public {
        uint128 liq = _computeLiquidity(5_000e18, 5_000e18);
        _deployLP(liq);

        BalanceDelta delta = swap(testPoolKey, false, -1e18, "");
        assertEq(delta.amount1(), -1e18);
        int128 output = delta.amount0();
        assertTrue(output > 0);
        // 5% ask fee → ~0.95e18 output
        assertApproxEqRel(uint256(int256(output)), 0.95e18, 0.01e18);
    }

    function test_swap_unlivePool_noFeeOverride() public {
        uint128 liq = _computeLiquidity(5_000e18, 5_000e18);
        _deployLP(liq);

        vm.prank(owner);
        hook.setPoolLive(testPoolKey, false);

        BalanceDelta delta = swap(testPoolKey, true, -1e18, "");
        assertEq(delta.amount0(), -1e18);
        int128 output = delta.amount1();
        assertTrue(output > 0);
        // No fee override → essentially no fee (dynamic default = 0)
        assertApproxEqRel(uint256(int256(output)), 1e18, 0.005e18);
    }

    // ──── Indicative quoting ────

    function test_getIndicativeQuote_matchesSwap() public {
        uint128 liq = _computeLiquidity(5_000e18, 5_000e18);
        _deployLP(liq);

        uint256 indicative = hook.getIndicativeQuote(testPoolKey, true, -1e18, "");
        BalanceDelta delta = swap(testPoolKey, true, -1e18, "");
        uint256 actual = uint256(int256(delta.amount1()));

        assertEq(indicative, actual);
    }

    function test_getIndicativeQuote_unliveReturnsZero() public {
        uint128 liq = _computeLiquidity(5_000e18, 5_000e18);
        _deployLP(liq);

        vm.prank(owner);
        hook.setPoolLive(testPoolKey, false);

        assertEq(hook.getIndicativeQuote(testPoolKey, true, -1e18, ""), 0);
    }

    // ──── Aave lazy rebalance ────

    function test_lazyRebalance_afterDeployLP() public {
        // Before: all 10_000e18 as ERC-20 on hook, 0 in Aave
        assertEq(MockERC20(aToken0).balanceOf(address(hook)), 0);
        assertEq(MockERC20(aToken1).balanceOf(address(hook)), 0);

        uint128 liq = _computeLiquidity(2_000e18, 2_000e18);
        _deployLP(liq);

        // After deploy: some tokens went to LP, rest should be partially in Aave
        // The lazy rebalance runs on both currencies after deployLiquidity
        uint256 aToken0Bal = MockERC20(aToken0).balanceOf(address(hook));
        uint256 aToken1Bal = MockERC20(aToken1).balanceOf(address(hook));

        // At least one currency should have aTokens (depends on how much LP consumed)
        assertTrue(aToken0Bal > 0 || aToken1Bal > 0, "Should have deposited excess to Aave");
    }

    function test_lazyRebalance_targetUtilization() public {
        // Deploy small LP to leave most tokens as idle ERC-20
        uint128 liq = _computeLiquidity(100e18, 100e18);
        _deployLP(liq);

        // Check utilization is near 80% target
        uint256 util0 = hook.currentUtilization(currency0);
        uint256 util1 = hook.currentUtilization(currency1);

        // At least one should be near 80%
        bool near0 = util0 > 700_000 && util0 < 900_000;
        bool near1 = util1 > 700_000 && util1 < 900_000;
        assertTrue(near0 || near1, "Utilization should be near 80%");
    }

    // ──── Aave withdrawal for LP deploy ────

    function test_deployLP_withdrawsFromAaveIfNeeded() public {
        // First deposit most tokens to Aave manually via a small deploy + lazy rebalance
        uint128 smallLiq = _computeLiquidity(100e18, 100e18);
        _deployLP(smallLiq);

        // Remove LP to get tokens back as ERC-20
        vm.prank(owner);
        hook.removeLiquidity(testPoolKey);

        // Trigger another rebalance to deposit most to Aave
        // We need to deposit more and trigger rebalance
        // Actually, after removeLiquidity, lazy rebalance runs again
        uint256 aToken0Bal = MockERC20(aToken0).balanceOf(address(hook));
        uint256 erc20_0 = token0.balanceOf(address(hook));

        // Now deploy larger LP that requires more than local ERC-20
        if (aToken0Bal > 0 && erc20_0 < 5_000e18) {
            // Need to withdraw from Aave to cover LP deployment
            uint128 bigLiq = _computeLiquidity(5_000e18, 5_000e18);
            _deployLP(bigLiq);

            // Should succeed — Aave funds covered the shortfall
            (,, uint128 liquidity) = hook.activePosition(testPoolKey.toId());
            assertEq(liquidity, bigLiq);
        }
    }

    // ──── setActiveTick repositions LP ────

    function test_setActiveTick_repositionsLP() public {
        uint128 liq = _computeLiquidity(5_000e18, 5_000e18);
        _deployLP(liq);

        // Verify initial position
        (int24 oldLower, int24 oldUpper,) = hook.activePosition(testPoolKey.toId());
        assertEq(oldLower, int24(0));
        assertEq(oldUpper, int24(60));

        // Reposition to tick 60
        vm.prank(owner);
        hook.setActiveTick(testPoolKey, int24(60));

        // Verify new position
        (int24 newLower, int24 newUpper, uint128 newLiq) = hook.activePosition(testPoolKey.toId());
        assertEq(newLower, int24(60));
        assertEq(newUpper, int24(120));
        assertEq(newLiq, liq); // same liquidity amount
        assertEq(hook.activeLowerTick(testPoolKey.toId()), int24(60));
    }

    function test_setActiveTick_noLPJustUpdatesTick() public {
        // No LP deployed
        vm.prank(owner);
        hook.setActiveTick(testPoolKey, int24(60));

        assertEq(hook.activeLowerTick(testPoolKey.toId()), int24(60));
        (,, uint128 liquidity) = hook.activePosition(testPoolKey.toId());
        assertEq(liquidity, 0);
    }

    function test_setActiveTick_unaligned_reverts() public {
        vm.prank(owner);
        vm.expectRevert();
        hook.setActiveTick(testPoolKey, int24(13)); // not aligned to tickSpacing=60
    }

    function test_setActiveTick_onlyOwner() public {
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, address(this)));
        hook.setActiveTick(testPoolKey, int24(60));
    }

    // ──── Yield accrual ────

    function test_yieldAccrual_countsTowardInventory() public {
        // Deposit some to Aave via LP deploy
        uint128 liq = _computeLiquidity(100e18, 100e18);
        _deployLP(liq);

        uint256 invBefore = hook.totalInventory(currency0);

        // Simulate yield
        mockAave.simulateYield(address(token0), address(hook), 10e18);

        uint256 invAfter = hook.totalInventory(currency0);
        assertEq(invAfter, invBefore + 10e18);
    }

    // ──── Owner deposit/withdraw ────

    function test_deposit_onlyOwner() public {
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, address(this)));
        hook.deposit(currency0, 100e18);
    }

    function test_withdraw_basic() public {
        uint256 ownerBefore = token0.balanceOf(owner);
        vm.prank(owner);
        hook.withdraw(currency0, 100e18);
        assertEq(token0.balanceOf(owner), ownerBefore + 100e18);
    }

    function test_withdraw_fromAave() public {
        // Trigger Aave deposit via LP deploy
        uint128 liq = _computeLiquidity(100e18, 100e18);
        _deployLP(liq);

        uint256 aTokenBal = MockERC20(aToken0).balanceOf(address(hook));
        if (aTokenBal > 0) {
            uint256 erc20Bal = token0.balanceOf(address(hook));
            uint256 withdrawAmt = erc20Bal + aTokenBal / 2;

            uint256 ownerBefore = token0.balanceOf(owner);
            vm.prank(owner);
            hook.withdraw(currency0, withdrawAmt);
            assertEq(token0.balanceOf(owner), ownerBefore + withdrawAmt);
        }
    }

    function test_withdraw_onlyOwner() public {
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, address(this)));
        hook.withdraw(currency0, 100e18);
    }

    // ──── Claims ────

    function test_redeemClaims_onlyOwner() public {
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, address(this)));
        hook.redeemClaims(currency0, 1e18);
    }

    // ──── Configuration ────

    function test_configureAaveToken_setsApproval() public view {
        uint256 allowance = token0.allowance(address(hook), address(mockAave));
        assertEq(allowance, type(uint256).max);
    }

    function test_configureAaveToken_onlyOwner() public {
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, address(this)));
        hook.configureAaveToken(address(token0), aToken0);
    }

    function test_setTargetUtilization() public {
        vm.prank(owner);
        hook.setTargetUtilization(900_000);
        assertEq(hook.targetUtilizationPips(), 900_000);
    }

    function test_setRebalanceThreshold() public {
        vm.prank(owner);
        hook.setRebalanceThreshold(100_000);
        assertEq(hook.rebalanceThresholdPips(), 100_000);
    }

    function test_setPoolLive_toggles() public {
        vm.prank(owner);
        hook.setPoolLive(testPoolKey, false);

        vm.prank(owner);
        hook.setPoolLive(testPoolKey, true);
    }

    // ──── Current utilization ────

    function test_currentUtilization_zeroWhenNoAave() public view {
        assertEq(hook.currentUtilization(currency0), 0);
    }

    // ──── No Aave configured ────

    function test_noop_whenNoAaveConfigured() public {
        // Deploy a fresh hook without Aave token configuration
        uint160 flags2 = uint160(
            Hooks.AFTER_INITIALIZE_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG
                | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG
        );
        AaveRehypothecatingSpreadQuoterHook hook2 = AaveRehypothecatingSpreadQuoterHook(
            address(uint160((uint256(type(uint160).max) - (1 << 14)) & clearAllHookPermissionsMask | flags2))
        );
        deployCodeTo(
            "AaveRehypothecatingSpreadQuoterHook",
            abi.encode(
                manager,
                address(attestationRegistry),
                uint32(100_000),
                owner,
                address(mockAave),
                TARGET_UTILIZATION,
                REBALANCE_THRESHOLD
            ),
            address(hook2)
        );

        PoolKey memory poolKey2 = PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: 10,
            hooks: IHooks(address(hook2))
        });
        manager.initialize(poolKey2, TickMath.getSqrtPriceAtTick(5));

        vm.startPrank(owner);
        hook2.updatePricingState(
            poolKey2,
            SpreadQuoterBase.PricingState({
                bidFeePips: BID_FEE_PIPS, askFeePips: ASK_FEE_PIPS, attestedDiscountBps: 0, live: true
            })
        );

        // Deposit and deploy LP without Aave tokens
        token0.mint(owner, 1_000e18);
        token1.mint(owner, 1_000e18);
        token0.approve(address(hook2), type(uint256).max);
        token1.approve(address(hook2), type(uint256).max);
        hook2.deposit(currency0, 1_000e18);
        hook2.deposit(currency1, 1_000e18);

        // Compute liquidity for this pool
        int24 activeTick2 = hook2.activeLowerTick(poolKey2.toId());
        (uint160 sqrtPrice2,,,) = manager.getSlot0(poolKey2.toId());
        uint128 liq2 = LiquidityAmounts.getLiquidityForAmounts(
            sqrtPrice2,
            TickMath.getSqrtPriceAtTick(activeTick2),
            TickMath.getSqrtPriceAtTick(activeTick2 + poolKey2.tickSpacing),
            500e18,
            500e18
        );
        hook2.deployLiquidity(poolKey2, liq2);
        vm.stopPrank();

        // Swap should work — no Aave interaction
        swap(poolKey2, true, -1e18, "");

        // No aTokens
        assertEq(MockERC20(aToken0).balanceOf(address(hook2)), 0);
        assertEq(MockERC20(aToken1).balanceOf(address(hook2)), 0);
    }

    // ──── Auto-Reposition ────

    function test_autoReposition_zeroForOnePushesBelowRange() public {
        uint128 liq = _computeLiquidity(5_000e18, 5_000e18);
        _deployLP(liq);

        // Verify initial LP at [0, 60)
        (int24 tickLower,, uint128 liquidity) = hook.activePosition(testPoolKey.toId());
        assertEq(tickLower, int24(0));
        assertEq(liquidity, liq);

        // Large zeroForOne swap to push tick below range
        swap(testPoolKey, true, -8_000e18, "");

        // afterSwap should have auto-repositioned to adjacent range [-60, 0)
        (int24 newLower, int24 newUpper, uint128 newLiq) = hook.activePosition(testPoolKey.toId());
        assertEq(newLower, int24(-60), "Repositioned to [-60, 0)");
        assertEq(newUpper, int24(0));
        assertEq(newLiq, liq, "Liquidity preserved");
        assertEq(hook.activeLowerTick(testPoolKey.toId()), int24(-60));

        // oneForZero swap (pushing tick back up into new range) should succeed
        BalanceDelta delta = swap(testPoolKey, false, -1e18, "");
        assertTrue(delta.amount0() > 0, "oneForZero should work after reposition");
    }

    function test_autoReposition_oneForZeroPushesAboveRange() public {
        uint128 liq = _computeLiquidity(5_000e18, 5_000e18);
        _deployLP(liq);

        // Large oneForZero swap to push tick above range
        swap(testPoolKey, false, -8_000e18, "");

        // afterSwap should have auto-repositioned to adjacent range [60, 120)
        (int24 newLower, int24 newUpper, uint128 newLiq) = hook.activePosition(testPoolKey.toId());
        assertEq(newLower, int24(60), "Repositioned to [60, 120)");
        assertEq(newUpper, int24(120));
        assertEq(newLiq, liq, "Liquidity preserved");

        // zeroForOne swap (pushing tick back down into new range) should succeed
        BalanceDelta delta = swap(testPoolKey, true, -1e18, "");
        assertTrue(delta.amount1() > 0, "zeroForOne should work after reposition");
    }

    function test_autoReposition_noopWhenInRange() public {
        uint128 liq = _computeLiquidity(5_000e18, 5_000e18);
        _deployLP(liq);

        // Small swap that stays in range
        swap(testPoolKey, true, -1e18, "");

        // Position should be unchanged
        (int24 tickLower, int24 tickUpper, uint128 liquidity) = hook.activePosition(testPoolKey.toId());
        assertEq(tickLower, int24(0));
        assertEq(tickUpper, int24(60));
        assertEq(liquidity, liq);
        assertEq(hook.activeLowerTick(testPoolKey.toId()), int24(0));
    }

    function test_autoReposition_aaveRebalanceAfterReposition() public {
        uint128 liq = _computeLiquidity(5_000e18, 5_000e18);
        _deployLP(liq);

        // Large oneForZero swap pushes tick above range → reposition from [0,60) to [60,120).
        // This changes the LP from all-token1 to needing token0 from Aave, causing rebalance.
        swap(testPoolKey, false, -8_000e18, "");

        (int24 newLower,,) = hook.activePosition(testPoolKey.toId());
        assertEq(newLower, int24(60), "LP repositioned to [60, 120)");

        // Verify the hook's total inventory is still tracked correctly
        uint256 inv0 = hook.totalInventory(currency0);
        uint256 inv1 = hook.totalInventory(currency1);
        assertTrue(inv0 > 0, "Token0 inventory exists");
        assertTrue(inv1 > 0, "Token1 inventory exists");
    }

    function test_autoReposition_oscillation() public {
        uint128 liq = _computeLiquidity(5_000e18, 5_000e18);
        _deployLP(liq);

        // Push tick down (zeroForOne) → LP repositions from [0, 60) to [-60, 0)
        swap(testPoolKey, true, -8_000e18, "");

        (int24 lowerAfterDown,,) = hook.activePosition(testPoolKey.toId());
        assertEq(lowerAfterDown, int24(-60), "LP at [-60, 0) after downward move");

        // Push tick back up past the LP range. The LP at [-60, 0) has ~10k token0
        // (deployed at MIN_TICK, below range → all token0). Need >10.5k token1
        // input (accounting for 5% fee) to exhaust the LP and push tick above 0.
        swap(testPoolKey, false, -15_000e18, "");

        (int24 lowerAfterUp,, uint128 finalLiq) = hook.activePosition(testPoolKey.toId());
        assertEq(lowerAfterUp, int24(0), "LP back at [0, 60) after upward move");
        assertEq(finalLiq, liq, "Liquidity preserved through oscillation");

        // zeroForOne swap (pushing tick back into the new range) should work
        BalanceDelta delta2 = swap(testPoolKey, true, -1e18, "");
        assertTrue(delta2.amount1() > 0, "zeroForOne works after oscillation");
    }
}
