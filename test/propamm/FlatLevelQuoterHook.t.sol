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
import {FlatLevelQuoterHook} from "../../src/propamm/FlatLevelQuoterHook.sol";
import {PropAMMIndex} from "../../src/propamm/PropAMMIndex.sol";
import {AttestationRegistry} from "../../src/propamm/AttestationRegistry.sol";
import {IPropAMMIndex, QuoterType, QuoterEntry} from "../../src/propamm/interfaces/IPropAMMIndex.sol";
import {IAttestationRegistry, Attestation} from "../../src/propamm/interfaces/IAttestationRegistry.sol";
import {MockAttestationSigner} from "./mocks/MockAttestationSigner.sol";
import {QuoterHookData} from "../../src/propamm/interfaces/IQuoterHook.sol";

contract FlatLevelQuoterHookTest is Test, Deployers {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;

    PropAMMIndex public index;
    AttestationRegistry public attestationRegistry;
    FlatLevelQuoterHook public hook;

    address owner = makeAddr("owner");
    uint256 attesterPk;
    address attester;

    PoolKey testPoolKey;

    // Coefficients: 0.98e18 bid (2% spread), 0.95e18 ask (5% spread)
    uint128 constant BID_COEFFICIENT = 0.98e18;
    uint128 constant ASK_COEFFICIENT = 0.95e18;

    function setUp() public {
        deployFreshManagerAndRouters();
        deployMintAndApprove2Currencies();

        index = new PropAMMIndex();
        attestationRegistry = new AttestationRegistry(owner);

        (attester, attesterPk) = makeAddrAndKey("attester");
        vm.prank(owner);
        attestationRegistry.addAttester(attester);

        // Deploy hook at flag-mined address
        uint160 flags = uint160(
            Hooks.AFTER_INITIALIZE_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_SWAP_FLAG
                | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG
        );
        hook = FlatLevelQuoterHook(address(uint160(uint256(type(uint160).max) & clearAllHookPermissionsMask | flags)));
        deployCodeTo(
            "FlatLevelQuoterHook",
            abi.encode(manager, address(index), address(attestationRegistry), uint32(50_000), owner),
            address(hook)
        );

        // Create pool key (no dynamic fee needed — hook uses delta override, not fee override)
        testPoolKey =
            PoolKey({currency0: currency0, currency1: currency1, fee: 0, tickSpacing: 1, hooks: IHooks(address(hook))});

        // Initialize pool (triggers afterInitialize → registers in index)
        manager.initialize(testPoolKey, Constants.SQRT_PRICE_1_1);

        // Set flat pricing state
        vm.prank(owner);
        hook.updateFlatPricingState(
            testPoolKey,
            FlatLevelQuoterHook.FlatPricingState({
                bidCoefficient: BID_COEFFICIENT, askCoefficient: ASK_COEFFICIENT, attestedDiscountBps: 5, live: true
            })
        );

        // Deposit inventory into the hook (both tokens)
        MockERC20 token0 = MockERC20(Currency.unwrap(currency0));
        MockERC20 token1 = MockERC20(Currency.unwrap(currency1));

        token0.mint(owner, 1_000e18);
        token1.mint(owner, 1_000e18);

        vm.startPrank(owner);
        token0.approve(address(hook), type(uint256).max);
        token1.approve(address(hook), type(uint256).max);
        hook.deposit(currency0, 1_000e18);
        hook.deposit(currency1, 1_000e18);
        vm.stopPrank();
    }

    // ──── afterInitialize ────

    function test_afterInitialize_registersInIndex() public view {
        assertTrue(index.isRegistered(address(hook), testPoolKey));
        QuoterEntry memory entry = index.getQuoter(address(hook), testPoolKey);
        assertEq(uint8(entry.quoterType), uint8(QuoterType.HOOKDATA));
        assertEq(entry.maxGas, 50_000);
        assertTrue(entry.isLive);
    }

    // ──── Blocks liquidity on virtual pool ────

    function test_blocksLiquidity() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                CustomRevert.WrappedError.selector,
                address(hook),
                IHooks.beforeAddLiquidity.selector,
                abi.encodeWithSelector(FlatLevelQuoterHook.LiquidityNotAllowed.selector),
                abi.encodeWithSelector(Hooks.HookCallFailed.selector)
            )
        );
        modifyLiquidityRouter.modifyLiquidity(
            testPoolKey, ModifyLiquidityParams({tickLower: -1, tickUpper: 1, liquidityDelta: 1e18, salt: 0}), ""
        );
    }

    // ──── Flat swap: exact input ────

    function test_flatSwap_exactInput_zeroForOne() public {
        BalanceDelta delta = swap(testPoolKey, true, -1e18, "");

        assertEq(delta.amount0(), -1e18); // paid 1e18 token0
        int128 output = delta.amount1();
        assertTrue(output > 0);
        // 1e18 * 0.98 = 0.98e18
        assertEq(uint256(int256(output)), 0.98e18);
    }

    function test_flatSwap_exactInput_oneForZero() public {
        BalanceDelta delta = swap(testPoolKey, false, -1e18, "");

        assertEq(delta.amount1(), -1e18); // paid 1e18 token1
        int128 output = delta.amount0();
        assertTrue(output > 0);
        // 1e18 * 0.95 = 0.95e18
        assertEq(uint256(int256(output)), 0.95e18);
    }

    // ──── Flat swap: exact output ────

    function test_flatSwap_exactOutput_zeroForOne() public {
        // Want exactly 0.98e18 token1 out
        BalanceDelta delta = swap(testPoolKey, true, 0.98e18, "");

        int128 output = delta.amount1();
        assertEq(uint256(int256(output)), 0.98e18); // got exact output

        // Input = ceil(0.98e18 * 1e18 / 0.98e18) = 1e18
        int128 input = delta.amount0();
        assertTrue(input < 0);
        assertEq(uint256(int256(-input)), 1e18);
    }

    // ──── Insufficient inventory ────

    function test_flatSwap_insufficientInventory_reverts() public {
        // Try to swap more than the hook's inventory (1000e18)
        vm.expectRevert();
        swap(testPoolKey, true, -2_000e18, "");
    }

    // ──── Deposit / Withdraw ────

    function test_deposit_withdraw() public {
        MockERC20 token0 = MockERC20(Currency.unwrap(currency0));

        uint256 hookBalBefore = token0.balanceOf(address(hook));

        // Deposit more
        token0.mint(owner, 500e18);
        vm.startPrank(owner);
        token0.approve(address(hook), 500e18);
        hook.deposit(currency0, 500e18);
        vm.stopPrank();

        assertEq(token0.balanceOf(address(hook)), hookBalBefore + 500e18);

        // Withdraw
        vm.prank(owner);
        hook.withdraw(currency0, 200e18);
        assertEq(token0.balanceOf(address(hook)), hookBalBefore + 300e18);
    }

    function test_deposit_onlyOwner() public {
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, address(this)));
        hook.deposit(currency0, 100e18);
    }

    function test_withdraw_onlyOwner() public {
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, address(this)));
        hook.withdraw(currency0, 100e18);
    }

    // ──── Indicative quotes ────

    function test_getIndicativeQuote_flat_zeroForOne() public view {
        uint256 output = hook.getIndicativeQuote(testPoolKey, true, -100e18, "");
        // 100 * 0.98 = 98
        assertEq(output, 98e18);
    }

    function test_getIndicativeQuote_flat_oneForZero() public view {
        uint256 output = hook.getIndicativeQuote(testPoolKey, false, -100e18, "");
        // 100 * 0.95 = 95
        assertEq(output, 95e18);
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
        // Base = 98e18, +5 bps → 98 * 10005 / 10000 = 98.049e18
        assertEq(output, 98.049e18);
    }

    function test_getIndicativeQuote_unlivePool_returnsZero() public {
        vm.prank(owner);
        hook.setPoolLive(testPoolKey, false);

        uint256 output = hook.getIndicativeQuote(testPoolKey, true, -100e18, "");
        assertEq(output, 0);
    }

    // ──── Owner functions ────

    function test_updateFlatPricingState_onlyOwner() public {
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, address(this)));
        hook.updateFlatPricingState(
            testPoolKey,
            FlatLevelQuoterHook.FlatPricingState({
                bidCoefficient: 1e18, askCoefficient: 1e18, attestedDiscountBps: 0, live: true
            })
        );
    }

    function test_setPoolLive_updatesIndex() public {
        vm.prank(owner);
        hook.setPoolLive(testPoolKey, false);
        assertFalse(index.getQuoter(address(hook), testPoolKey).isLive);

        vm.prank(owner);
        hook.setPoolLive(testPoolKey, true);
        assertTrue(index.getQuoter(address(hook), testPoolKey).isLive);
    }

    // ──── Unlive pool: no execution ────

    function test_beforeSwap_unlivePool_noExecution() public {
        vm.prank(owner);
        hook.setPoolLive(testPoolKey, false);

        // Pool has zero liquidity and hook returns zero delta → swap will produce zero output
        BalanceDelta delta = swap(testPoolKey, true, -1e18, "");
        // With zero liquidity and no hook delta, the swap produces nothing
        assertEq(delta.amount1(), int128(0));
    }

    // ──── Claim lifecycle: accumulation + redemption ────

    function test_claimLifecycle_accumulateAndRedeem() public {
        MockERC20 token0 = MockERC20(Currency.unwrap(currency0));

        // Before swap: no claims
        assertEq(hook.claimBalance(currency0), 0);
        assertEq(hook.claimBalance(currency1), 0);

        // Swap zeroForOne: hook receives token0 as claims, pays token1 as ERC-20
        swap(testPoolKey, true, -1e18, "");

        assertEq(hook.claimBalance(currency0), 1e18); // got 1e18 token0 claims
        assertEq(hook.claimBalance(currency1), 0);

        // Reverse swap (oneForZero): hook should burn token0 claims for output
        uint256 hookErc20Before = token0.balanceOf(address(hook));
        swap(testPoolKey, false, -1e18, "");

        // token0 claims were burned to settle the output (0.95e18)
        assertEq(hook.claimBalance(currency0), 1e18 - 0.95e18);
        // token1 received as new claims
        assertEq(hook.claimBalance(currency1), 1e18);
        // hook's ERC-20 token0 balance unchanged (claims were used, not ERC-20)
        assertEq(token0.balanceOf(address(hook)), hookErc20Before);

        // Redeem remaining token0 claims to ERC-20
        uint256 remainingClaims = hook.claimBalance(currency0);
        uint256 erc20Before = token0.balanceOf(address(hook));

        vm.prank(owner);
        hook.redeemClaims(currency0, remainingClaims);

        assertEq(hook.claimBalance(currency0), 0);
        assertEq(token0.balanceOf(address(hook)), erc20Before + remainingClaims);
    }

    function test_redeemClaims_onlyOwner() public {
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, address(this)));
        hook.redeemClaims(currency0, 1e18);
    }

    function test_withdraw_redeemsClaims_whenERC20Insufficient() public {
        MockERC20 token0 = MockERC20(Currency.unwrap(currency0));

        // Generate token0 claims via a zeroForOne swap
        swap(testPoolKey, true, -10e18, "");
        assertEq(hook.claimBalance(currency0), 10e18);

        uint256 erc20Bal = token0.balanceOf(address(hook));
        uint256 ownerBefore = token0.balanceOf(owner);

        // Withdraw more than ERC-20 balance (requires claim redemption)
        uint256 withdrawAmount = erc20Bal + 5e18;
        vm.prank(owner);
        hook.withdraw(currency0, withdrawAmount);

        assertEq(token0.balanceOf(owner), ownerBefore + withdrawAmount);
        assertEq(token0.balanceOf(address(hook)), 0);
        assertEq(hook.claimBalance(currency0), 10e18 - 5e18);
    }
}
