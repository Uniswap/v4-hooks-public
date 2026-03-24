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
import {CustomRevert} from "@uniswap/v4-core/src/libraries/CustomRevert.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {StableStableQuoterHook} from "../../src/alf/StableStableQuoterHook.sol";
import {AttestationRegistry} from "../../src/alf/AttestationRegistry.sol";
import {IAttestationRegistry, Attestation} from "../../src/alf/interfaces/IAttestationRegistry.sol";
import {MockAttestationSigner} from "./mocks/MockAttestationSigner.sol";
import {ALFHookData} from "../../src/alf/interfaces/IALFHook.sol";
import {FeeConfig} from "../../src/stable/interfaces/IFeeConfiguration.sol";
import {FeeCalculation} from "../../src/stable/libraries/FeeCalculation.sol";
import {SwapSimulator} from "../../src/alf/libraries/SwapSimulator.sol";

contract StableStableQuoterHookTest is Test, Deployers {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;
    using StateLibrary for IPoolManager;

    AttestationRegistry public attestationRegistry;
    StableStableQuoterHook public hook;

    address owner = makeAddr("owner");
    address configManager = makeAddr("configManager");
    uint256 attesterPk;
    address attester;

    uint24 constant K = 16_609_443;
    uint24 constant LOG_K = 9140;
    uint24 constant OPTIMAL_FEE_E6 = 90; // 0.9 bps
    uint160 constant REFERENCE_SQRT_PRICE_X96 = Constants.SQRT_PRICE_1_1;
    int24 constant TICK_SPACING = 60;

    FeeConfig testFeeConfig =
        FeeConfig({k: K, logK: LOG_K, optimalFeeE6: OPTIMAL_FEE_E6, targetMultiplier: 0, referenceSqrtPriceX96: REFERENCE_SQRT_PRICE_X96});

    PoolKey testPoolKey;

    function setUp() public {
        deployFreshManagerAndRouters();
        deployMintAndApprove2Currencies();

        attestationRegistry = new AttestationRegistry(owner);

        (attester, attesterPk) = makeAddrAndKey("attester");
        vm.prank(owner);
        attestationRegistry.addAttester(attester);

        // Deploy hook at flag-mined address
        uint160 flags = uint160(Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG);
        hook =
            StableStableQuoterHook(address(uint160(uint256(type(uint160).max) & clearAllHookPermissionsMask | flags)));
        deployCodeTo(
            "StableStableQuoterHook",
            abi.encode(manager, address(attestationRegistry), uint32(100_000), owner, configManager),
            address(hook)
        );

        // Create pool key
        testPoolKey = PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(address(hook))
        });

        // Initialize pool at 1:1 price
        vm.prank(owner);
        hook.initializePool(testPoolKey, Constants.SQRT_PRICE_1_1, testFeeConfig, 0, true);

        // Seed LP across a wide range around tick 0
        _seedLP(testPoolKey, -600, 600, 1_000_000e18, 1_000_000e18);
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
    // Initialization
    // ══════════════════════════════════════════════════════════════════════

    function test_initializePool_succeeds() public view {
        // Verify slot0
        (uint160 sqrtPrice, int24 tick,,) = manager.getSlot0(testPoolKey.toId());
        assertEq(sqrtPrice, Constants.SQRT_PRICE_1_1);
        assertEq(tick, TickMath.getTickAtSqrtPrice(Constants.SQRT_PRICE_1_1));

        // Verify fee config
        (uint256 k, uint256 logK, uint24 optFee,, uint160 refPrice) = hook.feeConfig(testPoolKey.toId());
        assertEq(k, K);
        assertEq(logK, LOG_K);
        assertEq(optFee, OPTIMAL_FEE_E6);
        assertEq(refPrice, REFERENCE_SQRT_PRICE_X96);

        // Verify fee state initialized
        (uint256 decayingFee,, uint256 blockNum) = hook.feeState(testPoolKey.toId());
        assertEq(decayingFee, FeeCalculation.UNDEFINED_DECAYING_FEE_E12);
        assertGt(blockNum, 0);
    }

    function test_initializePool_onlyOwner() public {
        PoolKey memory key2 = PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: 10,
            hooks: IHooks(address(hook))
        });
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, address(this)));
        hook.initializePool(key2, Constants.SQRT_PRICE_1_1, testFeeConfig, 0, true);
    }

    function test_initializePool_revertsStaticFee() public {
        PoolKey memory key2 = PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: LPFeeLibrary.MAX_LP_FEE,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(address(hook))
        });
        vm.prank(owner);
        vm.expectRevert(
            abi.encodeWithSelector(StableStableQuoterHook.MustUseDynamicFee.selector, LPFeeLibrary.MAX_LP_FEE)
        );
        hook.initializePool(key2, Constants.SQRT_PRICE_1_1, testFeeConfig, 0, true);
    }

    function test_initializePool_revertsInvalidHookAddress() public {
        PoolKey memory key2 = PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(address(0))
        });
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(StableStableQuoterHook.InvalidHookAddress.selector, address(0)));
        hook.initializePool(key2, Constants.SQRT_PRICE_1_1, testFeeConfig, 0, true);
    }

    function test_directInitialize_revertsInvalidInitializer() public {
        PoolKey memory key2 = PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: 10,
            hooks: IHooks(address(hook))
        });
        vm.expectRevert(
            abi.encodeWithSelector(
                CustomRevert.WrappedError.selector,
                address(hook),
                IHooks.beforeInitialize.selector,
                abi.encodeWithSelector(StableStableQuoterHook.InvalidInitializer.selector, address(this)),
                abi.encodeWithSelector(Hooks.HookCallFailed.selector)
            )
        );
        manager.initialize(key2, Constants.SQRT_PRICE_1_1);
    }

    // ══════════════════════════════════════════════════════════════════════
    // Indicative Quotes
    // ══════════════════════════════════════════════════════════════════════

    function test_getIndicativeQuote_zeroForOne() public view {
        // At reference price, fee = OPTIMAL_FEE_E6 = 90 pips (0.009%)
        uint256 output = hook.getIndicativeQuote(testPoolKey, true, -1e18, "");
        assertGt(output, 0);
        // ~0.99991e18 output with minimal price impact
        assertApproxEqRel(output, 0.99991e18, 0.001e18);
    }

    function test_getIndicativeQuote_oneForZero() public view {
        uint256 output = hook.getIndicativeQuote(testPoolKey, false, -1e18, "");
        assertGt(output, 0);
        assertApproxEqRel(output, 0.99991e18, 0.001e18);
    }

    function test_getIndicativeQuote_unlivePool_returnsZero() public {
        vm.prank(owner);
        hook.setPoolLive(testPoolKey, false);

        uint256 output = hook.getIndicativeQuote(testPoolKey, true, -1e18, "");
        assertEq(output, 0);
    }

    function test_getIndicativeQuote_withAttestation() public {
        // Set attested discount
        vm.prank(owner);
        hook.updatePoolConfig(testPoolKey, testFeeConfig, 50, true); // 50 bps = 0.5%

        Attestation memory att = Attestation({
            attester: attester,
            swapper: makeAddr("swapper"),
            deadline: block.timestamp + 1 hours,
            swapHash: keccak256("test")
        });
        bytes memory attestationData = MockAttestationSigner.sign(vm, attesterPk, att, address(attestationRegistry));
        bytes memory hookData = abi.encode(ALFHookData({attestationData: attestationData, curveUpdateData: ""}));

        uint256 baseOutput = hook.getIndicativeQuote(testPoolKey, true, -1e18, "");
        uint256 attestedOutput = hook.getIndicativeQuote(testPoolKey, true, -1e18, hookData);

        // Attested output should be ~0.5% better
        assertGt(attestedOutput, baseOutput);
        assertApproxEqRel(attestedOutput, baseOutput * 10_050 / 10_000, 0.001e18);
    }

    function test_getIndicativeQuote_matchesSwapExecution() public {
        // At reference price, first swap — fee state is pristine, outputs should match
        uint256 indicative = hook.getIndicativeQuote(testPoolKey, true, -1e18, "");

        BalanceDelta delta = swap(testPoolKey, true, -1e18, "");
        uint256 actual = uint256(int256(delta.amount1()));

        assertEq(indicative, actual);
    }

    // ══════════════════════════════════════════════════════════════════════
    // Dynamic Fee Execution (beforeSwap)
    // ══════════════════════════════════════════════════════════════════════

    function test_beforeSwap_atReferencePrice_chargesOptimalFee() public {
        BalanceDelta delta = swap(testPoolKey, true, -1e18, "");
        assertEq(delta.amount0(), -1e18);
        uint256 output = uint256(int256(delta.amount1()));
        // 90 pips = 0.009% fee → ~0.99991e18
        assertApproxEqRel(output, 0.99991e18, 0.001e18);
    }

    function test_beforeSwap_symmetricFeeAtReference() public {
        // Both swap directions should have the same fee at exact reference price
        BalanceDelta deltaZFO = swap(testPoolKey, true, -1e18, "");
        uint256 outputZFO = uint256(int256(deltaZFO.amount1()));

        // Reset state — use a fresh pool to avoid state-dependent fee changes
        PoolKey memory key2 = PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: 10,
            hooks: IHooks(address(hook))
        });
        vm.prank(owner);
        hook.initializePool(key2, Constants.SQRT_PRICE_1_1, testFeeConfig, 0, true);
        _seedLP(key2, -600, 600, 1_000_000e18, 1_000_000e18);

        BalanceDelta deltaOFZ = swap(key2, false, -1e18, "");
        uint256 outputOFZ = uint256(int256(deltaOFZ.amount0()));

        // Outputs should be approximately equal (both 90 pips fee at reference)
        assertApproxEqRel(outputZFO, outputOFZ, 0.001e18);
    }

    function test_beforeSwap_directionDependent_outsideOptimalRange() public {
        // Push price below reference with a large swap
        swap(testPoolKey, true, -50_000e18, "");

        // Now price is below reference. In the outside-optimal-range regime:
        // zeroForOne (pushing further away) → 0 fee
        // oneForZero (pushing toward reference) → decaying fee > 0

        // Verify zeroForOne quote matches a zero-fee simulation (fee = 0)
        uint256 quoteZFO = hook.getIndicativeQuote(testPoolKey, true, -1e18, "");
        uint256 zeroFeeZFO = SwapSimulator.simulateSwap(manager, testPoolKey.toId(), true, -1e18, 0, TICK_SPACING);
        assertEq(quoteZFO, zeroFeeZFO);

        // Verify oneForZero quote is less than zero-fee simulation (fee > 0)
        uint256 quoteOFZ = hook.getIndicativeQuote(testPoolKey, false, -1e18, "");
        uint256 zeroFeeOFZ = SwapSimulator.simulateSwap(manager, testPoolKey.toId(), false, -1e18, 0, TICK_SPACING);
        assertLt(quoteOFZ, zeroFeeOFZ);
    }

    function test_beforeSwap_unlivePool_noFeeOverride() public {
        vm.prank(owner);
        hook.setPoolLive(testPoolKey, false);

        BalanceDelta delta = swap(testPoolKey, true, -1e18, "");
        uint256 output = uint256(int256(delta.amount1()));
        // No fee → output ≈ input
        assertApproxEqRel(output, 1e18, 0.005e18);
    }

    function test_beforeSwap_exactOutput() public {
        BalanceDelta delta = swap(testPoolKey, true, 0.5e18, "");
        assertEq(delta.amount1(), int128(0.5e18));
        int128 input = delta.amount0();
        assertTrue(input < 0);
        // With 90 pips fee, input ≈ -0.50004e18
        assertApproxEqRel(uint256(int256(-input)), 0.50005e18, 0.001e18);
    }

    // ══════════════════════════════════════════════════════════════════════
    // Curve Updates via hookData (EIP-712 Signed)
    // ══════════════════════════════════════════════════════════════════════

    uint256 priceSignerPk;
    address priceSignerAddr;

    function _setupPriceSigner() internal {
        (priceSignerAddr, priceSignerPk) = makeAddrAndKey("priceSigner");
        vm.prank(owner);
        hook.setPriceSigner(priceSignerAddr);
    }

    function _signStableCurveUpdate(
        StableStableQuoterHook.StableCurveUpdate memory update,
        PoolId poolId,
        uint256 deadline,
        uint256 signerPk
    ) internal view returns (bytes memory sig) {
        bytes32 TYPEHASH = keccak256(
            "StableCurveUpdate(uint24 k,uint24 logK,uint24 optimalFeeE6,uint160 referenceSqrtPriceX96,uint16 attestedDiscountBps,bool live,bytes32 poolId,uint256 deadline)"
        );
        bytes32 structHash = keccak256(
            abi.encode(
                TYPEHASH,
                update.feeConfig.k,
                update.feeConfig.logK,
                update.feeConfig.optimalFeeE6,
                update.feeConfig.referenceSqrtPriceX96,
                update.attestedDiscountBps,
                update.live,
                PoolId.unwrap(poolId),
                deadline
            )
        );
        bytes32 domainSeparator = keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256("StableStableQuoterHook"),
                keccak256("1"),
                block.chainid,
                address(hook)
            )
        );
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", domainSeparator, structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(signerPk, digest);
        sig = abi.encodePacked(r, s, v);
    }

    function _buildCurveUpdateHookData(
        StableStableQuoterHook.StableCurveUpdate memory update,
        PoolId poolId,
        uint256 deadline,
        uint256 signerPk
    ) internal view returns (bytes memory hookData) {
        bytes memory sig = _signStableCurveUpdate(update, poolId, deadline, signerPk);
        bytes memory curveUpdateData = abi.encode(update, poolId, deadline, sig);
        hookData = abi.encode(ALFHookData({attestationData: "", curveUpdateData: curveUpdateData}));
    }

    function test_hookDataCurveUpdate_appliesNewConfig() public {
        _setupPriceSigner();

        // Increase fee from 90 pips to 10_000 pips (1%)
        StableStableQuoterHook.StableCurveUpdate memory update = StableStableQuoterHook.StableCurveUpdate({
            feeConfig: FeeConfig({
                k: K, logK: LOG_K, optimalFeeE6: 10_000, targetMultiplier: 0, referenceSqrtPriceX96: REFERENCE_SQRT_PRICE_X96
            }),
            attestedDiscountBps: 0,
            live: true
        });

        bytes memory hookData =
            _buildCurveUpdateHookData(update, testPoolKey.toId(), block.timestamp + 1 hours, priceSignerPk);
        BalanceDelta delta = swap(testPoolKey, true, -1e18, hookData);

        uint256 output = uint256(int256(delta.amount1()));
        // 1% fee → ~0.99e18 output
        assertApproxEqRel(output, 0.99e18, 0.01e18);
    }

    function test_hookDataCurveUpdate_sameBlockSameData_succeeds() public {
        _setupPriceSigner();

        StableStableQuoterHook.StableCurveUpdate memory update = StableStableQuoterHook.StableCurveUpdate({
            feeConfig: FeeConfig({
                k: K, logK: LOG_K, optimalFeeE6: 10_000, targetMultiplier: 0, referenceSqrtPriceX96: REFERENCE_SQRT_PRICE_X96
            }),
            attestedDiscountBps: 0,
            live: true
        });

        bytes memory hookData =
            _buildCurveUpdateHookData(update, testPoolKey.toId(), block.timestamp + 1 hours, priceSignerPk);

        swap(testPoolKey, true, -1e18, hookData);
        // Same data in same block → no-op, should succeed
        BalanceDelta delta = swap(testPoolKey, true, -1e18, hookData);
        uint256 output = uint256(int256(delta.amount1()));
        assertGt(output, 0);
    }

    function test_hookDataCurveUpdate_conflictingReverts() public {
        _setupPriceSigner();

        StableStableQuoterHook.StableCurveUpdate memory update1 = StableStableQuoterHook.StableCurveUpdate({
            feeConfig: FeeConfig({
                k: K, logK: LOG_K, optimalFeeE6: 10_000, targetMultiplier: 0, referenceSqrtPriceX96: REFERENCE_SQRT_PRICE_X96
            }),
            attestedDiscountBps: 0,
            live: true
        });
        bytes memory hookData1 =
            _buildCurveUpdateHookData(update1, testPoolKey.toId(), block.timestamp + 1 hours, priceSignerPk);
        swap(testPoolKey, true, -1e18, hookData1);

        // Different update in same block
        StableStableQuoterHook.StableCurveUpdate memory update2 = StableStableQuoterHook.StableCurveUpdate({
            feeConfig: FeeConfig({
                k: K, logK: LOG_K, optimalFeeE6: 20_000, targetMultiplier: 0, referenceSqrtPriceX96: REFERENCE_SQRT_PRICE_X96
            }),
            attestedDiscountBps: 0,
            live: true
        });
        bytes memory hookData2 =
            _buildCurveUpdateHookData(update2, testPoolKey.toId(), block.timestamp + 1 hours, priceSignerPk);

        vm.expectRevert();
        swap(testPoolKey, true, -1e18, hookData2);
    }

    function test_hookDataCurveUpdate_expiredReverts() public {
        _setupPriceSigner();

        StableStableQuoterHook.StableCurveUpdate memory update = StableStableQuoterHook.StableCurveUpdate({
            feeConfig: FeeConfig({
                k: K, logK: LOG_K, optimalFeeE6: 10_000, targetMultiplier: 0, referenceSqrtPriceX96: REFERENCE_SQRT_PRICE_X96
            }),
            attestedDiscountBps: 0,
            live: true
        });

        bytes memory hookData =
            _buildCurveUpdateHookData(update, testPoolKey.toId(), block.timestamp - 1, priceSignerPk);

        vm.expectRevert();
        swap(testPoolKey, true, -1e18, hookData);
    }

    function test_hookDataCurveUpdate_invalidSignerReverts() public {
        _setupPriceSigner();

        StableStableQuoterHook.StableCurveUpdate memory update = StableStableQuoterHook.StableCurveUpdate({
            feeConfig: FeeConfig({
                k: K, logK: LOG_K, optimalFeeE6: 10_000, targetMultiplier: 0, referenceSqrtPriceX96: REFERENCE_SQRT_PRICE_X96
            }),
            attestedDiscountBps: 0,
            live: true
        });

        (, uint256 wrongPk) = makeAddrAndKey("wrongSigner");
        bytes memory hookData =
            _buildCurveUpdateHookData(update, testPoolKey.toId(), block.timestamp + 1 hours, wrongPk);

        vm.expectRevert();
        swap(testPoolKey, true, -1e18, hookData);
    }

    function test_getIndicativeQuote_withCurveUpdate_usesNewConfig() public {
        _setupPriceSigner();

        StableStableQuoterHook.StableCurveUpdate memory update = StableStableQuoterHook.StableCurveUpdate({
            feeConfig: FeeConfig({
                k: K, logK: LOG_K, optimalFeeE6: 10_000, targetMultiplier: 0, referenceSqrtPriceX96: REFERENCE_SQRT_PRICE_X96
            }),
            attestedDiscountBps: 0,
            live: true
        });

        bytes memory sig = _signStableCurveUpdate(update, testPoolKey.toId(), block.timestamp + 1 hours, priceSignerPk);
        bytes memory curveUpdateData = abi.encode(update, testPoolKey.toId(), block.timestamp + 1 hours, sig);
        bytes memory hookData = abi.encode(ALFHookData({attestationData: "", curveUpdateData: curveUpdateData}));

        // With curve update: 1% fee
        uint256 outputWithUpdate = hook.getIndicativeQuote(testPoolKey, true, -1e18, hookData);
        // Without curve update: 0.009% fee (original config)
        uint256 outputWithout = hook.getIndicativeQuote(testPoolKey, true, -1e18, "");

        // Higher fee → less output
        assertLt(outputWithUpdate, outputWithout);
        assertApproxEqRel(outputWithUpdate, 0.99e18, 0.01e18);
        assertApproxEqRel(outputWithout, 0.99991e18, 0.001e18);
    }

    // ══════════════════════════════════════════════════════════════════════
    // Owner Functions
    // ══════════════════════════════════════════════════════════════════════

    function test_updatePoolConfig_changesConfig() public {
        FeeConfig memory newConfig =
            FeeConfig({k: K, logK: LOG_K, optimalFeeE6: 500, targetMultiplier: 0, referenceSqrtPriceX96: REFERENCE_SQRT_PRICE_X96});

        vm.prank(owner);
        hook.updatePoolConfig(testPoolKey, newConfig, 100, true);

        (,, uint24 optFee,,) = hook.feeConfig(testPoolKey.toId());
        assertEq(optFee, 500);
        assertEq(hook.attestedDiscountBps(testPoolKey.toId()), 100);
    }

    function test_updatePoolConfig_onlyOwner() public {
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, address(this)));
        hook.updatePoolConfig(testPoolKey, testFeeConfig, 0, true);
    }

    function test_setPoolLive_toggles() public {
        vm.prank(owner);
        hook.setPoolLive(testPoolKey, false);
        assertFalse(hook.poolLive(testPoolKey.toId()));

        vm.prank(owner);
        hook.setPoolLive(testPoolKey, true);
        assertTrue(hook.poolLive(testPoolKey.toId()));
    }

    function test_setPoolLive_onlyOwner() public {
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, address(this)));
        hook.setPoolLive(testPoolKey, false);
    }

    function test_setPriceSigner_succeeds() public {
        address newSigner = makeAddr("newSigner");
        vm.prank(owner);
        hook.setPriceSigner(newSigner);
        assertEq(hook.priceSigner(), newSigner);
    }

    function test_setPriceSigner_onlyOwner() public {
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, address(this)));
        hook.setPriceSigner(makeAddr("nobody"));
    }

    function test_isLive_alwaysTrue() public view {
        assertTrue(hook.isLive());
    }

    // ══════════════════════════════════════════════════════════════════════
    // FeeConfiguration configManager path
    // ══════════════════════════════════════════════════════════════════════

    function test_updateFeeConfig_viaConfigManager() public {
        FeeConfig memory newConfig =
            FeeConfig({k: K, logK: LOG_K, optimalFeeE6: 500, targetMultiplier: 0, referenceSqrtPriceX96: REFERENCE_SQRT_PRICE_X96});

        vm.prank(configManager);
        hook.updateFeeConfig(testPoolKey.toId(), newConfig);

        (,, uint24 optFee,,) = hook.feeConfig(testPoolKey.toId());
        assertEq(optFee, 500);
    }

    function test_updateFeeConfig_revertsNotConfigManager() public {
        vm.expectRevert();
        hook.updateFeeConfig(testPoolKey.toId(), testFeeConfig);
    }
}
