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
import {Constants} from "@uniswap/v4-core/test/utils/Constants.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {AaveRehypothecatingFlatQuoterHook} from "../../src/propamm/AaveRehypothecatingFlatQuoterHook.sol";
import {FlatQuoterBase} from "../../src/propamm/base/FlatQuoterBase.sol";
import {PropAMMIndex} from "../../src/propamm/PropAMMIndex.sol";
import {AttestationRegistry} from "../../src/propamm/AttestationRegistry.sol";
import {IPropAMMIndex} from "../../src/propamm/interfaces/IPropAMMIndex.sol";
import {IAttestationRegistry} from "../../src/propamm/interfaces/IAttestationRegistry.sol";
import {IAavePool} from "../../src/propamm/interfaces/IAavePool.sol";

/// @title Fork test for AaveRehypothecatingFlatQuoterHook against real Aave V3
/// @notice Tests real Aave V3 supply/withdraw on a mainnet fork with a DAI/USDC stable pair.
///         Validates that the hook handles decimal differences correctly (DAI=18dec, USDC=6dec)
///         and works end-to-end with real aTokens at 100% utilization (full JIT pattern).
///
///         Pricing formulas (decimal-aware):
///           _computeOutput: (amount * coefficient * 10^outDec) / (10^inDec * 1e18)
///           _computeInput:  ceil((outputAmount * 10^inDec * 1e18) / (coefficient * 10^outDec))
///
///         zeroForOne (DAI 18dec → USDC 6dec) with bid 0.999e18:
///           exactIn  1000 DAI  → (1000e18 * 999e15 * 1e6)  / (1e18 * 1e18) = 999e6  USDC
///           exactOut 500 USDC  → ceil(500e6 * 1e18 * 1e18 / (999e15 * 1e6)) = 500500500500500500501 DAI
///
///         oneForZero (USDC 6dec → DAI 18dec) with ask 0.998e18:
///           exactIn  1000 USDC → (1000e6 * 998e15 * 1e18)  / (1e6 * 1e18) = 998e18 DAI
///           exactOut 500 DAI   → ceil(500e18 * 1e6 * 1e18 / (998e15 * 1e18)) = 501002005 USDC
contract AaveRehypothecatingFlatQuoterHookForkTest is Test, Deployers {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;

    // ──── Mainnet Aave V3 Addresses ────

    address constant AAVE_V3_POOL = 0x87870Bca3F3fD6335C3F4ce8392D69350B4fA4E2;

    // Stable-stable pair: DAI (18 dec) / USDC (6 dec)
    // DAI (0x6B17...) < USDC (0xA0b8...) by address → currency0=DAI, currency1=USDC
    address constant DAI = 0x6B175474E89094C44Da98b954EedeAC495271d0F;
    address constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address constant A_DAI = 0x018008bfb33d285247A21d44E50697654f754e63;
    address constant A_USDC = 0x98C23E9d8f34FEFb1B7BD6a91B7FF122F4e16F5c;

    // ──── State ────

    PropAMMIndex public index;
    AttestationRegistry public attestationRegistry;
    AaveRehypothecatingFlatQuoterHook public hook;

    address owner = makeAddr("owner");
    PoolKey testPoolKey;

    Currency currencyDAI;
    Currency currencyUSDC;

    bool forked;

    // Flat coefficients — pure 1e18-scaled exchange rates.
    // Decimal conversion (DAI 18dec ↔ USDC 6dec) is handled automatically by FlatQuoterBase.
    uint128 constant BID_COEFFICIENT = 0.999e18; // zeroForOne (DAI → USDC): 99.9%
    uint128 constant ASK_COEFFICIENT = 0.998e18; // oneForZero (USDC → DAI): 99.8%

    // ──── Initial inventory ────

    uint256 constant INITIAL_DAI = 100_000e18;
    uint256 constant INITIAL_USDC = 100_000e6;

    function setUp() public {
        try vm.envString("MAINNET_RPC_URL") returns (string memory rpcUrl) {
            vm.createSelectFork(rpcUrl, 21_900_000);

            deployFreshManagerAndRouters();

            index = new PropAMMIndex();
            attestationRegistry = new AttestationRegistry(owner);

            currencyDAI = Currency.wrap(DAI);
            currencyUSDC = Currency.wrap(USDC);
            require(Currency.unwrap(currencyDAI) < Currency.unwrap(currencyUSDC), "bad ordering");

            // Deploy hook — 100% Aave utilization, 0% threshold (full JIT)
            uint160 flags = uint160(
                Hooks.AFTER_INITIALIZE_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_SWAP_FLAG
                    | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG
            );
            hook = AaveRehypothecatingFlatQuoterHook(
                address(uint160(uint256(type(uint160).max) & clearAllHookPermissionsMask | flags))
            );
            deployCodeTo(
                "AaveRehypothecatingFlatQuoterHook",
                abi.encode(
                    manager,
                    address(index),
                    address(attestationRegistry),
                    uint32(200_000),
                    owner,
                    AAVE_V3_POOL,
                    uint24(1_000_000), // 100% target utilization
                    uint24(0) // 0% threshold → always rebalance
                ),
                address(hook)
            );

            testPoolKey = PoolKey({
                currency0: currencyDAI,
                currency1: currencyUSDC,
                fee: 0,
                tickSpacing: 1,
                hooks: IHooks(address(hook))
            });

            manager.initialize(testPoolKey, Constants.SQRT_PRICE_1_1);

            vm.startPrank(owner);
            hook.configureAaveToken(DAI, A_DAI);
            hook.configureAaveToken(USDC, A_USDC);
            hook.updateFlatPricingState(
                testPoolKey,
                FlatQuoterBase.FlatPricingState({
                    bidCoefficient: BID_COEFFICIENT,
                    askCoefficient: ASK_COEFFICIENT,
                    attestedDiscountBps: 0,
                    live: true
                })
            );
            vm.stopPrank();

            deal(DAI, owner, 200_000e18);
            deal(USDC, owner, 200_000e6);

            vm.startPrank(owner);
            IERC20(DAI).approve(address(hook), type(uint256).max);
            IERC20(USDC).approve(address(hook), type(uint256).max);
            hook.deposit(currencyDAI, INITIAL_DAI);
            hook.deposit(currencyUSDC, INITIAL_USDC);
            vm.stopPrank();

            deal(DAI, address(this), 200_000e18);
            deal(USDC, address(this), 200_000e6);
            IERC20(DAI).approve(address(swapRouter), type(uint256).max);
            IERC20(USDC).approve(address(swapRouter), type(uint256).max);
            IERC20(DAI).approve(address(modifyLiquidityRouter), type(uint256).max);
            IERC20(USDC).approve(address(modifyLiquidityRouter), type(uint256).max);

            forked = true;
        } catch {
            console2.log("Skipping forked tests - no MAINNET_RPC_URL.");
        }
    }

    modifier onlyForked() {
        if (forked) {
            _;
            return;
        }
        console2.log("skipping forked test");
    }

    // ──── Test: Real Aave supply after swap ────

    function test_fork_realAaveSupply_afterSwap() public onlyForked {
        assertEq(IERC20(A_DAI).balanceOf(address(hook)), 0);
        assertEq(IERC20(A_USDC).balanceOf(address(hook)), 0);

        // zeroForOne exact-input 1000 DAI → 999 USDC
        // Hook receives 1000 DAI as claims, pays 999 USDC from ERC-20
        // Lazy rebalance: all 100k DAI ERC-20 → Aave
        swap(testPoolKey, true, -1000e18, "");

        // aDAI = full 100k deposit (claims are separate, not deposited to Aave)
        assertEq(IERC20(A_DAI).balanceOf(address(hook)), INITIAL_DAI, "All DAI ERC-20 deposited to Aave");
        assertEq(IERC20(DAI).balanceOf(address(hook)), 0, "Zero DAI ERC-20 remaining");
        assertEq(hook.claimBalance(currencyDAI), 1000e18, "1000 DAI as claims from swap input");
        // USDC: paid 999e6 output from 100k inventory
        assertEq(IERC20(USDC).balanceOf(address(hook)), INITIAL_USDC - 999e6, "USDC reduced by output");
        assertEq(IERC20(A_USDC).balanceOf(address(hook)), 0, "USDC not rebalanced (only input currency)");
    }

    // ──── Test: JIT withdraw from Aave ────

    function test_fork_jitWithdraw_onSwap() public onlyForked {
        // Step 1: oneForZero 1000 USDC → 998 DAI
        // Hook pays 998 DAI from ERC-20, receives 1000 USDC as claims
        // Lazy rebalance: all 100k USDC ERC-20 → Aave
        swap(testPoolKey, false, -1000e6, "");

        assertEq(IERC20(A_USDC).balanceOf(address(hook)), INITIAL_USDC, "All USDC ERC-20 to Aave");
        assertEq(IERC20(USDC).balanceOf(address(hook)), 0, "Zero USDC ERC-20");
        assertEq(hook.claimBalance(currencyUSDC), 1000e6, "1000 USDC claims from swap input");
        assertEq(IERC20(DAI).balanceOf(address(hook)), INITIAL_DAI - 998e18, "DAI reduced by output");

        // Step 2: zeroForOne exact-input 2000 DAI → 1998 USDC
        // Output 1998 USDC: burn 1000 claims + JIT withdraw 998 from Aave
        swap(testPoolKey, true, -2000e18, "");

        assertEq(IERC20(A_USDC).balanceOf(address(hook)), INITIAL_USDC - 998e6, "Withdrew 998 USDC from Aave");
        assertEq(hook.claimBalance(currencyUSDC), 0, "All USDC claims burned for settlement");
        assertEq(IERC20(USDC).balanceOf(address(hook)), 0, "Zero USDC ERC-20 after settlement");
    }

    // ──── Test: Yield accrual ────

    function test_fork_yieldAccrual_realAave() public onlyForked {
        // Push DAI to Aave via swap
        swap(testPoolKey, true, -1000e18, "");

        uint256 aDaiBefore = IERC20(A_DAI).balanceOf(address(hook));
        assertEq(aDaiBefore, INITIAL_DAI, "aDAI should equal full deposit");

        uint256 invBefore = hook.totalInventory(currencyDAI);
        assertEq(invBefore, INITIAL_DAI + 1000e18, "Inventory = deposit + swap input claims");

        // Advance 30 days for yield accrual
        vm.warp(block.timestamp + 30 days);
        vm.roll(block.number + 1);

        uint256 aDaiAfter = IERC20(A_DAI).balanceOf(address(hook));
        uint256 invAfter = hook.totalInventory(currencyDAI);
        uint256 yield = aDaiAfter - aDaiBefore;

        console2.log("Yield earned over 30 days:", yield);

        assertGt(aDaiAfter, aDaiBefore, "aDAI should increase from yield");
        assertGt(yield, 100e18, "Yield should be meaningful (>100 DAI on 100k deposit)");
        assertEq(invAfter, invBefore + yield, "Inventory increases by exactly the yield amount");
    }

    // ──── Test: Full deposit → swap → reverse → withdraw cycle ────

    function test_fork_fullCycle() public onlyForked {
        assertEq(IERC20(DAI).balanceOf(address(hook)), INITIAL_DAI);
        assertEq(IERC20(USDC).balanceOf(address(hook)), INITIAL_USDC);

        // Step 1: zeroForOne 5000 DAI → 4995 USDC
        // DAI: 100k ERC-20 → Aave, 5000 claims
        // USDC: 100k - 4995 = 95005 ERC-20
        swap(testPoolKey, true, -5000e18, "");

        assertEq(IERC20(A_DAI).balanceOf(address(hook)), INITIAL_DAI, "All DAI to Aave");
        assertEq(IERC20(DAI).balanceOf(address(hook)), 0);
        assertEq(hook.claimBalance(currencyDAI), 5000e18, "5000 DAI claims");
        assertEq(IERC20(USDC).balanceOf(address(hook)), INITIAL_USDC - 4995e6, "95005 USDC remaining");

        // Step 2: oneForZero 1000 USDC → 998 DAI
        // Output 998 DAI: burn from 5000 claims → 4002 claims remaining
        // Lazy rebalance USDC: 95005 ERC-20 → Aave
        swap(testPoolKey, false, -1000e6, "");

        assertEq(hook.claimBalance(currencyDAI), 5000e18 - 998e18, "4002 DAI claims after output");
        assertEq(IERC20(A_USDC).balanceOf(address(hook)), INITIAL_USDC - 4995e6, "95005 USDC to Aave");
        assertEq(IERC20(USDC).balanceOf(address(hook)), 0, "Zero USDC ERC-20 at 100% util");
        assertEq(hook.claimBalance(currencyUSDC), 1000e6, "1000 USDC claims from swap input");

        // Verify exact total inventories
        // DAI: 100k aToken + 4002 claims = 104002
        assertEq(hook.totalInventory(currencyDAI), INITIAL_DAI + 4002e18, "DAI inventory exact");
        // USDC: 95005 aToken + 1000 claims = 96005
        assertEq(hook.totalInventory(currencyUSDC), INITIAL_USDC - 4995e6 + 1000e6, "USDC inventory exact");

        // Step 3: Owner withdraws DAI from Aave
        uint256 ownerDaiBefore = IERC20(DAI).balanceOf(owner);
        uint256 withdrawAmount = IERC20(A_DAI).balanceOf(address(hook));
        vm.prank(owner);
        hook.withdraw(currencyDAI, withdrawAmount);
        assertEq(IERC20(DAI).balanceOf(owner) - ownerDaiBefore, withdrawAmount, "Owner received exact DAI");
    }

    // ──── Test: Gas profiling at 100% utilization ────

    function test_fork_gasProfile_jitSwap() public onlyForked {
        // Push USDC to Aave
        swap(testPoolKey, false, -1000e6, "");

        // JIT swap: must withdraw from Aave
        uint256 gasBefore = gasleft();
        swap(testPoolKey, true, -100e18, "");
        uint256 gasUsed = gasBefore - gasleft();
        console2.log("Gas used for JIT swap (100% util):", gasUsed);
    }

    function test_fork_gasProfile_noAaveNeeded() public onlyForked {
        uint256 gasBefore = gasleft();
        swap(testPoolKey, true, -100e18, "");
        uint256 gasUsed = gasBefore - gasleft();
        console2.log("Gas used for swap (no Aave needed):", gasUsed);
    }

    // ──── Test: aToken + claims + ERC-20 inventory accounting ────

    function test_fork_inventoryAccountingExact() public onlyForked {
        // After zeroForOne 1000 DAI → 999 USDC:
        swap(testPoolKey, true, -1000e18, "");

        // DAI breakdown
        assertEq(IERC20(DAI).balanceOf(address(hook)), 0, "DAI ERC-20 = 0");
        assertEq(IERC20(A_DAI).balanceOf(address(hook)), INITIAL_DAI, "aDAI = full deposit");
        assertEq(hook.claimBalance(currencyDAI), 1000e18, "DAI claims = swap input");
        assertEq(hook.totalInventory(currencyDAI), INITIAL_DAI + 1000e18, "DAI total = deposit + claims");

        // USDC breakdown
        assertEq(IERC20(USDC).balanceOf(address(hook)), INITIAL_USDC - 999e6, "USDC ERC-20 = initial - output");
        assertEq(IERC20(A_USDC).balanceOf(address(hook)), 0, "aUSDC = 0 (not rebalanced)");
        assertEq(hook.claimBalance(currencyUSDC), 0, "USDC claims = 0");
        assertEq(hook.totalInventory(currencyUSDC), INITIAL_USDC - 999e6, "USDC total = initial - output");
    }

    // ──── Test: Exact output zeroForOne (DAI → USDC) ────

    function test_fork_exactOutput_zeroForOne() public onlyForked {
        uint256 daiBefore = IERC20(DAI).balanceOf(address(this));
        uint256 usdcBefore = IERC20(USDC).balanceOf(address(this));

        // Request exactly 500 USDC output
        // _computeInput: ceil(500e6 * 1e18 * 1e18 / (999e15 * 1e6))
        //              = ceil(500e42 / 999e21) = 500500500500500500501
        swap(testPoolKey, true, 500e6, "");

        uint256 daiSpent = daiBefore - IERC20(DAI).balanceOf(address(this));
        uint256 usdcReceived = IERC20(USDC).balanceOf(address(this)) - usdcBefore;

        assertEq(usdcReceived, 500e6, "Exact USDC output");
        assertEq(daiSpent, 500500500500500500501, "Exact DAI input (ceil division)");
    }

    // ──── Test: Exact output oneForZero (USDC → DAI) ────

    function test_fork_exactOutput_oneForZero() public onlyForked {
        uint256 usdcBefore = IERC20(USDC).balanceOf(address(this));
        uint256 daiBefore = IERC20(DAI).balanceOf(address(this));

        // Request exactly 500 DAI output
        // _computeInput: ceil(500e18 * 1e6 * 1e18 / (998e15 * 1e18))
        //              = ceil(500e42 / 998e33) = 501002005
        swap(testPoolKey, false, 500e18, "");

        uint256 usdcSpent = usdcBefore - IERC20(USDC).balanceOf(address(this));
        uint256 daiReceived = IERC20(DAI).balanceOf(address(this)) - daiBefore;

        assertEq(daiReceived, 500e18, "Exact DAI output");
        assertEq(usdcSpent, 501002005, "Exact USDC input (ceil division)");
    }

    // ──── Test: Exact output with JIT Aave withdrawal ────

    function test_fork_exactOutput_jitWithdraw() public onlyForked {
        // Push USDC to Aave: oneForZero 1000 USDC → 998 DAI
        swap(testPoolKey, false, -1000e6, "");

        assertEq(IERC20(A_USDC).balanceOf(address(hook)), INITIAL_USDC, "All USDC in Aave");
        assertEq(hook.claimBalance(currencyUSDC), 1000e6, "1000 USDC claims");

        // Exact output zeroForOne: request 2000 USDC
        // Settlement: burn 1000 claims + JIT withdraw 1000 from Aave
        swap(testPoolKey, true, 2000e6, "");

        assertEq(IERC20(A_USDC).balanceOf(address(hook)), INITIAL_USDC - 1000e6, "Withdrew 1000 from Aave");
        assertEq(hook.claimBalance(currencyUSDC), 0, "All claims consumed");
    }

    // ──── Test: Exact-input/exact-output pricing consistency ────

    function test_fork_exactInputOutput_consistency() public onlyForked {
        // Exact input: 1000 DAI → 999 USDC
        uint256 usdcBefore = IERC20(USDC).balanceOf(address(this));
        swap(testPoolKey, true, -1000e18, "");
        uint256 usdcFromExactIn = IERC20(USDC).balanceOf(address(this)) - usdcBefore;
        assertEq(usdcFromExactIn, 999e6, "Exact-in output = 999 USDC");

        // Exact output: request 999 USDC → should consume exactly 1000 DAI
        // _computeInput: ceil(999e6 * 1e18 * 1e18 / (999e15 * 1e6))
        //              = ceil(999e42 / 999e21) = ceil(1e21) = 1000e18 exactly
        uint256 daiBefore = IERC20(DAI).balanceOf(address(this));
        swap(testPoolKey, true, int256(usdcFromExactIn), "");
        uint256 daiConsumed = daiBefore - IERC20(DAI).balanceOf(address(this));

        assertEq(daiConsumed, 1000e18, "Exact-out consumes same DAI as exact-in (no rounding loss)");
    }

    // ──── Test: Multiple swaps stress test ────

    function test_fork_multipleSwaps_100pctUtil() public onlyForked {
        // Track cumulative hook P&L across all swaps
        uint256 hookDaiStart = hook.totalInventory(currencyDAI);
        uint256 hookUsdcStart = hook.totalInventory(currencyUSDC);

        for (uint256 i = 0; i < 5; i++) {
            // Exact input: 500 DAI → 499.5 USDC (hook earns 0.5 DAI equivalent spread)
            swap(testPoolKey, true, -500e18, "");
            // Exact output: request 400 DAI, pays ceil(400/0.998) = 401 USDC (hook earns ~1 USDC spread)
            swap(testPoolKey, false, 400e18, "");
        }

        uint256 hookDaiEnd = hook.totalInventory(currencyDAI);
        uint256 hookUsdcEnd = hook.totalInventory(currencyUSDC);

        // Per iteration:
        //   zeroForOne exact-in 500 DAI: hook gains 500e18 DAI claims, pays 499_500_000 USDC
        //   oneForZero exact-out 400 DAI: hook gains 400_801_604 USDC claims, pays 400e18 DAI
        //     (400801604 = ceil(400e18 * 1e6 * 1e18 / (998e15 * 1e18)) = ceil(400e9/998))
        //   DAI net: +500e18 - 400e18 = +100e18
        //   USDC net: +400_801_604 - 499_500_000 = -98_698_396
        // Over 5 iterations: DAI +500e18, USDC -493_491_980
        // Net P&L positive: 500 DAI gained > ~493.5 USDC lost (profit in value terms)
        assertEq(hookDaiEnd - hookDaiStart, 500e18, "Hook DAI gain = 5 * 100e18");
        // USDC loss = 5 * (499_500_000 - 400_801_604) = 5 * 98_698_396 = 493_491_980
        // Tolerance of 1 for aToken scaled balance rounding during Aave supply/withdraw
        assertApproxEqAbs(hookUsdcStart - hookUsdcEnd, 493_491_980, 1, "Hook USDC loss = 5 * 98698396");
    }
}
