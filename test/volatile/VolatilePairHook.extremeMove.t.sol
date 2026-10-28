// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {VolatilePairTestBase} from "./base/VolatilePairTestBase.sol";
import {VolatilePairHook} from "../../src/volatile/VolatilePairHook.sol";
import {BaseDynamicFeeHook} from "../../src/base/BaseDynamicFeeHook.sol";
import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol";
import {Constants} from "@uniswap/v4-core/test/utils/Constants.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {ProtocolFeeLibrary} from "@uniswap/v4-core/src/libraries/ProtocolFeeLibrary.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {ModifyLiquidityParams, SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {Vm} from "forge-std/Vm.sol";
// Imported only so forge builds the artifact `deployCodeTo` loads by name.
import {ERC1967Proxy as _ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

/// Real-PoolManager swaps at price ratios above 2**24 pips, where the fee sits on its MAX_FEE_E6 clamp.
contract VolatilePairHookExtremeMoveTest is VolatilePairTestBase, Deployers {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    /// Narrow, so a pump empties it and slides through empty liquidity to the caller's price limit for free.
    int24 internal constant TICK_LOWER = -600;
    int24 internal constant TICK_UPPER = 600;
    int128 internal constant LIQUIDITY = 1e18;

    /// Exact input; the range absorbs L * (sqrt(1.0001^600) - 1) ~= 3.05e16 of currency1, so 1e18 empties it.
    int256 internal constant PUMP_AMOUNT = -1e18;
    /// Exact input.
    int256 internal constant BACKRUN_EXACT_INPUT_AMOUNT = -1e16;
    /// Exact output; the range holds ~6e16 of currency1 once the price is above it, so this fills in full.
    int256 internal constant BACKRUN_EXACT_OUTPUT_AMOUNT = 1e15;

    function setUp() public override {
        deployFreshManagerAndRouters();
        deployMintAndApprove2Currencies();

        VolatilePairHook impl = new VolatilePairHook(manager, MAX_TEMP_FEE_BLOCK_GAP);
        hook = VolatilePairHook(address(uint160(uint256(type(uint160).max) & clearAllHookPermissionsMask | HOOK_FLAGS)));
        deployCodeTo(
            "ERC1967Proxy.sol:ERC1967Proxy",
            abi.encode(
                address(impl), abi.encodeCall(BaseDynamicFeeHook.initialize, (owner, poolInitializer, configManager))
            ),
            address(hook)
        );

        testPoolKey = PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(address(hook))
        });

        vm.prank(poolInitializer);
        hook.initializePool(testPoolKey, Constants.SQRT_PRICE_1_1, _defaultConfig());

        modifyLiquidityRouter.modifyLiquidity(
            testPoolKey,
            ModifyLiquidityParams({tickLower: TICK_LOWER, tickUpper: TICK_UPPER, liquidityDelta: LIQUIDITY, salt: 0}),
            ZERO_BYTES
        );
    }

    // -------------------------------------------------------------------------
    // Ceiling charged
    // -------------------------------------------------------------------------

    /// swap.t.sol proves quote/charge parity only at the neutral fee. At a 1e6 fee no input would reach the curve and
    /// the pool could never be moved back.
    function test_swap_extremePump_chargesMaxFeeOnTheBackrun() public {
        _pump(SQRT_PRICE_UP_16_778_216_E6);
        (uint160 priceAfter,,,) = manager.getSlot0(testPoolKey.toId());
        assertEq(priceAfter, SQRT_PRICE_UP_16_778_216_E6, "the limit binds");

        (uint24 feeZeroForOneE6, uint24 feeOneForZeroE6) = hook.getFee(testPoolKey);
        assertEq(feeZeroForOneE6, MAX_FEE_E6, "backrun quote clamps");
        assertEq(feeOneForZeroE6, NEUTRAL_FEE_E6 + MAX_MID_FADE_E6, "continuing quote caps at maxMidFade");

        vm.recordLogs();
        BalanceDelta backrunDelta = _swapToLimit(true, BACKRUN_EXACT_INPUT_AMOUNT, MIN_PRICE_LIMIT);
        assertEq(_swapFeeFromLogs(), MAX_FEE_E6, "v4 charges the quoted ceiling");
        assertGt(backrunDelta.amount1(), 0, "2 pips of the input survive the fee and buy output");
    }

    // -------------------------------------------------------------------------
    // Protocol fee
    // -------------------------------------------------------------------------

    /// Why MAX_FEE_E6 is 1e6 - 2: v4 compounds fees as p + f - floor(p * f / 1e6) (Pool.sol:307) and reverts
    /// exact-output swaps once that reaches 1e6 (Pool.sol:311-314). 999_999 compounds to 1e6 under any nonzero p;
    /// 999_998 compounds to 999_999 under the max.
    function test_swap_withMaxProtocolFee_exactOutputAtMaxFeeStillExecutes() public {
        assertEq(
            ProtocolFeeLibrary.calculateSwapFee(uint16(ProtocolFeeLibrary.MAX_PROTOCOL_FEE), MAX_FEE_E6 + 1),
            LPFeeLibrary.MAX_LP_FEE
        );

        vm.prank(feeController);
        manager.setProtocolFee(
            testPoolKey, uint24(ProtocolFeeLibrary.MAX_PROTOCOL_FEE) << 12 | uint24(ProtocolFeeLibrary.MAX_PROTOCOL_FEE)
        );
        _pump(SQRT_PRICE_UP_16_778_216_E6);

        vm.recordLogs();
        BalanceDelta backrunDelta = _swapToLimit(true, BACKRUN_EXACT_OUTPUT_AMOUNT, MIN_PRICE_LIMIT);
        assertEq(
            _swapFeeFromLogs(),
            ProtocolFeeLibrary.calculateSwapFee(uint16(ProtocolFeeLibrary.MAX_PROTOCOL_FEE), MAX_FEE_E6),
            "protocol fee compounds on the clamped LP fee"
        );
        assertEq(int256(backrunDelta.amount1()), BACKRUN_EXACT_OUTPUT_AMOUNT, "exact output fills in full");
    }

    // -------------------------------------------------------------------------
    // Helpers
    // -------------------------------------------------------------------------

    function _swapToLimit(bool zeroForOne, int256 amountSpecified, uint160 limit) internal returns (BalanceDelta) {
        return swapRouter.swap(
            testPoolKey,
            SwapParams({zeroForOne: zeroForOne, amountSpecified: amountSpecified, sqrtPriceLimitX96: limit}),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ZERO_BYTES
        );
    }

    function _pump(uint160 limit) internal {
        _swapToLimit(false, PUMP_AMOUNT, limit);
    }

    /// `fee` of the manager's last Swap event: the hook's override, or the compounded fee once a protocol fee is set.
    function _swapFeeFromLogs() internal returns (uint24 feeE6) {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i = logs.length; i > 0; i--) {
            Vm.Log memory l = logs[i - 1];
            if (l.emitter == address(manager) && l.topics.length > 0 && l.topics[0] == IPoolManager.Swap.selector) {
                (,,,,, feeE6) = abi.decode(l.data, (int128, int128, uint160, uint128, int24, uint24));
                return feeE6;
            }
        }
        revert("no Swap event");
    }
}
