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
import {CustomRevert} from "@uniswap/v4-core/src/libraries/CustomRevert.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {ERC20} from "solmate/src/tokens/ERC20.sol";

import {DualPoolStableHook} from "../../src/alf/DualPoolStableHook.sol";
import {LiquidityBucket} from "../../src/alf/types/Distribution.sol";
import {
    FeeConfig,
    FeeState,
    FeeConfigUpdated,
    InvalidKAndLogK,
    InvalidOptimalFeeE6
} from "../../src/alf/types/DecayingFee.sol";
import {FeeCalculation} from "../../src/alf/libraries/FeeCalculation.sol";
import {PoolNotLive} from "../../src/alf/types/Liveness.sol";
import {MockERC4626} from "./mocks/MockERC4626.sol";

/// @title DualPoolStableHookTest
/// @notice End-to-end tests for DualPoolStableHook: the dynamic-fee integration points against
///         real pools (init gating, fee config lifecycle, fee behavior through executed swaps)
///         and the quote-vs-execution fidelity suite. The JIT/vault/share machinery is
///         byte-identical to the audited `DualPoolHook` and keeps its regression coverage there;
///         this suite exercises what the sibling changes.
contract DualPoolStableHookTest is Test, Deployers {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;
    using StateLibrary for IPoolManager;
    using BalanceDeltaLibrary for BalanceDelta;

    DualPoolStableHook public hook;

    MockERC4626 public vault0;
    MockERC4626 public vault1;

    address owner = makeAddr("owner");
    address alice = makeAddr("alice");

    PoolKey testPoolKey;
    PoolId testPoolId;

    MockERC20 token0;
    MockERC20 token1;

    uint24 constant K = 16_609_443; // 0.99 in Q24
    uint24 constant LOG_K = 9140; // -ln(0.99) >> 40
    uint24 constant OPTIMAL_FEE_E6 = 90; // 0.9 bps
    uint160 REFERENCE_SQRT_PRICE_X96;

    uint256 constant POOL_SIZE = 10_000 ether;

    /// @dev Same tolerance the DualPoolHook suite uses for compact indicative quotes.
    uint256 constant INDICATIVE_REL_TOLERANCE = 5e14; // 5 bps

    function setUp() public {
        deployFreshManagerAndRouters();
        deployMintAndApprove2Currencies();

        token0 = MockERC20(Currency.unwrap(currency0));
        token1 = MockERC20(Currency.unwrap(currency1));

        vault0 = new MockERC4626(ERC20(address(token0)));
        vault1 = new MockERC4626(ERC20(address(token1)));

        REFERENCE_SQRT_PRICE_X96 = TickMath.getSqrtPriceAtTick(0);

        // Deploy hook at flag-mined address (same flags as DualPoolHook: the fee override needs
        // no additional address flag).
        uint160 flags = uint160(
            Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG
                | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG
        );
        hook = DualPoolStableHook(address(uint160(uint256(type(uint160).max) & clearAllHookPermissionsMask | flags)));
        deployCodeTo("DualPoolStableHook", abi.encode(manager, uint32(150_000), owner, type(uint64).max), address(hook));

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

    function _defaultFeeConfig() internal view returns (FeeConfig memory) {
        return FeeConfig({
            k: K,
            logK: LOG_K,
            optimalFeeE6: OPTIMAL_FEE_E6,
            targetMultiplier: 50,
            referenceSqrtPriceX96: REFERENCE_SQRT_PRICE_X96
        });
    }

    function _defaultConfig() internal view returns (DualPoolStableHook.PoolConfig memory) {
        LiquidityBucket[] memory dist = new LiquidityBucket[](1);
        dist[0] = LiquidityBucket({tickLower: -10, tickUpper: 10, weightBps: 10_000});
        return DualPoolStableHook.PoolConfig({
            sqrtPriceX96: TickMath.getSqrtPriceAtTick(0),
            distribution: dist,
            feeConfig: _defaultFeeConfig(),
            allowExternalDeposits: false,
            vault0: IERC4626(address(vault0)),
            vault1: IERC4626(address(vault1)),
            minDepositBlocks: 0
        });
    }

    /// @dev Bootstrap the test pool with `amount` of each token as the owner and advance a block.
    function _bootstrap(uint256 amount) internal {
        token0.mint(owner, amount);
        token1.mint(owner, amount);
        vm.startPrank(owner);
        token0.approve(address(hook), amount);
        token1.approve(address(hook), amount);
        hook.bootstrap(testPoolKey, amount, amount);
        vm.stopPrank();
        vm.roll(block.number + 1);
    }

    /// @dev Push the pool price outside the optimal range (which is only ±0.9bps wide) with a
    ///      large swap, advance a block, and assert the price actually left the range.
    /// @param up True to push the price above the reference (zeroForOne = false swap).
    function _pushPriceOutsideRange(bool up) internal {
        swap(testPoolKey, !up, -int256(2_000 ether), ZERO_BYTES);
        vm.roll(block.number + 1);

        (uint160 sqrtP,,,) = manager.getSlot0(testPoolId);
        uint256 ratio = FeeCalculation.calculatePriceRatioX96(sqrtP, REFERENCE_SQRT_PRICE_X96);
        assertGt(
            FeeCalculation.calculateCloseBoundaryFee(ratio, OPTIMAL_FEE_E6), 0, "price should be outside optimal range"
        );
        if (up) {
            assertGt(sqrtP, REFERENCE_SQRT_PRICE_X96, "price should be above reference");
        } else {
            assertLt(sqrtP, REFERENCE_SQRT_PRICE_X96, "price should be below reference");
        }
    }

    /// @dev Output received by the swapper from a `swap()` BalanceDelta.
    function _received(BalanceDelta delta, bool zeroForOne) internal pure returns (uint256) {
        return uint256(int256(zeroForOne ? delta.amount1() : delta.amount0()));
    }

    /// @dev Input paid by the swapper from a `swap()` BalanceDelta.
    function _paid(BalanceDelta delta, bool zeroForOne) internal pure returns (uint256) {
        return uint256(-int256(zeroForOne ? delta.amount0() : delta.amount1()));
    }

    // ═══════════════════════════════════════════════════════════════════════════
    //                        INIT GATING & FEE CONFIG LIFECYCLE
    // ═══════════════════════════════════════════════════════════════════════════

    /// @dev The inverse of DualPoolHook's gate: a static `key.fee` is rejected because the fee
    ///      override would be silently ignored by v4 on a non-dynamic pool.
    function test_initializePool_revertsWithStaticFee() public {
        PoolKey memory key = PoolKey({
            currency0: currency0, currency1: currency1, fee: 1_000, tickSpacing: 60, hooks: IHooks(address(hook))
        });

        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(DualPoolStableHook.MustUseDynamicFee.selector, 1_000));
        hook.initializePool(key, _defaultConfig());
    }

    /// @dev Fee config validation runs inside `initializePool`: the capability's errors bubble.
    function test_initializePool_revertsWithInvalidFeeConfig() public {
        PoolKey memory key = PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: 60,
            hooks: IHooks(address(hook))
        });
        DualPoolStableHook.PoolConfig memory config = _defaultConfig();
        // Align the distribution to this key's tickSpacing so the fee config is the only
        // invalid input (Distribution.set validates before the fee engine runs).
        config.distribution[0] = LiquidityBucket({tickLower: -60, tickUpper: 60, weightBps: 10_000});
        config.feeConfig.logK = LOG_K + 1;

        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(InvalidKAndLogK.selector, K, LOG_K + 1));
        hook.initializePool(key, config);
    }

    function test_initializePool_setsFeeConfigAndResetsState() public view {
        FeeConfig memory stored = hook.feeConfig(testPoolId);
        assertEq(stored.k, K);
        assertEq(stored.logK, LOG_K);
        assertEq(stored.optimalFeeE6, OPTIMAL_FEE_E6);
        assertEq(stored.targetMultiplier, 50);
        assertEq(stored.referenceSqrtPriceX96, REFERENCE_SQRT_PRICE_X96);

        FeeState memory state = hook.feeState(testPoolId);
        assertEq(state.decayingFeeE12, FeeCalculation.UNDEFINED_DECAYING_FEE_E12);
        assertEq(state.sqrtAmmPriceX96, 0);
    }

    function test_updateFeeConfig_revertsForNonOwner() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        hook.updateFeeConfig(testPoolKey, _defaultFeeConfig());
    }

    function test_updateFeeConfig_revertsWithInvalidConfig() public {
        FeeConfig memory config = _defaultFeeConfig();
        config.optimalFeeE6 = 1e4 + 1;

        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(InvalidOptimalFeeE6.selector, 1e4 + 1));
        hook.updateFeeConfig(testPoolKey, config);
    }

    /// @dev A config write after real swap history resets the fee state atomically, so nothing
    ///      computed under the old parameters leaks into the new schedule.
    function test_updateFeeConfig_succeeds_emitsAndResetsState() public {
        _bootstrap(POOL_SIZE);
        swap(testPoolKey, true, -int256(100 ether), ZERO_BYTES);

        FeeState memory state = hook.feeState(testPoolId);
        assertTrue(state.sqrtAmmPriceX96 != 0, "swap should checkpoint the fee state");

        FeeConfig memory config = _defaultFeeConfig();
        config.targetMultiplier = 100;

        vm.expectEmit(true, false, false, true);
        emit FeeConfigUpdated(testPoolId, config);
        vm.prank(owner);
        hook.updateFeeConfig(testPoolKey, config);

        assertEq(hook.feeConfig(testPoolId).targetMultiplier, 100);
        state = hook.feeState(testPoolId);
        assertEq(state.decayingFeeE12, FeeCalculation.UNDEFINED_DECAYING_FEE_E12);
        assertEq(state.sqrtAmmPriceX96, 0);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    //                        FEE BEHAVIOR THROUGH REAL SWAPS
    // ═══════════════════════════════════════════════════════════════════════════

    /// @dev At the reference price both directions pay exactly the optimal fee.
    function test_currentFee_atReference_isOptimalFee() public {
        _bootstrap(POOL_SIZE);

        assertEq(hook.currentFee(testPoolKey, true), OPTIMAL_FEE_E6);
        assertEq(hook.currentFee(testPoolKey, false), OPTIMAL_FEE_E6);
    }

    /// @dev A swap checkpoints the fee state: inside the optimal range the stored decaying fee is
    ///      the UNDEFINED sentinel and the start-of-block price is cached.
    function test_swap_checkpointsFeeState() public {
        _bootstrap(POOL_SIZE);

        swap(testPoolKey, true, -int256(10 ether), ZERO_BYTES);

        FeeState memory state = hook.feeState(testPoolId);
        assertEq(state.decayingFeeE12, FeeCalculation.UNDEFINED_DECAYING_FEE_E12, "inside range stores the sentinel");
        assertEq(state.sqrtAmmPriceX96, REFERENCE_SQRT_PRICE_X96, "caches the start-of-block price");
        assertEq(state.blockNumber, block.number);
    }

    /// @dev Outside the optimal range, flow pushing the price further from the reference is free
    ///      and flow restoring the peg pays the decaying fee.
    function test_currentFee_outsideRange_directionalZeroFee() public {
        _bootstrap(POOL_SIZE);
        _pushPriceOutsideRange(true); // price above reference

        // zeroForOne = false pushes the price further up: free
        assertEq(hook.currentFee(testPoolKey, false), 0);
        // zeroForOne = true restores the peg: decaying fee, at least the far-boundary floor of
        // ~2 * optimalFee minus one block of decay
        assertGt(hook.currentFee(testPoolKey, true), OPTIMAL_FEE_E6);
    }

    /// @dev Mirror case below the reference.
    function test_currentFee_outsideRange_belowReference() public {
        _bootstrap(POOL_SIZE);
        _pushPriceOutsideRange(false); // price below reference

        assertEq(hook.currentFee(testPoolKey, true), 0);
        assertGt(hook.currentFee(testPoolKey, false), OPTIMAL_FEE_E6);
    }

    /// @dev The decaying fee decays across blocks: the peg-restoring fee shrinks as blocks pass
    ///      with no swaps.
    function test_currentFee_decaysAcrossBlocks() public {
        _bootstrap(POOL_SIZE);
        _pushPriceOutsideRange(true);

        // Checkpoint the outside-range decaying fee
        swap(testPoolKey, false, -int256(1 ether), ZERO_BYTES);

        uint24 feeSoon = hook.currentFee(testPoolKey, true);
        vm.roll(block.number + 750);
        uint24 feeLater = hook.currentFee(testPoolKey, true);

        assertLt(feeLater, feeSoon, "fee should decay toward the target across blocks");
        assertGt(feeLater, 0);
    }

    /// @dev Same-block swaps are fee-consistent: the second swap of a block reuses the first
    ///      swap's checkpoint (the property the multiplexer's split fills rely on), and the
    ///      checkpoint is written exactly once.
    function test_swap_sameBlock_feeConsistent() public {
        _bootstrap(POOL_SIZE);
        _pushPriceOutsideRange(true);

        uint24 quotedBefore = hook.currentFee(testPoolKey, true);
        swap(testPoolKey, true, -int256(10 ether), ZERO_BYTES);
        FeeState memory state1 = hook.feeState(testPoolId);

        // Second swap in the same block: the fee preview is unchanged even though slot0 moved,
        // and the checkpoint is not rewritten.
        uint24 quotedSameBlock = hook.currentFee(testPoolKey, true);
        assertEq(quotedSameBlock, quotedBefore, "same-block fee must come from the cached checkpoint");

        swap(testPoolKey, true, -int256(10 ether), ZERO_BYTES);
        FeeState memory state2 = hook.feeState(testPoolId);
        assertEq(state1.decayingFeeE12, state2.decayingFeeE12);
        assertEq(state1.sqrtAmmPriceX96, state2.sqrtAmmPriceX96);
        assertEq(state1.blockNumber, state2.blockNumber);
    }

    function test_swap_revertsWhenPoolNotLive() public {
        _bootstrap(POOL_SIZE);

        vm.prank(owner);
        hook.setPoolLive(testPoolKey, false);

        // v4 wraps hook reverts in CustomRevert.WrappedError; assert the full envelope.
        vm.expectRevert(
            abi.encodeWithSelector(
                CustomRevert.WrappedError.selector,
                address(hook),
                IHooks.beforeSwap.selector,
                abi.encodeWithSelector(PoolNotLive.selector, testPoolId),
                abi.encodeWithSelector(Hooks.HookCallFailed.selector)
            )
        );
        swap(testPoolKey, true, -int256(1 ether), ZERO_BYTES);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    //                        QUOTE-VS-EXECUTION FIDELITY
    // ═══════════════════════════════════════════════════════════════════════════

    /// @dev Exact input at the reference price, both directions: the indicative quote (which
    ///      previews the dynamic fee) matches the executed output.
    function test_quoteFidelity_exactInput_atReference() public {
        _bootstrap(POOL_SIZE);

        uint256 amt = 100 ether;

        uint256 quote0 = hook.getIndicativeQuote(testPoolKey, true, -int256(amt), ZERO_BYTES);
        BalanceDelta delta = swap(testPoolKey, true, -int256(amt), ZERO_BYTES);
        assertApproxEqRel(_received(delta, true), quote0, INDICATIVE_REL_TOLERANCE, "zeroForOne quote fidelity");

        vm.roll(block.number + 1);
        uint256 quote1 = hook.getIndicativeQuote(testPoolKey, false, -int256(amt), ZERO_BYTES);
        delta = swap(testPoolKey, false, -int256(amt), ZERO_BYTES);
        assertApproxEqRel(_received(delta, false), quote1, INDICATIVE_REL_TOLERANCE, "oneForZero quote fidelity");
    }

    /// @dev Exact input with the price outside the optimal range: the quote must reflect the
    ///      directional fee (zero away from the peg, decaying toward it) exactly as the swap
    ///      charges it. This is the case a static-fee quote would get wrong on both sides.
    function test_quoteFidelity_exactInput_outsideRange_bothDirections() public {
        _bootstrap(POOL_SIZE);
        _pushPriceOutsideRange(true);

        uint256 amt = 50 ether;

        // Away from the peg (zero fee)
        uint256 quoteAway = hook.getIndicativeQuote(testPoolKey, false, -int256(amt), ZERO_BYTES);
        BalanceDelta delta = swap(testPoolKey, false, -int256(amt), ZERO_BYTES);
        assertApproxEqRel(_received(delta, false), quoteAway, INDICATIVE_REL_TOLERANCE, "zero-fee direction fidelity");

        // Toward the peg (decaying fee)
        vm.roll(block.number + 1);
        uint256 quoteToward = hook.getIndicativeQuote(testPoolKey, true, -int256(amt), ZERO_BYTES);
        delta = swap(testPoolKey, true, -int256(amt), ZERO_BYTES);
        assertApproxEqRel(
            _received(delta, true), quoteToward, INDICATIVE_REL_TOLERANCE, "decaying-fee direction fidelity"
        );
    }

    /// @dev Second swap of a block: the quote previews the cached (checkpointed) fee, not a
    ///      recomputed one, and matches execution.
    function test_quoteFidelity_sameBlock_secondSwap() public {
        _bootstrap(POOL_SIZE);
        _pushPriceOutsideRange(true);

        swap(testPoolKey, true, -int256(20 ether), ZERO_BYTES);

        uint256 amt = 50 ether;
        uint256 quote = hook.getIndicativeQuote(testPoolKey, true, -int256(amt), ZERO_BYTES);
        BalanceDelta delta = swap(testPoolKey, true, -int256(amt), ZERO_BYTES);
        assertApproxEqRel(_received(delta, true), quote, INDICATIVE_REL_TOLERANCE, "same-block quote fidelity");
    }

    /// @dev Exact output: the indicative returns the required input priced with the previewed
    ///      dynamic fee; execution must match.
    function test_quoteFidelity_exactOutput() public {
        _bootstrap(POOL_SIZE);

        uint256 amtOut = 50 ether;
        uint256 quotedInput = hook.getIndicativeQuote(testPoolKey, true, int256(amtOut), ZERO_BYTES);
        assertGt(quotedInput, 0, "pool should be able to honor this output");

        BalanceDelta delta = swap(testPoolKey, true, int256(amtOut), ZERO_BYTES);
        assertEq(_received(delta, true), amtOut, "exact output must be delivered");
        assertApproxEqRel(_paid(delta, true), quotedInput, INDICATIVE_REL_TOLERANCE, "exact-output input fidelity");
    }

    /// @dev Price-bounded simulation vs a price-limited execution: `swapToPrice` previews the
    ///      same dynamic fee the bounded swap is charged.
    function test_quoteFidelity_swapToPrice_bounded() public {
        _bootstrap(POOL_SIZE);

        // A limit two ticks below spot bounds the fill mid-bucket
        uint160 limit = TickMath.getSqrtPriceAtTick(-2);
        (uint256 simIn, uint256 simOut) = hook.swapToPrice(testPoolKey, true, -int256(5_000 ether), limit, ZERO_BYTES);
        assertGt(simOut, 0);

        BalanceDelta delta = swapRouter.swap(
            testPoolKey,
            SwapParams({zeroForOne: true, amountSpecified: -int256(5_000 ether), sqrtPriceLimitX96: limit}),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ZERO_BYTES
        );

        assertApproxEqRel(_received(delta, true), simOut, INDICATIVE_REL_TOLERANCE, "bounded output fidelity");
        assertApproxEqRel(_paid(delta, true), simIn, INDICATIVE_REL_TOLERANCE, "bounded input fidelity");
    }

    /// @dev The fee actually charged accrues to the pool: after a round trip, reserves must not
    ///      fall below the seed (LPs keep the swap fees) and the fee engine must have charged a
    ///      nonzero fee at the reference price.
    function test_swap_feeAccruesToPoolReserves() public {
        _bootstrap(POOL_SIZE);

        (uint256 r0Before, uint256 r1Before) = hook.getReserves(testPoolKey);

        swap(testPoolKey, true, -int256(100 ether), ZERO_BYTES);
        vm.roll(block.number + 1);
        swap(testPoolKey, false, -int256(100 ether), ZERO_BYTES);

        (uint256 r0After, uint256 r1After) = hook.getReserves(testPoolKey);
        // Fees on both legs mean the pool's aggregate holdings strictly grow over a round trip.
        assertGt(r0After + r1After, r0Before + r1Before, "swap fees should accrue to pool reserves");
    }
}
