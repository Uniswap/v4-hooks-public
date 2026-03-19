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
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";
import {DeployPermit2} from "permit2/test/utils/DeployPermit2.sol";
import {Permit2JITQuoterHook} from "../../src/alf/Permit2JITQuoterHook.sol";
import {AttestationRegistry} from "../../src/alf/AttestationRegistry.sol";
import {IAttestationRegistry} from "../../src/alf/interfaces/IAttestationRegistry.sol";

contract Permit2JITQuoterHookTest is Test, Deployers {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;
    using StateLibrary for IPoolManager;

    AttestationRegistry public attestationRegistry;
    Permit2JITQuoterHook public hook;
    IAllowanceTransfer public permit2;

    address owner = makeAddr("owner");
    address maker = makeAddr("maker");

    PoolKey testPoolKey;

    uint24 constant BID_FEE_PIPS = 20_000; // 2%
    uint24 constant ASK_FEE_PIPS = 50_000; // 5%
    int24 constant TICK_WIDTH = 120;
    uint128 constant JIT_LIQUIDITY = 100_000e18;

    function setUp() public {
        deployFreshManagerAndRouters();
        deployMintAndApprove2Currencies();

        // Deploy Permit2 via etch
        DeployPermit2 deployer = new DeployPermit2();
        permit2 = IAllowanceTransfer(deployer.deployPermit2());

        attestationRegistry = new AttestationRegistry(owner);

        // Deploy hook at flag-mined address
        uint160 flags = uint160(Hooks.AFTER_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG);
        hook = Permit2JITQuoterHook(address(uint160(uint256(type(uint160).max) & clearAllHookPermissionsMask | flags)));
        deployCodeTo(
            "Permit2JITQuoterHook",
            abi.encode(manager, address(attestationRegistry), address(permit2), uint32(50_000), owner),
            address(hook)
        );

        // Create pool key (dynamic fee for fee override)
        testPoolKey = PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: 60,
            hooks: IHooks(address(hook))
        });

        // Initialize pool
        manager.initialize(testPoolKey, Constants.SQRT_PRICE_1_1);

        // Seed PoolManager with ERC-20 float so PM balance check passes.
        // In production, PM holds reserves across all pools. Here we simulate that.
        MockERC20(Currency.unwrap(currency0)).transfer(address(manager), 10_000e18);
        MockERC20(Currency.unwrap(currency1)).transfer(address(manager), 10_000e18);

        // Fund maker with tokens
        MockERC20(Currency.unwrap(currency0)).transfer(maker, 100_000e18);
        MockERC20(Currency.unwrap(currency1)).transfer(maker, 100_000e18);

        // Maker approves Permit2 for both tokens
        vm.startPrank(maker);
        MockERC20(Currency.unwrap(currency0)).approve(address(permit2), type(uint256).max);
        MockERC20(Currency.unwrap(currency1)).approve(address(permit2), type(uint256).max);
        // Maker grants Permit2 allowance to hook
        permit2.approve(Currency.unwrap(currency0), address(hook), type(uint160).max, type(uint48).max);
        permit2.approve(Currency.unwrap(currency1), address(hook), type(uint160).max, type(uint48).max);
        vm.stopPrank();

        // Set JIT config
        vm.prank(owner);
        hook.updateJITConfig(
            testPoolKey,
            Permit2JITQuoterHook.JITConfig({
                maker: maker,
                bidCoefficient: 0.98e18,
                askCoefficient: 0.95e18,
                bidFeePips: BID_FEE_PIPS,
                askFeePips: ASK_FEE_PIPS,
                tickWidth: TICK_WIDTH,
                liquidity: JIT_LIQUIDITY,
                attestedDiscountBps: 0,
                live: true
            })
        );
    }

    // ──── afterInitialize ────

    // (registry test removed — ALFQuoterRegistry no longer exists)

    // ──── getIndicativeQuote ────

    function test_getIndicativeQuote_zeroForOne() public view {
        uint256 output = hook.getIndicativeQuote(testPoolKey, true, -100e18, "");
        assertEq(output, 98e18); // 100 * 0.98
    }

    function test_getIndicativeQuote_oneForZero() public view {
        uint256 output = hook.getIndicativeQuote(testPoolKey, false, -100e18, "");
        assertEq(output, 95e18); // 100 * 0.95
    }

    function test_getIndicativeQuote_unlivePool_returnsZero() public {
        vm.prank(owner);
        hook.setPoolLive(testPoolKey, false);

        uint256 output = hook.getIndicativeQuote(testPoolKey, true, -100e18, "");
        assertEq(output, 0);
    }

    // ──── Full swap lifecycle: JIT LP add → swap → JIT LP remove ────

    function test_fullSwap_zeroForOne() public {
        uint256 makerErc20_0Before = MockERC20(Currency.unwrap(currency0)).balanceOf(maker);
        uint256 makerErc20_1Before = MockERC20(Currency.unwrap(currency1)).balanceOf(maker);

        BalanceDelta delta = swap(testPoolKey, true, -1e18, "");

        assertEq(delta.amount0(), -1e18);
        int128 output = delta.amount1();
        assertTrue(output > 0);
        // With 2% fee at ~1:1 price, expect ~0.98e18 output
        assertApproxEqRel(uint256(int256(output)), 0.98e18, 0.01e18);

        uint256 makerErc20_0After = MockERC20(Currency.unwrap(currency0)).balanceOf(maker);
        uint256 makerErc20_1After = MockERC20(Currency.unwrap(currency1)).balanceOf(maker);

        // Maker gained input token as ERC-20 (LP earned from swap)
        assertTrue(makerErc20_0After > makerErc20_0Before);
        // Maker lost output token (paid to swapper via LP)
        assertTrue(makerErc20_1After < makerErc20_1Before);

        // Maker has ZERO claims — pure ERC-20 settlement
        assertEq(manager.balanceOf(maker, currency0.toId()), 0);
        assertEq(manager.balanceOf(maker, currency1.toId()), 0);

        // Hook also has ZERO claims — stateless
        assertEq(manager.balanceOf(address(hook), currency0.toId()), 0);
        assertEq(manager.balanceOf(address(hook), currency1.toId()), 0);
    }

    function test_fullSwap_oneForZero() public {
        uint256 makerErc20_0Before = MockERC20(Currency.unwrap(currency0)).balanceOf(maker);
        uint256 makerErc20_1Before = MockERC20(Currency.unwrap(currency1)).balanceOf(maker);

        BalanceDelta delta = swap(testPoolKey, false, -1e18, "");

        assertEq(delta.amount1(), -1e18);
        int128 output = delta.amount0();
        assertTrue(output > 0);
        // With 5% fee at ~1:1 price, expect ~0.95e18 output
        assertApproxEqRel(uint256(int256(output)), 0.95e18, 0.01e18);

        uint256 makerErc20_0After = MockERC20(Currency.unwrap(currency0)).balanceOf(maker);
        uint256 makerErc20_1After = MockERC20(Currency.unwrap(currency1)).balanceOf(maker);

        // Maker lost output token (paid to swapper via LP)
        assertTrue(makerErc20_0After < makerErc20_0Before);
        // Maker gained input token as ERC-20 (LP earned from swap)
        assertTrue(makerErc20_1After > makerErc20_1Before);

        // Maker has ZERO claims — pure ERC-20 settlement
        assertEq(manager.balanceOf(maker, currency0.toId()), 0);
        assertEq(manager.balanceOf(maker, currency1.toId()), 0);

        // Hook also has ZERO claims — stateless
        assertEq(manager.balanceOf(address(hook), currency0.toId()), 0);
        assertEq(manager.balanceOf(address(hook), currency1.toId()), 0);
    }

    // ──── PM balance check: refuse to quote when insufficient float ────

    function test_refusesToQuote_insufficientPMFloat() public {
        // Drain PM's ERC-20 float so the balance check fails
        deal(Currency.unwrap(currency0), address(manager), 0);

        // Pool has no liquidity and PM has no float — swap returns zero
        BalanceDelta delta = swap(testPoolKey, true, -1e18, "");
        assertEq(delta.amount0(), int128(0));
        assertEq(delta.amount1(), int128(0));

        // Maker balances unchanged (hook refused to provide JIT LP)
        assertEq(manager.balanceOf(maker, currency0.toId()), 0);
        assertEq(manager.balanceOf(maker, currency1.toId()), 0);
    }

    // ──── Consecutive swaps: hook is stateless between transactions ────

    function test_consecutiveSwaps_stateless() public {
        // First swap
        swap(testPoolKey, true, -1e18, "");

        // Verify no lingering claims
        assertEq(manager.balanceOf(address(hook), currency0.toId()), 0);
        assertEq(manager.balanceOf(address(hook), currency1.toId()), 0);

        // Second swap works identically (no state leakage)
        uint256 makerErc20_0Before = MockERC20(Currency.unwrap(currency0)).balanceOf(maker);
        uint256 makerErc20_1Before = MockERC20(Currency.unwrap(currency1)).balanceOf(maker);

        swap(testPoolKey, true, -1e18, "");

        uint256 makerErc20_0After = MockERC20(Currency.unwrap(currency0)).balanceOf(maker);
        uint256 makerErc20_1After = MockERC20(Currency.unwrap(currency1)).balanceOf(maker);

        // Same pattern: gained input, lost output
        assertTrue(makerErc20_0After > makerErc20_0Before);
        assertTrue(makerErc20_1After < makerErc20_1Before);

        // Still zero claims
        assertEq(manager.balanceOf(maker, currency0.toId()), 0);
        assertEq(manager.balanceOf(maker, currency1.toId()), 0);
        assertEq(manager.balanceOf(address(hook), currency0.toId()), 0);
        assertEq(manager.balanceOf(address(hook), currency1.toId()), 0);
    }

    // ──── JIT LP is fully removed after swap ────

    function test_afterSwap_removesJITLP() public {
        // Pool starts with no liquidity
        uint128 liquidityBefore = manager.getLiquidity(testPoolKey.toId());
        assertEq(liquidityBefore, 0);

        // Swap triggers JIT LP add/remove
        swap(testPoolKey, true, -1e18, "");

        // Pool should have no remaining liquidity after swap
        uint128 liquidityAfter = manager.getLiquidity(testPoolKey.toId());
        assertEq(liquidityAfter, 0);
    }

    // ──── Unlive pool ────

    function test_unlivePool_noJIT() public {
        vm.prank(owner);
        hook.setPoolLive(testPoolKey, false);

        // Without JIT LP, the pool has no liquidity → swap returns zero delta
        BalanceDelta delta = swap(testPoolKey, true, -1e18, "");
        assertEq(delta.amount0(), int128(0));
        assertEq(delta.amount1(), int128(0));
    }

    // ──── Fee override applied ────

    function test_feeOverride_applied() public {
        // With BID_FEE_PIPS = 20_000 (2%), output for 1e18 input should be ~0.98
        BalanceDelta delta1 = swap(testPoolKey, true, -1e18, "");
        uint256 output1 = uint256(int256(delta1.amount1()));

        // Change to 0% fee
        vm.prank(owner);
        hook.updateJITConfig(
            testPoolKey,
            Permit2JITQuoterHook.JITConfig({
                maker: maker,
                bidCoefficient: 1e18,
                askCoefficient: 1e18,
                bidFeePips: 0,
                askFeePips: 0,
                tickWidth: TICK_WIDTH,
                liquidity: JIT_LIQUIDITY,
                attestedDiscountBps: 0,
                live: true
            })
        );

        BalanceDelta delta2 = swap(testPoolKey, true, -1e18, "");
        uint256 output2 = uint256(int256(delta2.amount1()));

        // 0% fee should give more output than 2% fee
        assertTrue(output2 > output1);
    }

    // ──── Owner functions ────

    function test_updateJITConfig_onlyOwner() public {
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, address(this)));
        hook.updateJITConfig(
            testPoolKey,
            Permit2JITQuoterHook.JITConfig({
                maker: maker,
                bidCoefficient: 1e18,
                askCoefficient: 1e18,
                bidFeePips: 0,
                askFeePips: 0,
                tickWidth: 60,
                liquidity: 1e18,
                attestedDiscountBps: 0,
                live: true
            })
        );
    }

    function test_setPoolLive_toggles() public {
        vm.prank(owner);
        hook.setPoolLive(testPoolKey, false);

        vm.prank(owner);
        hook.setPoolLive(testPoolKey, true);
    }

    function test_setPoolLive_onlyOwner() public {
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, address(this)));
        hook.setPoolLive(testPoolKey, false);
    }
}
