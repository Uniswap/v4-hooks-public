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
import {LiquidityAmounts} from "@uniswap/v4-core/test/utils/LiquidityAmounts.sol";
import {Constants} from "@uniswap/v4-core/test/utils/Constants.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {StableStableHook} from "../../src/stable/StableStableHook.sol";
import {StableStableQuoterHook} from "../../src/alf/StableStableQuoterHook.sol";
import {AttestationRegistry} from "../../src/alf/AttestationRegistry.sol";
import {FeeConfig} from "../../src/stable/interfaces/IFeeConfiguration.sol";

/// @title Cross-verification: StableStableHook vs StableStableQuoterHook
/// @notice Deploys both hooks with identical config and asserts identical swap outputs.
contract StableStableQuoterHookCrossVerificationTest is Test, Deployers {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;
    using StateLibrary for IPoolManager;

    StableStableHook public origHook;
    StableStableQuoterHook public quoterHook;
    AttestationRegistry public attestationRegistry;

    address owner = makeAddr("owner");
    address configManager = makeAddr("configManager");

    uint24 constant K = 16_609_443;
    uint24 constant LOG_K = 9140;
    uint24 constant OPTIMAL_FEE_E6 = 90;
    uint160 constant REFERENCE_SQRT_PRICE_X96 = Constants.SQRT_PRICE_1_1;
    int24 constant TICK_SPACING = 60;

    FeeConfig testFeeConfig =
        FeeConfig({k: K, logK: LOG_K, optimalFeeE6: OPTIMAL_FEE_E6, targetMultiplier: 0, referenceSqrtPriceX96: REFERENCE_SQRT_PRICE_X96});

    PoolKey origPoolKey;
    PoolKey quoterPoolKey;

    function setUp() public {
        deployFreshManagerAndRouters();
        deployMintAndApprove2Currencies();

        attestationRegistry = new AttestationRegistry(owner);

        uint160 flags = uint160(Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG);

        // Deploy original StableStableHook
        origHook = StableStableHook(address(uint160(uint256(type(uint160).max) & clearAllHookPermissionsMask | flags)));
        deployCodeTo("StableStableHook", abi.encode(manager, owner, configManager), address(origHook));

        // Deploy StableStableQuoterHook at a different address with same flags
        quoterHook = StableStableQuoterHook(
            address(uint160((uint256(type(uint160).max) - 0x4000) & clearAllHookPermissionsMask | flags))
        );
        deployCodeTo(
            "StableStableQuoterHook",
            abi.encode(manager, address(attestationRegistry), uint32(100_000), owner, configManager),
            address(quoterHook)
        );

        // Pool keys: identical config, different hooks
        origPoolKey = PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(address(origHook))
        });
        quoterPoolKey = PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(address(quoterHook))
        });

        // Initialize both at the same price with the same fee config
        vm.startPrank(owner);
        origHook.initializePool(origPoolKey, Constants.SQRT_PRICE_1_1, testFeeConfig);
        quoterHook.initializePool(quoterPoolKey, Constants.SQRT_PRICE_1_1, testFeeConfig, 0, true);
        vm.stopPrank();

        // Seed identical LP on both pools
        _seedLP(origPoolKey, -600, 600, 1_000_000e18, 1_000_000e18);
        _seedLP(quoterPoolKey, -600, 600, 1_000_000e18, 1_000_000e18);
    }

    function _seedLP(PoolKey memory key_, int24 tickLower, int24 tickUpper, uint256 amount0, uint256 amount1) internal {
        (uint160 sqrtPriceX96,,,) = manager.getSlot0(key_.toId());
        uint128 liq = LiquidityAmounts.getLiquidityForAmounts(
            sqrtPriceX96,
            TickMath.getSqrtPriceAtTick(tickLower),
            TickMath.getSqrtPriceAtTick(tickUpper),
            amount0,
            amount1
        );
        modifyLiquidityRouter.modifyLiquidity(
            key_,
            ModifyLiquidityParams({tickLower: tickLower, tickUpper: tickUpper, liquidityDelta: int128(liq), salt: 0}),
            ""
        );
    }

    // ══════════════════════════════════════════════════════════════════════
    // Swap Output Cross-Verification
    // ══════════════════════════════════════════════════════════════════════

    function test_crossVerify_firstSwap_zeroForOne() public {
        BalanceDelta origDelta = swap(origPoolKey, true, -1e18, "");
        BalanceDelta quoterDelta = swap(quoterPoolKey, true, -1e18, "");

        assertEq(origDelta.amount0(), quoterDelta.amount0(), "amount0 mismatch");
        assertEq(origDelta.amount1(), quoterDelta.amount1(), "amount1 mismatch");
    }

    function test_crossVerify_firstSwap_oneForZero() public {
        BalanceDelta origDelta = swap(origPoolKey, false, -1e18, "");
        BalanceDelta quoterDelta = swap(quoterPoolKey, false, -1e18, "");

        assertEq(origDelta.amount0(), quoterDelta.amount0(), "amount0 mismatch");
        assertEq(origDelta.amount1(), quoterDelta.amount1(), "amount1 mismatch");
    }

    function test_crossVerify_exactOutputSwap() public {
        BalanceDelta origDelta = swap(origPoolKey, true, 0.5e18, "");
        BalanceDelta quoterDelta = swap(quoterPoolKey, true, 0.5e18, "");

        assertEq(origDelta.amount0(), quoterDelta.amount0(), "exact output amount0 mismatch");
        assertEq(origDelta.amount1(), quoterDelta.amount1(), "exact output amount1 mismatch");
    }

    function test_crossVerify_sequentialSwaps() public {
        int256[5] memory amounts = [int256(-1e18), -10e18, -100e18, int256(50e18), -5e18];
        bool[5] memory directions = [true, false, true, true, false];

        for (uint256 i = 0; i < 5; i++) {
            BalanceDelta origDelta = swap(origPoolKey, directions[i], amounts[i], "");
            BalanceDelta quoterDelta = swap(quoterPoolKey, directions[i], amounts[i], "");

            assertEq(
                origDelta.amount0(), quoterDelta.amount0(), string.concat("amount0 mismatch at swap ", vm.toString(i))
            );
            assertEq(
                origDelta.amount1(), quoterDelta.amount1(), string.concat("amount1 mismatch at swap ", vm.toString(i))
            );
        }
    }

    function test_crossVerify_outsideOptimalRange_bothDirections() public {
        // Push both pools identically outside optimal range
        BalanceDelta origLarge = swap(origPoolKey, true, -50_000e18, "");
        BalanceDelta quoterLarge = swap(quoterPoolKey, true, -50_000e18, "");
        assertEq(origLarge.amount0(), quoterLarge.amount0(), "large swap amount0");
        assertEq(origLarge.amount1(), quoterLarge.amount1(), "large swap amount1");

        // zeroForOne: pushing further from reference (0 fee)
        BalanceDelta origZFO = swap(origPoolKey, true, -1e18, "");
        BalanceDelta quoterZFO = swap(quoterPoolKey, true, -1e18, "");
        assertEq(origZFO.amount0(), quoterZFO.amount0(), "ZFO amount0");
        assertEq(origZFO.amount1(), quoterZFO.amount1(), "ZFO amount1");

        // oneForZero: pushing toward reference (decaying fee > 0)
        BalanceDelta origOFZ = swap(origPoolKey, false, -1e18, "");
        BalanceDelta quoterOFZ = swap(quoterPoolKey, false, -1e18, "");
        assertEq(origOFZ.amount0(), quoterOFZ.amount0(), "OFZ amount0");
        assertEq(origOFZ.amount1(), quoterOFZ.amount1(), "OFZ amount1");
    }

    function test_crossVerify_feeDecayAcrossBlocks() public {
        // Push outside optimal range
        swap(origPoolKey, true, -50_000e18, "");
        swap(quoterPoolKey, true, -50_000e18, "");

        // Initial swap toward reference (charges decaying fee)
        swap(origPoolKey, false, -1e18, "");
        swap(quoterPoolKey, false, -1e18, "");

        // Advance blocks for fee decay
        vm.roll(block.number + 10);

        // Swap again — fee should have decayed identically
        BalanceDelta origDelta = swap(origPoolKey, false, -1e18, "");
        BalanceDelta quoterDelta = swap(quoterPoolKey, false, -1e18, "");

        assertEq(origDelta.amount0(), quoterDelta.amount0(), "decayed amount0");
        assertEq(origDelta.amount1(), quoterDelta.amount1(), "decayed amount1");
    }

    function test_crossVerify_feeState_matchesAfterSwap() public {
        swap(origPoolKey, true, -1e18, "");
        swap(quoterPoolKey, true, -1e18, "");

        (uint256 origDecaying, uint256 origSqrtPrice, uint256 origBlock) = origHook.feeState(origPoolKey.toId());
        (uint256 quoterDecaying, uint256 quoterSqrtPrice, uint256 quoterBlock) =
            quoterHook.feeState(quoterPoolKey.toId());

        assertEq(origDecaying, quoterDecaying, "decayingFeeE12 mismatch");
        assertEq(origSqrtPrice, quoterSqrtPrice, "sqrtAmmPriceX96 mismatch");
        assertEq(origBlock, quoterBlock, "blockNumber mismatch");
    }

    function test_crossVerify_indicativeQuote_matchesOriginalSwap() public {
        uint256 indicative = quoterHook.getIndicativeQuote(quoterPoolKey, true, -1e18, "");
        BalanceDelta origDelta = swap(origPoolKey, true, -1e18, "");
        uint256 origOutput = uint256(int256(origDelta.amount1()));

        assertEq(indicative, origOutput, "indicative quote != original swap output");
    }

    function testFuzz_crossVerify(int256 amount, bool zeroForOne) public {
        amount = bound(amount, -100_000e18, -0.001e18);

        BalanceDelta origDelta = swap(origPoolKey, zeroForOne, amount, "");
        BalanceDelta quoterDelta = swap(quoterPoolKey, zeroForOne, amount, "");

        assertEq(origDelta.amount0(), quoterDelta.amount0(), "fuzz amount0");
        assertEq(origDelta.amount1(), quoterDelta.amount1(), "fuzz amount1");
    }
}
