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
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {Constants} from "@uniswap/v4-core/test/utils/Constants.sol";
import {CustomRevert} from "@uniswap/v4-core/src/libraries/CustomRevert.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {AaveRehypothecatingFlatQuoterHook} from "../../src/propamm/AaveRehypothecatingFlatQuoterHook.sol";
import {FlatQuoterBase} from "../../src/propamm/base/FlatQuoterBase.sol";
import {PropAMMIndex} from "../../src/propamm/PropAMMIndex.sol";
import {AttestationRegistry} from "../../src/propamm/AttestationRegistry.sol";
import {IPropAMMIndex, QuoterType, QuoterEntry} from "../../src/propamm/interfaces/IPropAMMIndex.sol";
import {IAttestationRegistry, Attestation} from "../../src/propamm/interfaces/IAttestationRegistry.sol";
import {MockAttestationSigner} from "./mocks/MockAttestationSigner.sol";
import {MockAavePool} from "./mocks/MockAavePool.sol";
import {IAavePool} from "../../src/propamm/interfaces/IAavePool.sol";
import {QuoterHookData} from "../../src/propamm/interfaces/IQuoterHook.sol";

contract AaveRehypothecatingFlatQuoterHookTest is Test, Deployers {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;

    PropAMMIndex public index;
    AttestationRegistry public attestationRegistry;
    AaveRehypothecatingFlatQuoterHook public hook;
    MockAavePool public mockAave;

    address owner = makeAddr("owner");
    uint256 attesterPk;
    address attester;

    PoolKey testPoolKey;

    MockERC20 token0;
    MockERC20 token1;
    address aToken0;
    address aToken1;

    // Coefficients: 0.998e18 bid, 0.995e18 ask (tight stable-stable spread)
    uint128 constant BID_COEFFICIENT = 0.998e18;
    uint128 constant ASK_COEFFICIENT = 0.995e18;

    // 80% target utilization, 5% rebalance threshold
    uint24 constant TARGET_UTILIZATION = 800_000;
    uint24 constant REBALANCE_THRESHOLD = 50_000;

    function setUp() public {
        deployFreshManagerAndRouters();
        deployMintAndApprove2Currencies();

        token0 = MockERC20(Currency.unwrap(currency0));
        token1 = MockERC20(Currency.unwrap(currency1));

        index = new PropAMMIndex();
        attestationRegistry = new AttestationRegistry(owner);

        (attester, attesterPk) = makeAddrAndKey("attester");
        vm.prank(owner);
        attestationRegistry.addAttester(attester);

        // Deploy mock Aave pool
        mockAave = new MockAavePool();
        aToken0 = mockAave.addAsset(address(token0));
        aToken1 = mockAave.addAsset(address(token1));

        // Fund mock Aave with underlying liquidity for withdrawals
        token0.mint(address(mockAave), 100_000e18);
        token1.mint(address(mockAave), 100_000e18);

        // Deploy hook at flag-mined address
        uint160 flags = uint160(
            Hooks.AFTER_INITIALIZE_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_SWAP_FLAG
                | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG
        );
        hook = AaveRehypothecatingFlatQuoterHook(address(uint160(uint256(type(uint160).max) & clearAllHookPermissionsMask | flags)));
        deployCodeTo(
            "AaveRehypothecatingFlatQuoterHook",
            abi.encode(
                manager,
                address(index),
                address(attestationRegistry),
                uint32(100_000),
                owner,
                address(mockAave),
                TARGET_UTILIZATION,
                REBALANCE_THRESHOLD
            ),
            address(hook)
        );

        // Create pool key
        testPoolKey =
            PoolKey({currency0: currency0, currency1: currency1, fee: 0, tickSpacing: 1, hooks: IHooks(address(hook))});

        // Initialize pool (triggers afterInitialize → registers in index)
        manager.initialize(testPoolKey, Constants.SQRT_PRICE_1_1);

        // Configure Aave tokens
        vm.startPrank(owner);
        hook.configureAaveToken(address(token0), aToken0);
        hook.configureAaveToken(address(token1), aToken1);

        // Set flat pricing state
        hook.updateFlatPricingState(
            testPoolKey,
            FlatQuoterBase.FlatPricingState({
                bidCoefficient: BID_COEFFICIENT, askCoefficient: ASK_COEFFICIENT, attestedDiscountBps: 5, live: true
            })
        );

        // Deposit inventory into the hook
        token0.mint(owner, 1_000e18);
        token1.mint(owner, 1_000e18);
        token0.approve(address(hook), type(uint256).max);
        token1.approve(address(hook), type(uint256).max);
        hook.deposit(currency0, 1_000e18);
        hook.deposit(currency1, 1_000e18);
        vm.stopPrank();
    }

    // ──── Registration ────

    function test_afterInitialize_registersInIndex() public view {
        assertTrue(index.isRegistered(address(hook), testPoolKey));
        QuoterEntry memory entry = index.getQuoter(address(hook), testPoolKey);
        assertEq(uint8(entry.quoterType), uint8(QuoterType.HOOKDATA));
        assertEq(entry.maxGas, 100_000);
        assertTrue(entry.isLive);
    }

    // ──── Blocks liquidity ────

    function test_blocksLiquidity() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                CustomRevert.WrappedError.selector,
                address(hook),
                IHooks.beforeAddLiquidity.selector,
                abi.encodeWithSelector(FlatQuoterBase.LiquidityNotAllowed.selector),
                abi.encodeWithSelector(Hooks.HookCallFailed.selector)
            )
        );
        modifyLiquidityRouter.modifyLiquidity(
            testPoolKey, ModifyLiquidityParams({tickLower: -1, tickUpper: 1, liquidityDelta: 1e18, salt: 0}), ""
        );
    }

    // ──── Basic flat swap ────

    function test_flatSwap_exactInput_zeroForOne() public {
        swap(testPoolKey, true, -1e18, "");
        // Expected output: 1e18 * 0.998 = 0.998e18
    }

    function test_flatSwap_exactInput_oneForZero() public {
        swap(testPoolKey, false, -1e18, "");
        // Expected output: 1e18 * 0.995 = 0.995e18
    }

    function test_flatSwap_exactOutput_zeroForOne() public {
        swap(testPoolKey, true, 0.998e18, "");
    }

    // ──── Aave: Lazy rebalance deposits excess to Aave ────

    function test_lazyRebalance_depositsExcessToAave() public {
        // After deposit: 1000e18 token0 sits as ERC-20 on hook, 0 in Aave
        uint256 aTokenBalBefore = MockERC20(aToken0).balanceOf(address(hook));
        assertEq(aTokenBalBefore, 0);

        // Swap zeroForOne: hook receives token0 as input (claims), pays token1
        // This triggers lazy rebalance on the input currency (token0):
        // But token0 input is minted as claims, not ERC-20. Lazy rebalance checks ERC-20 only.
        // The 1000e18 ERC-20 token0 is still there with 0 aTokens → well below 80% target → deposits.
        swap(testPoolKey, true, -10e18, "");

        // After swap: lazy rebalance should have deposited token0 ERC-20 to Aave
        uint256 aTokenBalAfter = MockERC20(aToken0).balanceOf(address(hook));
        assertTrue(aTokenBalAfter > 0, "aTokens should have been deposited");

        // Roughly 80% of the 1000e18 ERC-20 should now be in Aave
        // (ERC-20 total ≈ 1000e18, aToken target = 800e18)
        assertApproxEqRel(aTokenBalAfter, 800e18, 0.05e18); // within 5%
    }

    function test_lazyRebalance_skipsWhenWithinThreshold() public {
        // Manually supply ~80% to Aave to start near target
        // We'll do this by executing a swap that triggers initial rebalance
        swap(testPoolKey, true, -10e18, "");
        uint256 aTokenBalAfterFirst = MockERC20(aToken0).balanceOf(address(hook));
        assertTrue(aTokenBalAfterFirst > 0);

        // Now do a tiny swap — the drift should be within threshold (5%)
        // so no further Aave ops should occur
        uint256 aTokenBalBefore = MockERC20(aToken0).balanceOf(address(hook));
        swap(testPoolKey, true, -0.001e18, "");
        uint256 aTokenBalAfter = MockERC20(aToken0).balanceOf(address(hook));

        // aToken balance should be unchanged (no deposit triggered)
        assertEq(aTokenBalBefore, aTokenBalAfter, "No rebalance expected for tiny swap");
    }

    // ──── Aave: Withdrawal when local liquidity insufficient ────

    function test_swap_withdrawsFromAaveIfNeeded() public {
        // First swap to deposit most token1 to Aave via lazy rebalance
        // Swap oneForZero: input=token1, output=token0. Lazy rebalance on token1.
        swap(testPoolKey, false, -100e18, "");

        uint256 aToken1Bal = MockERC20(aToken1).balanceOf(address(hook));
        assertTrue(aToken1Bal > 0, "Should have token1 in Aave");

        // Now swap zeroForOne: needs token1 output.
        // Hook's token1 ERC-20 balance is reduced, so it should withdraw from Aave.
        uint256 hookToken1Before = token1.balanceOf(address(hook));
        uint256 swapAmount = hookToken1Before + 50e18; // request more than local ERC-20

        // Need to check total inventory is sufficient first
        uint256 totalInv = hook.totalInventory(currency1);
        assertTrue(totalInv >= swapAmount, "Total inventory should cover swap");

        // Calculate exact output we want (limited by inventory)
        // For exact input: output = input * bid_coefficient / 1e18
        // We want enough input so output ≈ swapAmount
        // output = input * 0.998 → input = output / 0.998
        // But let's just do an exact input swap that needs more token1 than ERC-20
        uint256 inputNeeded = (swapAmount * 1e18 + BID_COEFFICIENT - 1) / BID_COEFFICIENT;
        swap(testPoolKey, true, -int256(inputNeeded), "");

        // Swap should succeed (withdrew from Aave to cover shortfall)
    }

    // ──── Total inventory ────

    function test_totalInventory_allSources() public {
        // Initially: 1000e18 ERC-20 for each token, 0 claims, 0 aTokens
        assertEq(hook.totalInventory(currency0), 1_000e18);

        // Swap to generate claims + trigger Aave deposit
        swap(testPoolKey, true, -10e18, "");

        // Total inventory should still be ≈ 1000e18 for token0
        // (some ERC-20 moved to Aave as aTokens + claims from input)
        uint256 inv = hook.totalInventory(currency0);
        // token0 had 1000e18, received 10e18 as claims = ~1010e18 total
        assertApproxEqRel(inv, 1_010e18, 0.01e18);
    }

    // ──── Configure Aave token ────

    function test_configureAaveToken_setsApproval() public {
        // Check that the hook approved Aave pool to spend underlying
        uint256 allowance = token0.allowance(address(hook), address(mockAave));
        assertEq(allowance, type(uint256).max);
    }

    function test_configureAaveToken_onlyOwner() public {
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, address(this)));
        hook.configureAaveToken(address(token0), aToken0);
    }

    // ──── Yield accrual ────

    function test_yieldAccrual_countsTowardInventory() public {
        // Trigger Aave deposit via swap
        swap(testPoolKey, true, -10e18, "");

        uint256 invBefore = hook.totalInventory(currency0);

        // Simulate yield: Aave mints extra aTokens to the hook
        mockAave.simulateYield(address(token0), address(hook), 10e18);

        uint256 invAfter = hook.totalInventory(currency0);
        assertEq(invAfter, invBefore + 10e18, "Yield should increase inventory");
    }

    // ──── Pricing unchanged from FlatLevel ────

    function test_getIndicativeQuote_flat_zeroForOne() public view {
        uint256 output = hook.getIndicativeQuote(testPoolKey, true, -100e18, "");
        // 100 * 0.998 = 99.8
        assertEq(output, 99.8e18);
    }

    function test_getIndicativeQuote_flat_oneForZero() public view {
        uint256 output = hook.getIndicativeQuote(testPoolKey, false, -100e18, "");
        // 100 * 0.995 = 99.5
        assertEq(output, 99.5e18);
    }

    function test_getIndicativeQuote_unlivePool_returnsZero() public {
        vm.prank(owner);
        hook.setPoolLive(testPoolKey, false);
        uint256 output = hook.getIndicativeQuote(testPoolKey, true, -100e18, "");
        assertEq(output, 0);
    }

    function test_getIndicativeQuote_withAttestation() public {
        Attestation memory att = Attestation({
            attester: attester,
            swapper: makeAddr("swapper"),
            deadline: block.timestamp + 1 hours,
            swapHash: keccak256("test")
        });
        bytes memory attestationData = MockAttestationSigner.sign(vm, attesterPk, att, address(attestationRegistry));
        bytes memory hookData = abi.encode(QuoterHookData({attestationData: attestationData, curveUpdateData: ""}));

        uint256 output = hook.getIndicativeQuote(testPoolKey, true, -100e18, hookData);
        // Base = 99.8e18, +5 bps → 99.8 * 10005/10000 = 99.8499e18
        assertEq(output, 99.8499e18);
    }

    // ──── Inventory-aware quoting ────

    function test_quote_capsAtInventory_exactInput() public {
        // Total token1 inventory = 1000e18
        // Request exact input that would produce more than inventory
        // input * 0.998 > 1000 → input > 1002.004...
        uint256 output = hook.getIndicativeQuote(testPoolKey, true, -2000e18, "");
        // Should cap at 1000e18 (total inventory for token1)
        assertEq(output, 1_000e18);
    }

    function test_quote_returnsZero_exactOutput_insufficientInventory() public {
        // Request exact output of 2000e18 token1 — more than inventory
        uint256 output = hook.getIndicativeQuote(testPoolKey, true, 2000e18, "");
        assertEq(output, 0, "Should return 0 when inventory insufficient for exact output");
    }

    function test_quote_includesAaveBalance() public {
        // Trigger Aave deposit via swap
        swap(testPoolKey, true, -10e18, "");

        // Verify aTokens exist
        uint256 aTokenBal = MockERC20(aToken0).balanceOf(address(hook));
        assertTrue(aTokenBal > 0);

        // Quote should include aToken balance in inventory cap
        // Token0 inventory = ERC-20 + claims + aTokens
        uint256 totalInv = hook.totalInventory(currency0);
        uint256 output = hook.getIndicativeQuote(testPoolKey, false, -int256(totalInv * 2), "");
        // Should be capped at totalInv
        assertEq(output, totalInv);
    }

    // ──── Noop when no Aave configured ────

    function test_noop_whenNoAaveConfigured() public {
        // Deploy a fresh hook without Aave token configuration
        uint160 flags2 = uint160(
            Hooks.AFTER_INITIALIZE_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_SWAP_FLAG
                | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG
        );
        AaveRehypothecatingFlatQuoterHook hook2 = AaveRehypothecatingFlatQuoterHook(
            address(uint160((uint256(type(uint160).max) - (1 << 14)) & clearAllHookPermissionsMask | flags2))
        );
        deployCodeTo(
            "AaveRehypothecatingFlatQuoterHook",
            abi.encode(
                manager,
                address(index),
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
            currency0: currency0, currency1: currency1, fee: 0, tickSpacing: 60, hooks: IHooks(address(hook2))
        });
        manager.initialize(poolKey2, Constants.SQRT_PRICE_1_1);

        vm.startPrank(owner);
        hook2.updateFlatPricingState(
            poolKey2,
            FlatQuoterBase.FlatPricingState({
                bidCoefficient: BID_COEFFICIENT, askCoefficient: ASK_COEFFICIENT, attestedDiscountBps: 0, live: true
            })
        );

        // Deposit without configuring aTokens
        token0.mint(owner, 100e18);
        token1.mint(owner, 100e18);
        token0.approve(address(hook2), type(uint256).max);
        token1.approve(address(hook2), type(uint256).max);
        hook2.deposit(currency0, 100e18);
        hook2.deposit(currency1, 100e18);
        vm.stopPrank();

        // Swap should work — no Aave interaction, behaves like FlatLevel
        swap(poolKey2, true, -1e18, "");

        // No aTokens should exist for this hook
        assertEq(MockERC20(aToken0).balanceOf(address(hook2)), 0);
        assertEq(MockERC20(aToken1).balanceOf(address(hook2)), 0);
    }

    // ──── Owner: deposit / withdraw ────

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
        // First trigger Aave deposit
        swap(testPoolKey, true, -10e18, "");
        uint256 aTokenBal = MockERC20(aToken0).balanceOf(address(hook));
        assertTrue(aTokenBal > 0);

        // Withdraw more than ERC-20 balance — should redeem from Aave
        uint256 erc20Bal = token0.balanceOf(address(hook));
        uint256 withdrawAmt = erc20Bal + aTokenBal / 2;

        uint256 ownerBefore = token0.balanceOf(owner);
        vm.prank(owner);
        hook.withdraw(currency0, withdrawAmt);
        assertEq(token0.balanceOf(owner), ownerBefore + withdrawAmt);
    }

    function test_withdraw_onlyOwner() public {
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, address(this)));
        hook.withdraw(currency0, 100e18);
    }

    // ──── Owner: redeemClaims ────

    function test_redeemClaims() public {
        // Generate claims via swap
        swap(testPoolKey, true, -10e18, "");
        uint256 claims = hook.claimBalance(currency0);
        assertTrue(claims > 0);

        uint256 erc20Before = token0.balanceOf(address(hook));
        vm.prank(owner);
        hook.redeemClaims(currency0, claims);

        assertEq(hook.claimBalance(currency0), 0);
        assertEq(token0.balanceOf(address(hook)), erc20Before + claims);
    }

    function test_redeemClaims_onlyOwner() public {
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, address(this)));
        hook.redeemClaims(currency0, 1e18);
    }

    // ──── Owner: configuration ────

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

    function test_setPoolLive_updatesIndex() public {
        vm.prank(owner);
        hook.setPoolLive(testPoolKey, false);
        assertFalse(index.getQuoter(address(hook), testPoolKey).isLive);

        vm.prank(owner);
        hook.setPoolLive(testPoolKey, true);
        assertTrue(index.getQuoter(address(hook), testPoolKey).isLive);
    }

    // ──── Current utilization ────

    function test_currentUtilization_zeroWhenNoAave() public view {
        // Before any swaps, all inventory is ERC-20, none in Aave
        assertEq(hook.currentUtilization(currency0), 0);
    }

    function test_currentUtilization_afterRebalance() public {
        // Trigger Aave deposit
        swap(testPoolKey, true, -10e18, "");

        uint256 util = hook.currentUtilization(currency0);
        // Should be ≈ 80% (800_000 pips)
        assertApproxEqAbs(util, 800_000, 50_000); // within 5%
    }

    // ──── Claim lifecycle ────

    function test_claimLifecycle_accumulateAndBurnOnReverseSwap() public {
        // Before swap: no claims
        assertEq(hook.claimBalance(currency0), 0);

        // Swap zeroForOne: hook receives token0 as claims
        swap(testPoolKey, true, -1e18, "");
        assertEq(hook.claimBalance(currency0), 1e18);

        // Reverse swap (oneForZero): hook burns token0 claims to settle output
        uint256 hookErc20Before = token0.balanceOf(address(hook));
        swap(testPoolKey, false, -1e18, "");

        // token0 claims should be partially burned for the output
        uint256 output0 = 0.995e18; // 1e18 * ASK_COEFFICIENT / 1e18
        assertEq(hook.claimBalance(currency0), 1e18 - output0);
        // hook's ERC-20 token0 unchanged (claims were used)
        assertEq(token0.balanceOf(address(hook)), hookErc20Before);
    }

    // ──── Unlive pool returns zero delta ────

    function test_beforeSwap_unlivePool_noExecution() public {
        vm.prank(owner);
        hook.setPoolLive(testPoolKey, false);

        BalanceDelta delta = swap(testPoolKey, true, -1e18, "");
        assertEq(delta.amount1(), int128(0));
    }
}
