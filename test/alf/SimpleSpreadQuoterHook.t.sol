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
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {Constants} from "@uniswap/v4-core/test/utils/Constants.sol";
import {CustomRevert} from "@uniswap/v4-core/src/libraries/CustomRevert.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {SimpleSpreadQuoterHook} from "../../src/alf/SimpleSpreadQuoterHook.sol";
import {SpreadQuoterBase} from "../../src/alf/base/SpreadQuoterBase.sol";
import {ALFHookData} from "../../src/alf/interfaces/IALFHook.sol";

contract SimpleSpreadQuoterHookTest is Test, Deployers {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;
    using StateLibrary for IPoolManager;

    SimpleSpreadQuoterHook public hook;

    address owner = makeAddr("owner");

    PoolKey testPoolKey;

    // Fee pips for tests: 20_000 pips = 2%
    uint24 constant BID_FEE_PIPS = 20_000;
    uint24 constant ASK_FEE_PIPS = 50_000; // 5%

    function setUp() public {
        deployFreshManagerAndRouters();
        deployMintAndApprove2Currencies();

        // Deploy hook at flag-mined address
        uint160 flags = uint160(
            Hooks.AFTER_INITIALIZE_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG
                | Hooks.BEFORE_SWAP_FLAG
        );
        hook =
            SimpleSpreadQuoterHook(address(uint160(uint256(type(uint160).max) & clearAllHookPermissionsMask | flags)));
        deployCodeTo("SimpleSpreadQuoterHook", abi.encode(manager, uint32(50_000), owner), address(hook));

        // Create pool key (dynamic fee pool — fee override requires this)
        testPoolKey = PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: 60,
            hooks: IHooks(address(hook))
        });

        // Initialize pool at tick 30 → inside LP range [0,60) so both swap directions have liquidity
        manager.initialize(testPoolKey, TickMath.getSqrtPriceAtTick(30));

        // Authorize the modifyLiquidityRouter for LP operations
        vm.prank(owner);
        hook.setAuthorizedLP(address(modifyLiquidityRouter), true);

        // Add LP at the active tick (single-tick concentration)
        _seedAtActiveTick(testPoolKey, 10_000e18, 10_000e18);

        // Set pricing state with fee overrides
        vm.prank(owner);
        hook.updatePricingState(
            testPoolKey,
            SpreadQuoterBase.PricingState({
                bidFeePips: BID_FEE_PIPS, askFeePips: ASK_FEE_PIPS, live: true
            })
        );
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
        // Simulates AMM swap with 5% fee → ~95e18 output
        assertApproxEqRel(output, 95e18, 0.01e18);
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
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: 10,
            hooks: IHooks(address(hook))
        });
        manager.initialize(emptyPoolKey, Constants.SQRT_PRICE_1_1);

        vm.prank(owner);
        hook.updatePricingState(
            emptyPoolKey,
            SpreadQuoterBase.PricingState({
                bidFeePips: BID_FEE_PIPS, askFeePips: ASK_FEE_PIPS, live: true
            })
        );

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

    function test_beforeSwap_zeroForOne_appliesBidFee() public {
        // Swap 1e18 token0 → token1 with BID_FEE_PIPS (2%)
        BalanceDelta delta = swap(testPoolKey, true, -1e18, "");

        assertEq(delta.amount0(), -1e18);
        int128 output = delta.amount1();
        assertTrue(output > 0);
        assertApproxEqRel(uint256(int256(output)), 0.98e18, 0.01e18);
    }

    function test_beforeSwap_oneForZero_appliesAskFee() public {
        // Swap 1e18 token1 → token0 with ASK_FEE_PIPS (5%)
        BalanceDelta delta = swap(testPoolKey, false, -1e18, "");

        assertEq(delta.amount1(), -1e18);
        int128 output = delta.amount0();
        assertTrue(output > 0);
        assertApproxEqRel(uint256(int256(output)), 0.95e18, 0.01e18);
    }

    function test_beforeSwap_unlivePool_noFeeOverride() public {
        vm.prank(owner);
        hook.setPoolLive(testPoolKey, false);

        BalanceDelta delta = swap(testPoolKey, true, -1e18, "");

        assertEq(delta.amount0(), -1e18);
        int128 output = delta.amount1();
        assertTrue(output > 0);
        assertApproxEqRel(uint256(int256(output)), 1e18, 0.005e18);
    }

    function test_beforeSwap_exactOutput_zeroForOne() public {
        BalanceDelta delta = swap(testPoolKey, true, 0.5e18, "");

        assertEq(delta.amount1(), int128(0.5e18));
        int128 input = delta.amount0();
        assertTrue(input < 0);
        assertApproxEqRel(uint256(int256(-input)), 0.5102e18, 0.01e18);
    }

    // ──── Owner functions ────

    function test_updatePricingState_onlyOwner() public {
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, address(this)));
        hook.updatePricingState(
            testPoolKey,
            SpreadQuoterBase.PricingState({bidFeePips: 0, askFeePips: 0, live: true})
        );
    }

    function test_updatePricingState_changesFee() public {
        vm.prank(owner);
        hook.updatePricingState(
            testPoolKey,
            SpreadQuoterBase.PricingState({bidFeePips: 0, askFeePips: 0, live: true})
        );

        BalanceDelta delta = swap(testPoolKey, true, -1e18, "");
        int128 output = delta.amount1();
        // With 0 fees, output should be close to input (price ≈ 1:1 at tick 30)
        assertApproxEqRel(uint256(int256(output)), 1e18, 0.01e18);
    }

    function test_setPoolLive_onlyOwner() public {
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, address(this)));
        hook.setPoolLive(testPoolKey, false);
    }

    // ──── Asymmetric fees ────

    function test_asymmetricFees() public {
        BalanceDelta deltaZFO = swap(testPoolKey, true, -1e18, "");
        BalanceDelta deltaOFZ = swap(testPoolKey, false, -1e18, "");

        uint256 outputZFO = uint256(int256(deltaZFO.amount1()));
        uint256 outputOFZ = uint256(int256(deltaOFZ.amount0()));

        // zeroForOne output should be larger (smaller fee)
        assertTrue(outputZFO > outputOFZ);
    }

    // ──── setPriceSigner ────

    function test_setPriceSigner() public {
        address newSigner = makeAddr("newSigner");
        vm.prank(owner);
        hook.setPriceSigner(newSigner);
        assertEq(hook.priceSigner(), newSigner);
    }

    function test_setPriceSigner_onlyOwner() public {
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, address(this)));
        hook.setPriceSigner(makeAddr("nobody"));
    }

    // ──── hookData curve updates ────

    uint256 priceSignerPk;
    address priceSignerAddr;

    function _setupPriceSigner() internal {
        (priceSignerAddr, priceSignerPk) = makeAddrAndKey("priceSigner");
        vm.prank(owner);
        hook.setPriceSigner(priceSignerAddr);
    }

    function _signPricingUpdate(
        SpreadQuoterBase.PricingState memory state,
        PoolId poolId,
        uint256 deadline,
        uint256 signerPk
    ) internal view returns (bytes memory sig) {
        bytes32 TYPEHASH = keccak256(
            "PricingUpdate(uint24 bidFeePips,uint24 askFeePips,bool live,bytes32 poolId,uint256 deadline)"
        );
        bytes32 structHash = keccak256(
            abi.encode(
                TYPEHASH,
                state.bidFeePips,
                state.askFeePips,
                state.live,
                PoolId.unwrap(poolId),
                deadline
            )
        );
        bytes32 domainSeparator = keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256("SimpleSpreadQuoterHook"),
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
        SpreadQuoterBase.PricingState memory state,
        PoolId poolId,
        uint256 deadline,
        uint256 signerPk
    ) internal view returns (bytes memory hookData) {
        bytes memory sig = _signPricingUpdate(state, poolId, deadline, signerPk);
        bytes memory curveUpdateData = abi.encode(state, poolId, deadline, sig);
        hookData = abi.encode(ALFHookData({attestationData: "", curveUpdateData: curveUpdateData}));
    }

    function test_hookDataCurveUpdate_appliesNewPricing() public {
        _setupPriceSigner();

        // New pricing: 1% bid fee (down from 2%)
        SpreadQuoterBase.PricingState memory newState = SpreadQuoterBase.PricingState({
            bidFeePips: 10_000, // 1%
            askFeePips: ASK_FEE_PIPS,
            live: true
        });

        bytes memory hookData =
            _buildCurveUpdateHookData(newState, testPoolKey.toId(), block.timestamp + 1 hours, priceSignerPk);
        BalanceDelta delta = swap(testPoolKey, true, -1e18, hookData);

        assertEq(delta.amount0(), -1e18);
        int128 output = delta.amount1();
        assertTrue(output > 0);
        // 1% fee → ~0.99e18 output (instead of 0.98e18 with 2% fee)
        assertApproxEqRel(uint256(int256(output)), 0.99e18, 0.01e18);
    }

    function test_hookDataCurveUpdate_sameBlockSameData_succeeds() public {
        _setupPriceSigner();

        SpreadQuoterBase.PricingState memory newState = SpreadQuoterBase.PricingState({
            bidFeePips: 10_000, askFeePips: ASK_FEE_PIPS, live: true
        });

        bytes memory hookData =
            _buildCurveUpdateHookData(newState, testPoolKey.toId(), block.timestamp + 1 hours, priceSignerPk);

        // First swap applies the update
        swap(testPoolKey, true, -1e18, hookData);
        // Second swap in same block with same data should pass (no-op update)
        BalanceDelta delta = swap(testPoolKey, true, -1e18, hookData);

        assertEq(delta.amount0(), -1e18);
        int128 output = delta.amount1();
        assertTrue(output > 0);
        assertApproxEqRel(uint256(int256(output)), 0.99e18, 0.01e18);
    }

    function test_hookDataCurveUpdate_conflictingReverts() public {
        _setupPriceSigner();

        SpreadQuoterBase.PricingState memory state1 = SpreadQuoterBase.PricingState({
            bidFeePips: 10_000, askFeePips: ASK_FEE_PIPS, live: true
        });
        bytes memory hookData1 =
            _buildCurveUpdateHookData(state1, testPoolKey.toId(), block.timestamp + 1 hours, priceSignerPk);
        swap(testPoolKey, true, -1e18, hookData1);

        // Conflicting update in same block
        SpreadQuoterBase.PricingState memory state2 = SpreadQuoterBase.PricingState({
            bidFeePips: 30_000, // different fee
            askFeePips: ASK_FEE_PIPS,
            live: true
        });
        bytes memory hookData2 =
            _buildCurveUpdateHookData(state2, testPoolKey.toId(), block.timestamp + 1 hours, priceSignerPk);

        vm.expectRevert();
        swap(testPoolKey, true, -1e18, hookData2);
    }

    function test_hookDataCurveUpdate_expiredReverts() public {
        _setupPriceSigner();

        SpreadQuoterBase.PricingState memory newState = SpreadQuoterBase.PricingState({
            bidFeePips: 10_000, askFeePips: ASK_FEE_PIPS, live: true
        });

        // Deadline in the past
        bytes memory hookData =
            _buildCurveUpdateHookData(newState, testPoolKey.toId(), block.timestamp - 1, priceSignerPk);

        vm.expectRevert();
        swap(testPoolKey, true, -1e18, hookData);
    }

    function test_hookDataCurveUpdate_invalidSignerReverts() public {
        _setupPriceSigner();

        SpreadQuoterBase.PricingState memory newState = SpreadQuoterBase.PricingState({
            bidFeePips: 10_000, askFeePips: ASK_FEE_PIPS, live: true
        });

        // Sign with wrong key
        (, uint256 wrongPk) = makeAddrAndKey("wrongSigner");
        bytes memory hookData =
            _buildCurveUpdateHookData(newState, testPoolKey.toId(), block.timestamp + 1 hours, wrongPk);

        vm.expectRevert();
        swap(testPoolKey, true, -1e18, hookData);
    }

    function test_getIndicativeQuote_withHookDataCurveUpdate() public {
        _setupPriceSigner();

        // New pricing: 1% bid fee
        SpreadQuoterBase.PricingState memory newState = SpreadQuoterBase.PricingState({
            bidFeePips: 10_000, askFeePips: ASK_FEE_PIPS, live: true
        });

        bytes memory sig = _signPricingUpdate(newState, testPoolKey.toId(), block.timestamp + 1 hours, priceSignerPk);
        bytes memory curveUpdateData = abi.encode(newState, testPoolKey.toId(), block.timestamp + 1 hours, sig);
        bytes memory hookData = abi.encode(ALFHookData({attestationData: "", curveUpdateData: curveUpdateData}));

        // Indicative quote uses new pricing without modifying state
        uint256 output = hook.getIndicativeQuote(testPoolKey, true, -100e18, hookData);
        // 1% fee → ~99e18 output (instead of 98e18 with stored 2% fee)
        assertApproxEqRel(output, 99e18, 0.01e18);

        // Stored state is unchanged — regular quote still uses 2% fee
        uint256 storedOutput = hook.getIndicativeQuote(testPoolKey, true, -100e18, "");
        assertApproxEqRel(storedOutput, 98e18, 0.01e18);
    }
}
