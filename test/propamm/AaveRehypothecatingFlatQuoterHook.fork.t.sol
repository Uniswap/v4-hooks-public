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

    function setUp() public {
        try vm.envString("MAINNET_RPC_URL") returns (string memory rpcUrl) {
            console2.log("Forked Ethereum mainnet for Aave V3 integration test");
            vm.createSelectFork(rpcUrl, 21_900_000);

            deployFreshManagerAndRouters();

            index = new PropAMMIndex();
            attestationRegistry = new AttestationRegistry(owner);

            // Currency ordering: DAI (0x6B17...) < USDC (0xA0b8...)
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

            // Create pool key
            testPoolKey = PoolKey({
                currency0: currencyDAI,
                currency1: currencyUSDC,
                fee: 0,
                tickSpacing: 1,
                hooks: IHooks(address(hook))
            });

            manager.initialize(testPoolKey, Constants.SQRT_PRICE_1_1);

            // Configure Aave tokens + pricing
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

            // Fund owner and deposit inventory
            deal(DAI, owner, 200_000e18);
            deal(USDC, owner, 200_000e6);

            vm.startPrank(owner);
            IERC20(DAI).approve(address(hook), type(uint256).max);
            IERC20(USDC).approve(address(hook), type(uint256).max);
            hook.deposit(currencyDAI, 100_000e18);
            hook.deposit(currencyUSDC, 100_000e6);
            vm.stopPrank();

            // Fund test contract for swaps
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
        assertEq(IERC20(A_DAI).balanceOf(address(hook)), 0, "No aDAI before");
        assertEq(IERC20(A_USDC).balanceOf(address(hook)), 0, "No aUSDC before");

        // zeroForOne (DAI → USDC): hook receives DAI claims, pays USDC from inventory
        // After: lazy rebalance pushes DAI ERC-20 to Aave
        swap(testPoolKey, true, -1000e18, ""); // 1000 DAI → ~999 USDC

        uint256 aDaiAfter = IERC20(A_DAI).balanceOf(address(hook));
        console2.log("aDAI after swap:", aDaiAfter);
        assertTrue(aDaiAfter > 0, "DAI should be in Aave after lazy rebalance");
        assertEq(IERC20(DAI).balanceOf(address(hook)), 0, "All DAI ERC-20 in Aave at 100% util");
    }

    // ──── Test: JIT withdraw from Aave ────

    function test_fork_jitWithdraw_onSwap() public onlyForked {
        // Push USDC to Aave by doing oneForZero swap (small input → hook gets claims)
        swap(testPoolKey, false, -1000e6, ""); // 1000 USDC → ~998 DAI

        uint256 aUsdcAfter = IERC20(A_USDC).balanceOf(address(hook));
        console2.log("aUSDC after rebalance:", aUsdcAfter);
        assertTrue(aUsdcAfter > 0, "USDC should be in Aave");
        assertEq(IERC20(USDC).balanceOf(address(hook)), 0, "All USDC ERC-20 in Aave");

        // Now zeroForOne (DAI → USDC): output must EXCEED the 1000 USDC in claims
        // to force an Aave withdrawal. 2000 DAI → ~1998 USDC output > 1000 claims.
        uint256 aUsdcBefore = IERC20(A_USDC).balanceOf(address(hook));
        swap(testPoolKey, true, -2000e18, ""); // 2000 DAI → ~1998 USDC

        uint256 aUsdcRemaining = IERC20(A_USDC).balanceOf(address(hook));
        console2.log("aUSDC before JIT:", aUsdcBefore);
        console2.log("aUSDC after JIT:", aUsdcRemaining);
        assertTrue(aUsdcRemaining < aUsdcBefore, "Should have withdrawn USDC from Aave");
    }

    // ──── Test: Yield accrual ────

    function test_fork_yieldAccrual_realAave() public onlyForked {
        // Push DAI to Aave
        swap(testPoolKey, true, -1000e18, "");

        uint256 aDaiBefore = IERC20(A_DAI).balanceOf(address(hook));
        assertTrue(aDaiBefore > 0, "Should have aDAI");

        uint256 invBefore = hook.totalInventory(currencyDAI);

        // Advance 30 days for yield accrual
        vm.warp(block.timestamp + 30 days);
        vm.roll(block.number + 1);

        uint256 aDaiAfter = IERC20(A_DAI).balanceOf(address(hook));
        uint256 invAfter = hook.totalInventory(currencyDAI);

        console2.log("aDAI before yield:", aDaiBefore);
        console2.log("aDAI after 30 days:", aDaiAfter);
        console2.log("Yield earned:", aDaiAfter - aDaiBefore);
        console2.log("Total inventory before:", invBefore);
        console2.log("Total inventory after:", invAfter);

        assertTrue(aDaiAfter > aDaiBefore, "aDAI should increase over time");
        assertTrue(invAfter > invBefore, "Total inventory should increase from yield");
    }

    // ──── Test: Full deposit → swap → reverse → withdraw cycle ────

    function test_fork_fullCycle() public onlyForked {
        // 1. After deposit: all ERC-20 on hook
        assertEq(IERC20(DAI).balanceOf(address(hook)), 100_000e18);
        assertEq(IERC20(USDC).balanceOf(address(hook)), 100_000e6);

        // 2. zeroForOne: DAI → USDC (pushes DAI to Aave)
        swap(testPoolKey, true, -5000e18, ""); // 5000 DAI → ~4995 USDC

        assertTrue(IERC20(A_DAI).balanceOf(address(hook)) > 0, "DAI in Aave after swap");
        assertEq(IERC20(DAI).balanceOf(address(hook)), 0, "No DAI ERC-20 at 100% util");

        // 3. oneForZero: USDC → DAI (JIT withdraw DAI from Aave to output)
        swap(testPoolKey, false, -1000e6, ""); // 1000 USDC → ~998 DAI

        // 4. Owner withdraws remaining inventory
        uint256 totalDai = hook.totalInventory(currencyDAI);
        uint256 totalUsdc = hook.totalInventory(currencyUSDC);
        console2.log("Total DAI inventory:", totalDai);
        console2.log("Total USDC inventory:", totalUsdc);
        assertTrue(totalDai > 0, "DAI inventory should remain");
        assertTrue(totalUsdc > 0, "USDC inventory should remain");

        // Withdraw DAI (from Aave + claims)
        uint256 ownerDaiBefore = IERC20(DAI).balanceOf(owner);
        uint256 hookDaiErc20 = IERC20(DAI).balanceOf(address(hook));
        uint256 hookADai = IERC20(A_DAI).balanceOf(address(hook));
        vm.prank(owner);
        hook.withdraw(currencyDAI, hookDaiErc20 + hookADai);
        assertTrue(IERC20(DAI).balanceOf(owner) > ownerDaiBefore, "Owner received DAI");
    }

    // ──── Test: Gas profiling at 100% utilization ────

    function test_fork_gasProfile_jitSwap() public onlyForked {
        // Push USDC to Aave first
        swap(testPoolKey, false, -1000e6, ""); // triggers USDC → Aave

        // JIT swap: must withdraw USDC from Aave for output
        uint256 gasBefore = gasleft();
        swap(testPoolKey, true, -100e18, ""); // DAI → USDC (JIT withdraw)
        uint256 gasUsed = gasBefore - gasleft();
        console2.log("Gas used for JIT swap (100% util):", gasUsed);
    }

    function test_fork_gasProfile_noAaveNeeded() public onlyForked {
        // Swap without touching Aave (USDC still as ERC-20)
        uint256 gasBefore = gasleft();
        swap(testPoolKey, true, -100e18, ""); // DAI → USDC (USDC available)
        uint256 gasUsed = gasBefore - gasleft();
        console2.log("Gas used for swap (no Aave needed):", gasUsed);
    }

    // ──── Test: aToken balance reflects real Aave ────

    function test_fork_aTokenBalanceReflectsRealAave() public onlyForked {
        // Push DAI to Aave
        swap(testPoolKey, true, -1000e18, "");

        uint256 hookADai = IERC20(A_DAI).balanceOf(address(hook));
        assertTrue(hookADai > 0, "Hook should hold real aDAI");

        uint256 hookDaiErc20 = IERC20(DAI).balanceOf(address(hook));
        uint256 hookClaims = hook.claimBalance(currencyDAI);

        console2.log("Hook aDAI:", hookADai);
        console2.log("Hook DAI ERC-20:", hookDaiErc20);
        console2.log("Hook DAI claims:", hookClaims);
        console2.log("Total inventory:", hook.totalInventory(currencyDAI));

        // DAI inventory = 100_000e18 (deposited) + 1000e18 (swap input claims)
        assertApproxEqAbs(hook.totalInventory(currencyDAI), 101_000e18, 1e18);
    }

    // ──── Test: Multiple swaps stress test ────

    function test_fork_multipleSwaps_100pctUtil() public onlyForked {
        for (uint256 i = 0; i < 5; i++) {
            swap(testPoolKey, true, -500e18, ""); // DAI → USDC
            swap(testPoolKey, false, -500e6, ""); // USDC → DAI
        }

        uint256 daiInv = hook.totalInventory(currencyDAI);
        uint256 usdcInv = hook.totalInventory(currencyUSDC);
        console2.log("DAI inventory after 10 swaps:", daiInv);
        console2.log("USDC inventory after 10 swaps:", usdcInv);
        assertTrue(daiInv > 0, "DAI inventory should remain");
        assertTrue(usdcInv > 0, "USDC inventory should remain");
    }
}
