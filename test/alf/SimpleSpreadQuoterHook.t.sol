// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {LiquidityAmounts} from "@uniswap/v4-core/test/utils/LiquidityAmounts.sol";
import {Constants} from "@uniswap/v4-core/test/utils/Constants.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {SimpleSpreadQuoterHook} from "../../src/alf/SimpleSpreadQuoterHook.sol";
import {SpreadQuoterBase} from "../../src/alf/base/SpreadQuoterBase.sol";

contract SimpleSpreadQuoterHookTest is Test, Deployers {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    SimpleSpreadQuoterHook public hook;

    address owner = makeAddr("owner");

    PoolKey testPoolKey;

    // Fee pips for tests: 20_000 pips = 2%
    uint24 constant FEE_PIPS = 20_000;

    function setUp() public {
        deployFreshManagerAndRouters();
        deployMintAndApprove2Currencies();

        // Deploy hook at flag-mined address
        uint160 flags = uint160(
            Hooks.BEFORE_INITIALIZE_FLAG | Hooks.AFTER_INITIALIZE_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG
                | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG | Hooks.BEFORE_SWAP_FLAG
        );
        hook =
            SimpleSpreadQuoterHook(address(uint160(uint256(type(uint160).max) & clearAllHookPermissionsMask | flags)));
        deployCodeTo("SimpleSpreadQuoterHook", abi.encode(manager, uint32(50_000), owner), address(hook));

        // Create pool key with static fee (`PoolKey.fee`)
        testPoolKey = PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: FEE_PIPS,
            tickSpacing: 60,
            hooks: IHooks(address(hook))
        });

        // Initialize pool at tick 30 via owner-only `initializePool` — direct
        // `manager.initialize` is now blocked.
        vm.prank(owner);
        hook.initializePool(testPoolKey, TickMath.getSqrtPriceAtTick(30));

        // Authorize the modifyLiquidityRouter for LP operations
        vm.prank(owner);
        hook.setAuthorizedLP(address(modifyLiquidityRouter), true);

        // Add LP at the active tick (single-tick concentration)
        _seedAtActiveTick(testPoolKey, 10_000e18, 10_000e18);

        // Activate the pool for swaps (defaults to paused after manager.initialize)
        vm.prank(owner);
        hook.setPoolLive(testPoolKey, true);
    }

    // ──── Helpers ────

    function _seedAtActiveTick(PoolKey memory key_, uint256 amount0, uint256 amount1) internal {
        int24 activeTick = hook.activeLowerTick(key_.toId());
        (uint160 sqrtPriceX96,,,) = manager.getSlot0(key_.toId());
        uint128 liq = LiquidityAmounts.getLiquidityForAmounts(
            sqrtPriceX96,
            TickMath.getSqrtPriceAtTick(activeTick),
            TickMath.getSqrtPriceAtTick(activeTick + key_.tickSpacing),
            amount0,
            amount1
        );
        modifyLiquidityRouter.modifyLiquidity(
            key_,
            ModifyLiquidityParams({
                tickLower: activeTick, tickUpper: activeTick + key_.tickSpacing, liquidityDelta: int128(liq), salt: 0
            }),
            ""
        );
    }

    // ──── afterInitialize ────

    function test_afterInitialize_setsActiveLowerTick() public view {
        // Init tick 30, tickSpacing 60 → floor(30/60)*60 = 0 → activeLowerTick = 0
        assertEq(hook.activeLowerTick(testPoolKey.toId()), int24(0));
    }

    // ──── M-05 regression: init gating ────

    /// @dev Direct `manager.initialize` on a SpreadQuoter pool MUST revert. Without the
    ///      `_beforeInitialize` gate, an attacker could front-run an operator-planned launch
    ///      and pin the pool's `sqrtPriceX96` (immutable for the pool's lifetime) to a
    ///      price the operator did not choose.
    function test_directInitialize_reverts() public {
        PoolKey memory unowned = PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: FEE_PIPS,
            tickSpacing: 30,
            hooks: IHooks(address(hook))
        });
        vm.expectRevert();
        manager.initialize(unowned, TickMath.getSqrtPriceAtTick(0));
    }

    /// @dev `initializePool` is `onlyOwner` — non-owners cannot bypass the gate via the
    ///      hook's own entry point either.
    function test_initializePool_onlyOwner() public {
        PoolKey memory unowned = PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: FEE_PIPS,
            tickSpacing: 30,
            hooks: IHooks(address(hook))
        });
        vm.expectRevert();
        hook.initializePool(unowned, TickMath.getSqrtPriceAtTick(0));
    }

    // ──── LP authorization ────

    function test_addLiquidity_unauthorized_reverts() public {
        int24 activeTick = hook.activeLowerTick(testPoolKey.toId());

        // Revoke the router's authorization
        vm.prank(owner);
        hook.setAuthorizedLP(address(modifyLiquidityRouter), false);

        vm.expectRevert();
        modifyLiquidityRouter.modifyLiquidity(
            testPoolKey,
            ModifyLiquidityParams({
                tickLower: activeTick,
                tickUpper: activeTick + testPoolKey.tickSpacing,
                liquidityDelta: 1e18,
                salt: bytes32(uint256(1))
            }),
            ""
        );
    }

    function test_removeLiquidity_unauthorized_reverts() public {
        int24 activeTick = hook.activeLowerTick(testPoolKey.toId());

        // Revoke the router's authorization
        vm.prank(owner);
        hook.setAuthorizedLP(address(modifyLiquidityRouter), false);

        vm.expectRevert();
        modifyLiquidityRouter.modifyLiquidity(
            testPoolKey,
            ModifyLiquidityParams({
                tickLower: activeTick, tickUpper: activeTick + testPoolKey.tickSpacing, liquidityDelta: -1e18, salt: 0
            }),
            ""
        );
    }

    function test_setAuthorizedLP_onlyOwner() public {
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, address(this)));
        hook.setAuthorizedLP(makeAddr("someone"), true);
    }

    function test_setAuthorizedLP_grantsAndRevokes() public {
        address lp = makeAddr("lp");

        vm.prank(owner);
        hook.setAuthorizedLP(lp, true);
        assertTrue(hook.authorizedLPs(lp));

        vm.prank(owner);
        hook.setAuthorizedLP(lp, false);
        assertFalse(hook.authorizedLPs(lp));
    }

    // ──── Tick enforcement ────

    function test_addLiquidity_wrongTickRange_reverts() public {
        // Try adding with a range wider than one tick spacing
        vm.expectRevert();
        modifyLiquidityRouter.modifyLiquidity(
            testPoolKey,
            ModifyLiquidityParams({tickLower: -120, tickUpper: 120, liquidityDelta: 1e18, salt: bytes32(uint256(1))}),
            ""
        );
    }

    function test_addLiquidity_wrongActiveTick_reverts() public {
        int24 activeTick = hook.activeLowerTick(testPoolKey.toId());

        // Correct width but wrong starting tick
        vm.expectRevert();
        modifyLiquidityRouter.modifyLiquidity(
            testPoolKey,
            ModifyLiquidityParams({
                tickLower: activeTick + testPoolKey.tickSpacing,
                tickUpper: activeTick + 2 * testPoolKey.tickSpacing,
                liquidityDelta: 1e18,
                salt: bytes32(uint256(1))
            }),
            ""
        );
    }

    function test_setActiveTick_updatesAndEmits() public {
        int24 newTick = int24(60);
        vm.prank(owner);
        hook.setActiveTick(testPoolKey, newTick);
        assertEq(hook.activeLowerTick(testPoolKey.toId()), newTick);
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

    // ──── getIndicativeQuote (AMM simulation) ────

    function test_getIndicativeQuote_zeroForOne() public view {
        uint256 output = hook.getIndicativeQuote(testPoolKey, true, -100e18, "");
        // Simulates AMM swap with 2% fee → ~98e18 output (minimal price impact)
        assertApproxEqRel(output, 98e18, 0.01e18);
    }

    function test_getIndicativeQuote_oneForZero() public view {
        uint256 output = hook.getIndicativeQuote(testPoolKey, false, -100e18, "");
        // Simulates AMM swap with 2% fee → ~98e18 output (symmetric)
        assertApproxEqRel(output, 98e18, 0.01e18);
    }

    function test_getIndicativeQuote_unlivePool_returnsZero() public {
        vm.prank(owner);
        hook.setPoolLive(testPoolKey, false);

        uint256 output = hook.getIndicativeQuote(testPoolKey, true, -100e18, "");
        assertEq(output, 0);
    }

    function test_getIndicativeQuote_noLiquidity_returnsZero() public {
        // Create a fresh pool with no LP
        PoolKey memory emptyPoolKey = PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: FEE_PIPS,
            tickSpacing: 10,
            hooks: IHooks(address(hook))
        });
        vm.prank(owner);
        hook.initializePool(emptyPoolKey, Constants.SQRT_PRICE_1_1);

        vm.prank(owner);
        hook.setPoolLive(emptyPoolKey, true);

        // No liquidity → simulation returns 0
        uint256 output = hook.getIndicativeQuote(emptyPoolKey, true, -1e18, "");
        assertEq(output, 0);
    }

    function test_getIndicativeQuote_matchesSwapExecution() public {
        // Indicative quote should closely match actual swap output
        uint256 indicative = hook.getIndicativeQuote(testPoolKey, true, -1e18, "");

        BalanceDelta delta = swap(testPoolKey, true, -1e18, "");
        uint256 actual = uint256(int256(delta.amount1()));

        // Should be very close — same fee, same pool state
        assertEq(indicative, actual);
    }

    // ──── beforeSwap: fee override ────

    function test_beforeSwap_zeroForOne_appliesFee() public {
        // Swap 1e18 token0 → token1 with FEE_PIPS (2%)
        BalanceDelta delta = swap(testPoolKey, true, -1e18, "");

        assertEq(delta.amount0(), -1e18);
        int128 output = delta.amount1();
        assertTrue(output > 0);
        assertApproxEqRel(uint256(int256(output)), 0.98e18, 0.01e18);
    }

    function test_beforeSwap_oneForZero_appliesFee() public {
        // Swap 1e18 token1 → token0 with FEE_PIPS (2%) — symmetric
        BalanceDelta delta = swap(testPoolKey, false, -1e18, "");

        assertEq(delta.amount1(), -1e18);
        int128 output = delta.amount0();
        assertTrue(output > 0);
        assertApproxEqRel(uint256(int256(output)), 0.98e18, 0.01e18);
    }

    function test_beforeSwap_unlivePool_reverts() public {
        vm.prank(owner);
        hook.setPoolLive(testPoolKey, false);

        vm.expectRevert();
        swap(testPoolKey, true, -1e18, "");
    }

    function test_beforeSwap_exactOutput_zeroForOne() public {
        BalanceDelta delta = swap(testPoolKey, true, 0.5e18, "");

        assertEq(delta.amount1(), int128(0.5e18));
        int128 input = delta.amount0();
        assertTrue(input < 0);
        assertApproxEqRel(uint256(int256(-input)), 0.5102e18, 0.01e18);
    }

    // ──── Owner functions ────

    function test_setPoolLive_onlyOwner() public {
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, address(this)));
        hook.setPoolLive(testPoolKey, false);
    }

}
