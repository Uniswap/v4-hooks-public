// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {VolatilePairTestBase} from "./base/VolatilePairTestBase.sol";
import {VolatilePairHook} from "../../src/volatile/VolatilePairHook.sol";
import {IDynamicFeeHook} from "../../src/interfaces/IDynamicFeeHook.sol";
import {IVolatilePairHook} from "../../src/volatile/interfaces/IVolatilePairHook.sol";
import {Vm} from "forge-std/Vm.sol";
import {VolatileFeeConfig, VolatileFeeState} from "../../src/volatile/interfaces/IVolatileFeeConfiguration.sol";
import {VolatileFeeCalculation} from "../../src/volatile/libraries/VolatileFeeCalculation.sol";
import {ImmutableState} from "@uniswap/v4-periphery/src/base/ImmutableState.sol";
import {Constants} from "@uniswap/v4-core/test/utils/Constants.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";

/// `beforeSwap` / `getFee` on the base's mocked PoolManager. Exact fees only where price rounding cannot move them.
contract VolatilePairHookBeforeSwapTest is VolatilePairTestBase {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    address internal other = makeAddr("other");

    PoolKey internal otherPoolKey;
    PoolKey internal tickSpacingPoolKey;
    /// Invalid ordering in real v4, unenforced by the mock.
    PoolKey internal flippedPoolKey;

    mapping(bytes32 slot => uint160 sqrtPriceX96) internal priceBySlot;

    error UnregisteredPool(bytes32 slot);

    function setUp() public override {
        super.setUp();

        otherPoolKey = PoolKey({
            currency0: Currency.wrap(address(2)),
            currency1: Currency.wrap(address(3)),
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(address(hook))
        });

        tickSpacingPoolKey = testPoolKey;
        tickSpacingPoolKey.tickSpacing = TICK_SPACING * 2;

        flippedPoolKey = testPoolKey;
        flippedPoolKey.currency0 = testPoolKey.currency1;
        flippedPoolKey.currency1 = testPoolKey.currency0;

        // distinct pies, so a cross-pool leak shows as a wrong fee
        _initializeSecondaryPool(otherPoolKey, 1200);
        _initializeSecondaryPool(tickSpacingPoolKey, 1500);
        _initializeSecondaryPool(flippedPoolKey, 1800);
    }

    function _initializeSecondaryPool(PoolKey memory key, uint24 restingSpreadE6) internal {
        vm.prank(poolInitializer);
        hook.initializePool(key, Constants.SQRT_PRICE_1_1, _configWithRestingSpread(restingSpreadE6));
        priceBySlot[StateLibrary._getPoolStateSlot(key.toId())] = Constants.SQRT_PRICE_1_1;
    }

    function extsload(bytes32 slot) external view override returns (bytes32) {
        if (slot == StateLibrary._getPoolStateSlot(testPoolKey.toId())) return _packedSlot0(sqrtAmmPriceX96);
        uint160 price = priceBySlot[slot];
        if (price == 0) revert UnregisteredPool(slot);
        return _packedSlot0(price);
    }

    // -------------------------------------------------------------------------
    // Helpers
    // -------------------------------------------------------------------------

    /// Fee `beforeSwap` charges, override flag stripped; writes state.
    function _swapFee(PoolKey memory key, bool zeroForOne) internal returns (uint24) {
        SwapParams memory params = SwapParams(zeroForOne, -1e18, 0);
        (,, uint24 fee) = hook.beforeSwap(address(this), key, params, Constants.ZERO_BYTES);
        return LPFeeLibrary.removeOverrideFlag(fee);
    }

    /// `_swapFee` plus return-shape and `getFee`-parity asserts; quoted first, since a first-of-block swap writes.
    function _callBeforeSwap(PoolKey memory key, bool zeroForOne) internal returns (uint24) {
        (uint24 quotedZeroForOneE6, uint24 quotedOneForZeroE6) = hook.getFee(key);
        uint24 quotedE6 = zeroForOne ? quotedZeroForOneE6 : quotedOneForZeroE6;

        SwapParams memory params = SwapParams(zeroForOne, -1e18, 0);
        (bytes4 selector, BeforeSwapDelta delta, uint24 fee) =
            hook.beforeSwap(address(this), key, params, Constants.ZERO_BYTES);

        assertEq(selector, IHooks.beforeSwap.selector, "selector");
        assertEq(BeforeSwapDelta.unwrap(delta), BeforeSwapDelta.unwrap(BeforeSwapDeltaLibrary.ZERO_DELTA), "delta");
        assertTrue(LPFeeLibrary.isOverride(fee), "override flag");

        fee = LPFeeLibrary.removeOverrideFlag(fee);
        assertEq(fee, quotedE6, "getFee parity");
        return fee;
    }

    function _contains(bytes32[] memory slots, bytes32 slot) internal pure returns (bool) {
        for (uint256 i = 0; i < slots.length; i++) {
            if (slots[i] == slot) return true;
        }
        return false;
    }

    function _assertStateEq(VolatileFeeState memory a, VolatileFeeState memory b, string memory label) internal pure {
        assertEq(a.blockNumber, b.blockNumber, string.concat(label, ": blockNumber"));
        assertEq(a.sqrtPriceTopX96, b.sqrtPriceTopX96, string.concat(label, ": sqrtPriceTopX96"));
        assertEq(a.askPermFeeE6, b.askPermFeeE6, string.concat(label, ": askPermFeeE6"));
        assertEq(a.tempFeeE6, b.tempFeeE6, string.concat(label, ": tempFeeE6"));
        assertEq(a.tempOnBid, b.tempOnBid, string.concat(label, ": tempOnBid"));
    }

    function _assertGetFeeMatchesSwap() internal {
        (uint24 feeZeroForOneE6, uint24 feeOneForZeroE6) = hook.getFee(testPoolKey);

        uint256 snap = vm.snapshotState();
        uint24 swapZeroForOneE6 = _swapFee(testPoolKey, true);
        vm.revertToState(snap);

        snap = vm.snapshotState();
        uint24 swapOneForZeroE6 = _swapFee(testPoolKey, false);
        vm.revertToState(snap);

        assertEq(feeZeroForOneE6, swapZeroForOneE6, "zeroForOne");
        assertEq(feeOneForZeroE6, swapOneForZeroE6, "oneForZero");
    }

    function _secondaryPools() internal view returns (PoolKey[3] memory keys) {
        keys = [otherPoolKey, tickSpacingPoolKey, flippedPoolKey];
    }

    // -------------------------------------------------------------------------
    // Return shape
    // -------------------------------------------------------------------------

    function test_beforeSwap_returnsSelectorZeroDeltaAndOverrideFee() public {
        SwapParams memory params = SwapParams(true, -1e18, 0);
        (bytes4 selector, BeforeSwapDelta delta, uint24 fee) =
            hook.beforeSwap(address(this), testPoolKey, params, Constants.ZERO_BYTES);

        assertEq(selector, IHooks.beforeSwap.selector);
        assertEq(BeforeSwapDelta.unwrap(delta), BeforeSwapDelta.unwrap(BeforeSwapDeltaLibrary.ZERO_DELTA));
        assertTrue(LPFeeLibrary.isOverride(fee));
        assertEq(LPFeeLibrary.removeOverrideFlag(fee), NEUTRAL_FEE_E6);
    }

    // -------------------------------------------------------------------------
    // Fee ceiling
    // -------------------------------------------------------------------------

    /// Largest odd pie the validator accepts, so the last leg's pre-clamp baseline sum (1_999_996) is the largest a
    /// baseline add can see. The sequence fuzz (invariants.t.sol) asserts only <=.
    function test_beforeSwap_maxPie_fullRangeRoundTrip_bothSidesChargeMaxFee() public {
        _setConfig(
            VolatileFeeConfig({
                restingSpreadE6: MAX_RESTING_SPREAD_E6 - 1, // odd: resets to 999_997 ask / 999_998 bid
                backrunCaptureFractionE6: uint24(VolatileFeeCalculation.ONE_E6),
                midFadeRateE6: type(uint24).max,
                maxMidFadeE6: MAX_FEE_E6,
                skewRateE6: type(uint24).max,
                maxSkewStepE6: 1, // = band = 2 * maxSkew - RS
                maxSkewE6: MAX_FEE_E6,
                backrunThresholdE6: 0,
                restoreFractionE6: RESTORE_FRACTION_E6,
                restoreThresholdE6: RESTORE_THRESHOLD_E6
            })
        );

        _setAmmPrice(TickMath.MIN_SQRT_PRICE);
        _swapFee(testPoolKey, true); // opens the block at MIN_SQRT_PRICE

        // Same block: displacement = (2**96 - 1) * 1e6 up (ratioX96 floors to 0 and is clamped to 1)
        _setAmmPrice(TickMath.MAX_SQRT_PRICE - 1);
        assertEq(_callBeforeSwap(testPoolKey, true), MAX_FEE_E6, "mid-block bid");
        assertEq(_callBeforeSwap(testPoolKey, false), MAX_FEE_E6, "mid-block ask");

        // Next block: PI = (2**96 - 1) * 1e6 up vs. the MIN_SQRT_PRICE open; askPerm steps 999_997 -> 999_998
        _advanceBlocks(1);
        assertEq(_callBeforeSwap(testPoolKey, true), MAX_FEE_E6, "up top-of-block bid");
        assertEq(_callBeforeSwap(testPoolKey, false), MAX_FEE_E6, "up top-of-block ask");

        // Next block: PI = 1e6 down vs. the MAX_SQRT_PRICE - 1 open; askBaseline = 999_997 + (1 + 999_998) clamps
        _setAmmPrice(TickMath.MIN_SQRT_PRICE);
        _advanceBlocks(1);
        assertEq(_callBeforeSwap(testPoolKey, true), MAX_FEE_E6, "down top-of-block bid");
        assertEq(_callBeforeSwap(testPoolKey, false), MAX_FEE_E6, "down top-of-block ask");
    }

    /// askPerm = 450 + 300 = 750 < maxSkew 900, so the step binds;
    /// bid baseline = (RS - askPerm) + min(step + bcf * PI, 999_998) = 150 + 999_998 = 1_000_148, clamped.
    function test_beforeSwap_nextBlockAfterExtremeUpMove_stepsAskPermAndClampsBidBaseline() public {
        _swapFee(testPoolKey, true);
        _setAmmPrice(SQRT_PRICE_UP_16_778_216_E6);
        _advanceBlocks(1);

        (uint24 feeZeroForOneE6, uint24 feeOneForZeroE6) = hook.getFee(testPoolKey);
        assertEq(feeZeroForOneE6, MAX_FEE_E6, "bid baseline clamped");
        assertEq(feeOneForZeroE6, NEUTRAL_FEE_E6 + MAX_SKEW_STEP_E6, "ask perm steps by maxSkewStep, under maxSkew");

        _callBeforeSwap(testPoolKey, true);
        VolatileFeeState memory s = _storedState(testPoolKey.toId());
        assertEq(s.askPermFeeE6, NEUTRAL_FEE_E6 + MAX_SKEW_STEP_E6, "stored ask perm");
        assertTrue(s.tempOnBid, "temp fee sits on the bid side");
        (uint24 askBaselineFeeE6, uint24 bidBaselineFeeE6) = _storedBaselines(testPoolKey.toId());
        assertEq(askBaselineFeeE6, s.askPermFeeE6, "no backrun charge on the leaning side");
        assertEq(s.tempFeeE6, MAX_FEE_E6, "step + capture clamps as a whole");
        assertEq(bidBaselineFeeE6, MAX_FEE_E6, "1_000_148 clamps");
    }

    // -------------------------------------------------------------------------
    // Access control
    // -------------------------------------------------------------------------

    function test_beforeSwap_revertsForNonPoolManager() public {
        SwapParams memory params = SwapParams(true, -1e18, 0);
        vm.prank(other);
        vm.expectRevert(ImmutableState.NotPoolManager.selector);
        hook.beforeSwap(other, testPoolKey, params, Constants.ZERO_BYTES);
    }

    // -------------------------------------------------------------------------
    // getFee
    // -------------------------------------------------------------------------

    /// The guard runs before the price read, else the mock's `UnregisteredPool` would fire.
    function test_getFee_revertsForUninitializedPool() public {
        PoolKey memory uninitialized = PoolKey({
            currency0: Currency.wrap(address(8)),
            currency1: Currency.wrap(address(9)),
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(address(hook))
        });

        vm.expectRevert(abi.encodeWithSelector(IDynamicFeeHook.PoolNotInitialized.selector, uninitialized.toId()));
        hook.getFee(uninitialized);
    }

    function test_getFee_bothDirectionsMatchBeforeSwap_midBlock() public {
        _advanceBlocks(1);
        _callBeforeSwap(testPoolKey, true);

        _setAmmPrice(_sqrtPriceScaled(sqrtAmmPriceX96, 1_010_000));
        _assertGetFeeMatchesSwap();
    }

    function test_fuzz_getFee_matchesBeforeSwap(
        ConfigSeed memory configSeed,
        uint160 priceSeed,
        uint160 primePriceSeed,
        uint32 blockGap,
        bool primeState
    ) public {
        VolatileFeeConfig memory config = _boundFeeConfig(configSeed);
        _setConfig(config);

        if (primeState) {
            _setAmmPrice(_boundSqrtPriceRelative(primePriceSeed, Constants.SQRT_PRICE_1_1));
            _advanceBlocks(1);
            _swapFee(testPoolKey, true);
        }

        // gap 0 on primed state is the mid-block path
        _advanceBlocks(bound(blockGap, primeState ? 0 : 1, 10_000));
        _setAmmPrice(_boundSqrtPriceRelative(priceSeed, Constants.SQRT_PRICE_1_1));

        _assertGetFeeMatchesSwap();
    }

    // -------------------------------------------------------------------------
    // Freshness
    // -------------------------------------------------------------------------

    function test_beforeSwap_afterInitialize_adoptsLivePriceWithoutChargingTheGap() public {
        PoolId poolId = testPoolKey.toId();
        assertEq(_storedState(poolId).sqrtPriceTopX96, 0, "init must leave the cache empty");

        uint160 livePrice = _sqrtPriceScaled(Constants.SQRT_PRICE_1_1, 1_100_000);
        _setAmmPrice(livePrice);
        _advanceBlocks(1);

        uint24 feeE6 = _callBeforeSwap(testPoolKey, true);

        VolatileFeeState memory state = _storedState(poolId);
        assertEq(state.sqrtPriceTopX96, livePrice, "must cache the live price, not the init price");
        assertEq(state.askPermFeeE6, NEUTRAL_FEE_E6, "no skew off an undefined PI");
        assertEq(state.tempFeeE6, 0, "no backrun charge off an undefined PI");
        (uint24 askBaselineFeeE6, uint24 bidBaselineFeeE6) = _storedBaselines(poolId);
        assertEq(askBaselineFeeE6, NEUTRAL_FEE_E6);
        assertEq(bidBaselineFeeE6, NEUTRAL_FEE_E6);
        assertEq(feeE6, NEUTRAL_FEE_E6, "and the swap pays the neutral baseline");
    }

    function test_beforeSwap_afterConfigReset_rereadsPriceAndDropsSkew() public {
        PoolId poolId = testPoolKey.toId();

        _advanceBlocks(1);
        _callBeforeSwap(testPoolKey, true);
        _setAmmPrice(_sqrtPriceScaled(sqrtAmmPriceX96, 1_050_000));
        _advanceBlocks(1);
        _callBeforeSwap(testPoolKey, true);
        assertTrue(_storedState(poolId).askPermFeeE6 != NEUTRAL_FEE_E6, "skew must have moved off centre");

        _setConfig(_defaultConfig());

        VolatileFeeState memory reset = _storedState(poolId);
        assertEq(reset.sqrtPriceTopX96, 0, "reset must zero the cached open");
        assertEq(reset.askPermFeeE6, NEUTRAL_FEE_E6, "reset must recentre the skew");

        // same block as the reset: the zeroed blockNumber alone makes this swap a new block
        uint160 freshPrice = _sqrtPriceScaled(sqrtAmmPriceX96, 1_020_000);
        _setAmmPrice(freshPrice);
        uint24 feeE6 = _callBeforeSwap(testPoolKey, true);

        assertEq(_storedState(poolId).sqrtPriceTopX96, freshPrice, "must re-read, not reuse the pre-reset open");
        assertEq(feeE6, NEUTRAL_FEE_E6, "and price the swap off the recentred baselines");
    }

    // -------------------------------------------------------------------------
    // Write discipline
    // -------------------------------------------------------------------------

    function test_beforeSwap_firstSwapOfBlock_writesExactlyTheStateSlots() public {
        PoolId poolId = testPoolKey.toId();
        _advanceBlocks(5);
        uint160 openPrice = _sqrtPriceScaled(Constants.SQRT_PRICE_1_1, 1_030_000);
        _setAmmPrice(openPrice);

        vm.record();
        _swapFee(testPoolKey, true);
        (, bytes32[] memory writes) = vm.accesses(address(hook));

        assertTrue(_contains(writes, _stateSlot(poolId)), "must write the state word");
        assertFalse(_contains(writes, _configSlot(poolId)), "must not touch the config word");

        VolatileFeeState memory state = _storedState(poolId);
        assertEq(state.blockNumber, uint40(block.number), "block stamped");
        assertEq(state.sqrtPriceTopX96, openPrice, "open cached");
    }

    function test_beforeSwap_firstSwapOfBlock_leavesTheConfigWordIntact() public {
        PoolId poolId = testPoolKey.toId();
        VolatileFeeConfig memory before = _storedConfig(poolId);

        _advanceBlocks(5);
        _setAmmPrice(_sqrtPriceScaled(Constants.SQRT_PRICE_1_1, 1_030_000));
        _swapFee(testPoolKey, true);

        assertEq(keccak256(abi.encode(_storedConfig(poolId))), keccak256(abi.encode(before)), "config survives");
        assertTrue(_storedState(poolId).sqrtPriceTopX96 != 0, "and the state write landed");
    }

    function test_beforeSwap_laterSwapsInBlock_writeNothingButStillReprice() public {
        PoolId poolId = testPoolKey.toId();
        _advanceBlocks(1);
        uint24 openFeeE6 = _callBeforeSwap(testPoolKey, true);
        assertEq(openFeeE6, NEUTRAL_FEE_E6, "no displacement at the open");

        VolatileFeeState memory before = _storedState(poolId);

        // +1%: selling into it is the backrun, buying continues it
        _setAmmPrice(_sqrtPriceScaled(sqrtAmmPriceX96, 1_010_000));

        vm.record();
        uint24 backrunFeeE6 = _swapFee(testPoolKey, true);
        uint24 continuingFeeE6 = _swapFee(testPoolKey, false);
        (, bytes32[] memory writes) = vm.accesses(address(hook));

        assertEq(writes.length, 0, "a later swap in the block must not write");
        _assertStateEq(_storedState(poolId), before, "mid-block state");

        // 0.05 * 1% = 500 exceeds the 200 cap, so the continuing side pins to baseline + maxMidFade above 0.4%
        assertEq(continuingFeeE6, NEUTRAL_FEE_E6 + MAX_MID_FADE_E6, "continuing side capped at maxMidFade");
        // backrun = baseline + capture * displacement = 50% * 1% = 5_000
        assertGt(backrunFeeE6, continuingFeeE6, "backrun must cost more than continuing");
        assertApproxEqAbs(backrunFeeE6, NEUTRAL_FEE_E6 + 5_000, 100, "backrun ~ baseline + capture * 1%");
    }

    function test_beforeSwap_firstSwapOfBlock_emitsFeeStateUpdated() public {
        PoolId poolId = testPoolKey.toId();
        _swapFee(testPoolKey, true);
        _setAmmPrice(SQRT_PRICE_UP_16_778_216_E6);
        _advanceBlocks(1);

        vm.recordLogs();
        _swapFee(testPoolKey, true);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        VolatileFeeState memory s = _storedState(poolId);
        assertEq(logs.length, 1, "one event");
        assertEq(logs[0].emitter, address(hook), "emitter");
        assertEq(logs[0].topics[0], IVolatilePairHook.FeeStateUpdated.selector, "signature");
        assertEq(logs[0].topics[1], PoolId.unwrap(poolId), "indexed poolId");
        assertEq(
            logs[0].data,
            abi.encode(
                s.blockNumber,
                s.sqrtPriceTopX96,
                s.askPermFeeE6,
                _storedConfig(poolId).restingSpreadE6 - s.askPermFeeE6,
                s.tempFeeE6,
                s.tempOnBid
            ),
            "fields match the stored state"
        );
        assertTrue(s.tempOnBid && s.tempFeeE6 != 0, "non-trivial state was logged");
    }

    function test_beforeSwap_laterSwapsInBlock_emitNothing() public {
        _advanceBlocks(1);
        _swapFee(testPoolKey, true);
        _setAmmPrice(_sqrtPriceScaled(sqrtAmmPriceX96, 1_010_000));

        vm.recordLogs();
        _swapFee(testPoolKey, true);
        _swapFee(testPoolKey, false);
        assertEq(vm.getRecordedLogs().length, 0, "same block must not re-log");
    }

    // -------------------------------------------------------------------------
    // View honesty
    // -------------------------------------------------------------------------

    function test_getFee_mutatesNothing_evenWhenItRollsANewBlock() public {
        PoolId poolId = testPoolKey.toId();
        _advanceBlocks(1);
        _callBeforeSwap(testPoolKey, true);

        _setAmmPrice(_sqrtPriceScaled(sqrtAmmPriceX96, 1_040_000));
        _advanceBlocks(1);

        VolatileFeeState memory before = _storedState(poolId);
        bytes32 rawStateBefore = _rawStateHash(poolId);
        assertTrue(before.blockNumber != uint40(block.number), "stored block must still be stale");

        hook.getFee(testPoolKey);
        hook.getFee(testPoolKey);

        _assertStateEq(_storedState(poolId), before, "after getFee");
        assertEq(_rawStateHash(poolId), rawStateBefore, "state slots");

        _assertGetFeeMatchesSwap();
    }

    // -------------------------------------------------------------------------
    // Clock robustness
    // -------------------------------------------------------------------------

    /// Opens a new block only on a strictly greater block number.
    function test_beforeSwap_blockNumberRegression_isNoOp() public {
        PoolId poolId = testPoolKey.toId();
        _setAmmPrice(_sqrtPriceScaled(Constants.SQRT_PRICE_1_1, 1_020_000));

        vm.roll(1000);
        _swapFee(testPoolKey, true);
        VolatileFeeState memory primed = _storedState(poolId);
        assertEq(primed.blockNumber, 1000);

        vm.roll(999);
        _callBeforeSwap(testPoolKey, true);
        _assertStateEq(_storedState(poolId), primed, "a regressed block changes nothing");

        // post-reset: blockNumber is zeroed, so any block number opens
        vm.roll(2000);
        _setConfig(_defaultConfig());
        assertEq(_storedState(poolId).blockNumber, 0, "reset must zero the stored block");
        vm.roll(1999);
        _callBeforeSwap(testPoolKey, true);
        assertEq(_storedState(poolId).blockNumber, 1999);
    }

    // -------------------------------------------------------------------------
    // Temp fee block gap
    // -------------------------------------------------------------------------

    /// Opens a block at 1:1, pushes the price up 20bp (above the 10bp capture threshold), then waits `gap` blocks
    /// with no swaps.
    function _pushUpAndWait(uint256 gap) internal {
        _swapFee(testPoolKey, true);
        _setAmmPrice(_sqrtPriceScaled(Constants.SQRT_PRICE_1_1, 1_002_000));
        _advanceBlocks(gap);
    }

    function test_beforeSwap_withinMaxBlockGap_chargesTempFee() public {
        _pushUpAndWait(MAX_TEMP_FEE_BLOCK_GAP);
        uint24 bidFeeE6 = _callBeforeSwap(testPoolKey, true);

        VolatileFeeState memory s = _storedState(testPoolKey.toId());
        assertTrue(s.tempOnBid, "up move puts the temp fee on the bid");
        assertGt(s.tempFeeE6, 0, "temp fee within the gap");
        assertEq(bidFeeE6, RESTING_SPREAD_E6 - s.askPermFeeE6 + s.tempFeeE6, "bid pays perm + temp");
    }

    /// The same push seen one block past the gap: the skew steps exactly as within the gap, the temp fee (restore
    /// and capture) is 0, and the bid pays its lowered permanent fee.
    function test_beforeSwap_pastMaxBlockGap_dropsTempFeeButStepsSkew() public {
        uint256 snapshot = vm.snapshotState();
        _pushUpAndWait(MAX_TEMP_FEE_BLOCK_GAP);
        _callBeforeSwap(testPoolKey, true);
        VolatileFeeState memory withinGap = _storedState(testPoolKey.toId());
        vm.revertToState(snapshot);

        _pushUpAndWait(MAX_TEMP_FEE_BLOCK_GAP + 1);
        uint24 bidFeeE6 = _callBeforeSwap(testPoolKey, true);
        VolatileFeeState memory pastGap = _storedState(testPoolKey.toId());

        assertEq(pastGap.askPermFeeE6, withinGap.askPermFeeE6, "skew steps the same");
        assertGt(pastGap.askPermFeeE6, NEUTRAL_FEE_E6, "ask leans after the up move");
        assertTrue(pastGap.tempOnBid, "direction still recorded");
        assertEq(pastGap.tempFeeE6, 0, "temp fee dropped past the gap");
        assertEq(bidFeeE6, RESTING_SPREAD_E6 - pastGap.askPermFeeE6, "bid pays its lowered permanent fee");
        assertLt(bidFeeE6, NEUTRAL_FEE_E6, "below neutral once the temp fee is gone");
    }

    /// An idle pool's quote carries the temp fee only while the next block would still be within the gap.
    function test_getFee_idlePool_dropsTempFeeOnceGapPassesMax() public {
        _pushUpAndWait(MAX_TEMP_FEE_BLOCK_GAP);
        (uint24 bidWithinGapE6, uint24 askWithinGapE6) = hook.getFee(testPoolKey);
        _advanceBlocks(1);
        (uint24 bidPastGapE6, uint24 askPastGapE6) = hook.getFee(testPoolKey);

        assertEq(askPastGapE6, askWithinGapE6, "leaning side unchanged");
        assertEq(bidPastGapE6, RESTING_SPREAD_E6 - askPastGapE6, "bid quote back to its permanent fee");
        assertGt(bidWithinGapE6, bidPastGapE6, "temp fee was in the earlier quote");
    }

    /// Any max gap, reached by upgrading the implementation: a swap `gap` blocks after the push pays the temp fee
    /// exactly when gap <= maxGap.
    function test_fuzz_beforeSwap_tempFeeOnlyWithinMaxBlockGap(uint256 maxGap, uint256 gap) public {
        maxGap = bound(maxGap, 1, 1000);
        gap = bound(gap, 1, 2000);
        VolatilePairHook newImpl = new VolatilePairHook(IPoolManager(address(this)), maxGap);
        vm.prank(owner);
        hook.upgradeToAndCall(address(newImpl), "");
        assertEq(hook.maxTempFeeBlockGap(), maxGap, "upgrade sets the gap");

        _pushUpAndWait(gap);
        _callBeforeSwap(testPoolKey, true);

        assertEq(_storedState(testPoolKey.toId()).tempFeeE6 > 0, gap <= maxGap, "temp fee iff within the gap");
    }

    // -------------------------------------------------------------------------
    // State isolation across pools
    // -------------------------------------------------------------------------

    function test_beforeSwap_swappingOnePool_leavesOtherPoolsUntouched() public {
        PoolKey[3] memory neighbours = _secondaryPools();

        VolatileFeeState[3] memory before;
        uint24[3] memory quotedBeforeE6;
        for (uint256 i = 0; i < neighbours.length; i++) {
            before[i] = _storedState(neighbours[i].toId());
            (quotedBeforeE6[i],) = hook.getFee(neighbours[i]);
        }

        _advanceBlocks(1);
        _setAmmPrice(_sqrtPriceScaled(Constants.SQRT_PRICE_1_1, 1_060_000));
        _callBeforeSwap(testPoolKey, true);
        _callBeforeSwap(testPoolKey, false);

        for (uint256 i = 0; i < neighbours.length; i++) {
            _assertStateEq(_storedState(neighbours[i].toId()), before[i], "neighbour state");
            (uint24 quotedAfterE6,) = hook.getFee(neighbours[i]);
            assertEq(quotedAfterE6, quotedBeforeE6[i], "neighbour fee");
        }

        assertEq(_storedConfig(otherPoolKey.toId()).restingSpreadE6, 1200);
        assertEq(_storedConfig(tickSpacingPoolKey.toId()).restingSpreadE6, 1500);
        assertEq(_storedConfig(flippedPoolKey.toId()).restingSpreadE6, 1800);
        assertEq(_storedConfig(testPoolKey.toId()).restingSpreadE6, RESTING_SPREAD_E6);
    }

    function test_updateFeeConfig_onePool_leavesOtherPoolsUntouched() public {
        _advanceBlocks(1);
        _callBeforeSwap(testPoolKey, true);
        PoolKey[3] memory neighbours = _secondaryPools();
        for (uint256 i = 0; i < neighbours.length; i++) {
            _callBeforeSwap(neighbours[i], true);
        }

        VolatileFeeState[3] memory before;
        for (uint256 i = 0; i < neighbours.length; i++) {
            before[i] = _storedState(neighbours[i].toId());
            assertTrue(before[i].sqrtPriceTopX96 != 0, "neighbour must hold a cached open");
        }

        _setConfig(_configWithRestingSpread(2000));

        assertEq(_storedState(testPoolKey.toId()).sqrtPriceTopX96, 0, "target pool resets");
        for (uint256 i = 0; i < neighbours.length; i++) {
            _assertStateEq(_storedState(neighbours[i].toId()), before[i], "neighbour state");
        }
    }

    // -------------------------------------------------------------------------
    // Gas
    // -------------------------------------------------------------------------

    function test_beforeSwap_newBlock_gas() public {
        _advanceBlocks(1);
        _setAmmPrice(_sqrtPriceScaled(Constants.SQRT_PRICE_1_1, 1_020_000));

        SwapParams memory params = SwapParams(true, -1e18, 0);
        hook.beforeSwap(address(this), testPoolKey, params, Constants.ZERO_BYTES);
        vm.snapshotGasLastCall("beforeSwap_newBlock");
    }

    function test_beforeSwap_sameBlock_gas() public {
        _advanceBlocks(1);
        SwapParams memory params = SwapParams(true, -1e18, 0);
        hook.beforeSwap(address(this), testPoolKey, params, Constants.ZERO_BYTES);

        hook.beforeSwap(address(this), testPoolKey, params, Constants.ZERO_BYTES);
        vm.snapshotGasLastCall("beforeSwap_sameBlock");
    }

    function test_beforeSwap_sameBlock_backrun_gas() public {
        _advanceBlocks(1);
        SwapParams memory sell = SwapParams(true, -1e18, 0);
        hook.beforeSwap(address(this), testPoolKey, sell, Constants.ZERO_BYTES);

        _setAmmPrice(_sqrtPriceScaled(sqrtAmmPriceX96, 1_010_000));
        hook.beforeSwap(address(this), testPoolKey, sell, Constants.ZERO_BYTES);
        vm.snapshotGasLastCall("beforeSwap_sameBlock_backrun");
    }

    function test_beforeSwap_sameBlock_continuing_gas() public {
        _advanceBlocks(1);
        SwapParams memory sell = SwapParams(true, -1e18, 0);
        hook.beforeSwap(address(this), testPoolKey, sell, Constants.ZERO_BYTES);

        _setAmmPrice(_sqrtPriceScaled(sqrtAmmPriceX96, 1_010_000));
        SwapParams memory buy = SwapParams(false, -1e18, 0);
        hook.beforeSwap(address(this), testPoolKey, buy, Constants.ZERO_BYTES);
        vm.snapshotGasLastCall("beforeSwap_sameBlock_continuing");
    }
}
