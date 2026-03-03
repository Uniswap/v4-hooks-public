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
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {Constants} from "@uniswap/v4-core/test/utils/Constants.sol";
import {CustomRevert} from "@uniswap/v4-core/src/libraries/CustomRevert.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {LiquidityAmounts} from "@uniswap/v4-core/test/utils/LiquidityAmounts.sol";
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {PropAMMAuctionHook} from "../../src/propamm/PropAMMAuctionHook.sol";
import {SimpleSpreadQuoterHook} from "../../src/propamm/SimpleSpreadQuoterHook.sol";
import {SpreadQuoterBase} from "../../src/propamm/base/SpreadQuoterBase.sol";
import {PropAMMIndex} from "../../src/propamm/PropAMMIndex.sol";
import {AttestationRegistry} from "../../src/propamm/AttestationRegistry.sol";
import {IPropAMMIndex, QuoterType} from "../../src/propamm/interfaces/IPropAMMIndex.sol";
import {IAttestationRegistry, Attestation} from "../../src/propamm/interfaces/IAttestationRegistry.sol";
import {MockAttestationSigner} from "./mocks/MockAttestationSigner.sol";
import {QuoterHookData} from "../../src/propamm/interfaces/IQuoterHook.sol";
import {AuctionHookData, TargetedQuoter} from "../../src/propamm/types/AuctionTypes.sol";

contract PropAMMAuctionHookTest is Test, Deployers {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;
    using StateLibrary for IPoolManager;

    PropAMMIndex public index;
    AttestationRegistry public attestationRegistry;
    PropAMMAuctionHook public auctionHook;

    SimpleSpreadQuoterHook public quoterA;
    SimpleSpreadQuoterHook public quoterB;

    address ownerA = makeAddr("ownerA");
    address ownerB = makeAddr("ownerB");
    uint256 attesterPk;
    address attester;

    PoolKey auctionPoolKey;
    PoolKey quoterAPoolKey;
    PoolKey quoterBPoolKey;

    function setUp() public {
        deployFreshManagerAndRouters();
        deployMintAndApprove2Currencies();

        index = new PropAMMIndex();
        attestationRegistry = new AttestationRegistry(ownerA);

        (attester, attesterPk) = makeAddrAndKey("attester");
        vm.prank(ownerA);
        attestationRegistry.addAttester(attester);

        // ── Deploy auction hook ──
        uint160 auctionFlags =
            uint160(Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG);
        auctionHook = PropAMMAuctionHook(
            address(uint160(uint256(type(uint160).max) & clearAllHookPermissionsMask | auctionFlags))
        );
        deployCodeTo("PropAMMAuctionHook", abi.encode(manager, address(index)), address(auctionHook));

        // ── Deploy quoters (native LP model with LP gating) ──
        uint160 quoterFlags = uint160(
            Hooks.AFTER_INITIALIZE_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG
                | Hooks.BEFORE_SWAP_FLAG
        );
        quoterA = SimpleSpreadQuoterHook(
            address(uint160(uint256(type(uint160).max) & clearAllHookPermissionsMask | quoterFlags))
        );
        deployCodeTo(
            "SimpleSpreadQuoterHook",
            abi.encode(manager, address(index), address(attestationRegistry), uint32(50_000), ownerA),
            address(quoterA)
        );

        quoterB = SimpleSpreadQuoterHook(
            address(uint160((uint256(type(uint160).max) - (1 << 14)) & clearAllHookPermissionsMask | quoterFlags))
        );
        deployCodeTo(
            "SimpleSpreadQuoterHook",
            abi.encode(manager, address(index), address(attestationRegistry), uint32(50_000), ownerB),
            address(quoterB)
        );

        // ── Create pool keys (dynamic fee for fee override) ──
        quoterAPoolKey = PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: 60,
            hooks: IHooks(address(quoterA))
        });

        quoterBPoolKey = PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: 60,
            hooks: IHooks(address(quoterB))
        });

        auctionPoolKey = PoolKey({
            currency0: currency0, currency1: currency1, fee: 0, tickSpacing: 1, hooks: IHooks(address(auctionHook))
        });

        // ── Initialize pools (quoters at tick 30 → inside LP range [0,60)) ──
        manager.initialize(quoterAPoolKey, TickMath.getSqrtPriceAtTick(30));
        manager.initialize(quoterBPoolKey, TickMath.getSqrtPriceAtTick(30));
        manager.initialize(auctionPoolKey, Constants.SQRT_PRICE_1_1);

        // ── Authorize LP router and seed at active tick ──
        vm.prank(ownerA);
        quoterA.setAuthorizedLP(address(modifyLiquidityRouter), true);
        vm.prank(ownerB);
        quoterB.setAuthorizedLP(address(modifyLiquidityRouter), true);

        _seedAtActiveTick(quoterAPoolKey, quoterA, 10_000e18, 10_000e18);
        _seedAtActiveTick(quoterBPoolKey, quoterB, 10_000e18, 10_000e18);

        // ── Set pricing: asymmetric fees create directional winners ──
        // A: expensive bid (5%), cheap ask (1%)
        vm.prank(ownerA);
        quoterA.updatePricingState(
            quoterAPoolKey,
            SpreadQuoterBase.PricingState({
                bidFeePips: 50_000, // 5%
                askFeePips: 10_000, // 1%
                attestedDiscountBps: 5,
                live: true
            })
        );
        // B: cheap bid (1%), expensive ask (5%)
        vm.prank(ownerB);
        quoterB.updatePricingState(
            quoterBPoolKey,
            SpreadQuoterBase.PricingState({
                bidFeePips: 10_000, // 1%
                askFeePips: 50_000, // 5%
                attestedDiscountBps: 0,
                live: true
            })
        );
    }

    // ──── Helpers ────

    function _seedAtActiveTick(PoolKey memory key_, SpreadQuoterBase quoter, uint256 amount0, uint256 amount1)
        internal
    {
        int24 activeTick = quoter.activeLowerTick(key_.toId());
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

    // ──── Auction selects best quoter ────

    function test_selectsBetterQuoter_zeroForOne() public {
        // B has lower bidFee (1% vs 5%) → B wins auction
        // Execution goes through B's AMM with 1% fee
        BalanceDelta delta = swap(auctionPoolKey, true, -1e18, "");

        assertEq(delta.amount0(), -1e18);
        int128 output = delta.amount1();
        assertTrue(output > 0);
        // B's 1% fee → ~0.99e18 output
        assertApproxEqRel(uint256(int256(output)), 0.99e18, 0.01e18);
    }

    function test_selectsBetterQuoter_oneForZero() public {
        // A has lower askFee (1% vs 5%) → A wins auction
        // Execution goes through A's AMM with 1% fee
        BalanceDelta delta = swap(auctionPoolKey, false, -1e18, "");

        int128 output = delta.amount0();
        assertTrue(output > 0);
        assertEq(delta.amount1(), -1e18);
        // A's 1% fee → ~0.99e18 output
        assertApproxEqRel(uint256(int256(output)), 0.99e18, 0.01e18);
    }

    // ──── Skips failed quoters ────

    function test_skipsUnliveQuoter_routesToLiveOne() public {
        // Turn off B (the better quoter for zeroForOne bid)
        vm.prank(ownerB);
        quoterB.setPoolLive(quoterBPoolKey, false);

        BalanceDelta delta = swap(auctionPoolKey, true, -1e18, "");

        assertEq(delta.amount0(), -1e18);
        int128 output = delta.amount1();
        assertTrue(output > 0);
        // Falls back to A with 5% bidFee → ~0.95e18
        assertApproxEqRel(uint256(int256(output)), 0.95e18, 0.01e18);
    }

    // ──── No valid quotes ────

    function test_revertsWhenNoLiveQuoters() public {
        vm.prank(ownerA);
        quoterA.setPoolLive(quoterAPoolKey, false);
        vm.prank(ownerB);
        quoterB.setPoolLive(quoterBPoolKey, false);

        vm.expectRevert(
            abi.encodeWithSelector(
                CustomRevert.WrappedError.selector,
                address(auctionHook),
                IHooks.beforeSwap.selector,
                abi.encodeWithSelector(PropAMMAuctionHook.NoValidQuotes.selector),
                abi.encodeWithSelector(Hooks.HookCallFailed.selector)
            )
        );
        swap(auctionPoolKey, true, -1e18, "");
    }

    // ──── Delta forwarding correctness ────

    function test_deltaForwarding_exactInput() public {
        MockERC20 token0 = MockERC20(Currency.unwrap(currency0));
        MockERC20 token1 = MockERC20(Currency.unwrap(currency1));

        uint256 userBal0Before = token0.balanceOf(address(this));
        uint256 userBal1Before = token1.balanceOf(address(this));

        BalanceDelta delta = swap(auctionPoolKey, true, -1e18, "");

        // User paid exactly 1e18 token0
        assertEq(token0.balanceOf(address(this)), userBal0Before - 1e18);

        // User received output token1 (B wins with 1% bidFee)
        uint256 received = token1.balanceOf(address(this)) - userBal1Before;
        assertApproxEqRel(received, 0.99e18, 0.01e18);

        assertEq(delta.amount0(), -1e18);
        assertApproxEqRel(uint256(int256(delta.amount1())), 0.99e18, 0.01e18);
    }

    function test_deltaForwarding_exactOutput() public {
        // Exact output: user wants 0.5e18 token1 via zeroForOne
        // For exact output, auction picks the quoter requiring the LEAST input.
        // B has lower bidFee (1% vs 5%) → requires less input → B wins
        BalanceDelta delta = swap(auctionPoolKey, true, 0.5e18, "");

        int128 output = delta.amount1();
        assertTrue(output > 0);
        // Should get approximately 0.5e18 token1
        assertApproxEqRel(uint256(int256(output)), 0.5e18, 0.02e18);
    }

    // ──── Blocks liquidity on virtual pool ────

    function test_blocksLiquidity() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                CustomRevert.WrappedError.selector,
                address(auctionHook),
                IHooks.beforeAddLiquidity.selector,
                abi.encodeWithSelector(PropAMMAuctionHook.LiquidityNotAllowed.selector),
                abi.encodeWithSelector(Hooks.HookCallFailed.selector)
            )
        );
        modifyLiquidityRouter.modifyLiquidity(
            auctionPoolKey, ModifyLiquidityParams({tickLower: -60, tickUpper: 60, liquidityDelta: 1e18, salt: 0}), ""
        );
    }

    // ──── Attestation flows through to winner ────

    function test_attestationForwardsToWinner() public {
        Attestation memory att = Attestation({
            attester: attester,
            swapper: address(swapRouter),
            deadline: block.timestamp + 1 hours,
            swapHash: keccak256("test")
        });
        bytes memory attestationData = MockAttestationSigner.sign(vm, attesterPk, att, address(attestationRegistry));
        bytes memory hookData =
            abi.encode(
                AuctionHookData({attestationData: attestationData, targets: new TargetedQuoter[](0), strict: false})
            );

        // A's 5% bidFee simulation ≈ 0.95, +5bps attestation → ~0.9505
        // B's 1% bidFee simulation ≈ 0.99, no discount → 0.99
        // B still wins on indicative → nested swap goes through B's pool (1% fee)
        BalanceDelta delta = swap(auctionPoolKey, true, -1e18, hookData);

        assertEq(delta.amount0(), -1e18);
        assertApproxEqRel(uint256(int256(delta.amount1())), 0.99e18, 0.01e18);
    }

    // ──── Event emission ────

    function test_emitsAuctionExecuted() public {
        // B wins with lower bidFee (1%) for zeroForOne
        vm.expectEmit(true, false, false, false); // only check winner address
        emit PropAMMAuctionHook.AuctionExecuted(address(quoterB), true, -1e18, 0);
        swap(auctionPoolKey, true, -1e18, "");
    }

    // ════════════════════════════════════════════
    //  Targeted Mode
    // ════════════════════════════════════════════

    function _buildTargetedHookData(TargetedQuoter[] memory targets) internal pure returns (bytes memory) {
        return abi.encode(AuctionHookData({attestationData: "", targets: targets, strict: false}));
    }

    function _buildTargetedHookDataWithAttestation(bytes memory attestationData, TargetedQuoter[] memory targets)
        internal
        pure
        returns (bytes memory)
    {
        return abi.encode(AuctionHookData({attestationData: attestationData, targets: targets, strict: false}));
    }

    function test_targeted_selectsBetterQuoter() public {
        // Target both quoters — B should win for zeroForOne (1% vs 5% bid fee)
        TargetedQuoter[] memory targets = new TargetedQuoter[](2);
        targets[0] = TargetedQuoter({poolKey: quoterAPoolKey, curveUpdateData: ""});
        targets[1] = TargetedQuoter({poolKey: quoterBPoolKey, curveUpdateData: ""});

        BalanceDelta delta = swap(auctionPoolKey, true, -1e18, _buildTargetedHookData(targets));

        assertEq(delta.amount0(), -1e18);
        int128 output = delta.amount1();
        assertTrue(output > 0);
        // B's 1% fee → ~0.99e18 output
        assertApproxEqRel(uint256(int256(output)), 0.99e18, 0.01e18);
    }

    function test_targeted_singleQuoter() public {
        // Target only A for zeroForOne — A executes with its 5% bidFee
        TargetedQuoter[] memory targets = new TargetedQuoter[](1);
        targets[0] = TargetedQuoter({poolKey: quoterAPoolKey, curveUpdateData: ""});

        BalanceDelta delta = swap(auctionPoolKey, true, -1e18, _buildTargetedHookData(targets));

        assertEq(delta.amount0(), -1e18);
        int128 output = delta.amount1();
        assertTrue(output > 0);
        // A's 5% bidFee → ~0.95e18
        assertApproxEqRel(uint256(int256(output)), 0.95e18, 0.01e18);
    }

    function test_targeted_skipsUnliveQuoter() public {
        // Set B to unlive, target both — A should win
        vm.prank(ownerB);
        quoterB.setPoolLive(quoterBPoolKey, false);

        TargetedQuoter[] memory targets = new TargetedQuoter[](2);
        targets[0] = TargetedQuoter({poolKey: quoterAPoolKey, curveUpdateData: ""});
        targets[1] = TargetedQuoter({poolKey: quoterBPoolKey, curveUpdateData: ""});

        BalanceDelta delta = swap(auctionPoolKey, true, -1e18, _buildTargetedHookData(targets));

        assertEq(delta.amount0(), -1e18);
        int128 output = delta.amount1();
        assertTrue(output > 0);
        // Falls back to A with 5% bidFee → ~0.95e18
        assertApproxEqRel(uint256(int256(output)), 0.95e18, 0.01e18);
    }

    function test_targeted_revertsWhenAllTargetsInvalid() public {
        vm.prank(ownerA);
        quoterA.setPoolLive(quoterAPoolKey, false);
        vm.prank(ownerB);
        quoterB.setPoolLive(quoterBPoolKey, false);

        TargetedQuoter[] memory targets = new TargetedQuoter[](2);
        targets[0] = TargetedQuoter({poolKey: quoterAPoolKey, curveUpdateData: ""});
        targets[1] = TargetedQuoter({poolKey: quoterBPoolKey, curveUpdateData: ""});

        vm.expectRevert(
            abi.encodeWithSelector(
                CustomRevert.WrappedError.selector,
                address(auctionHook),
                IHooks.beforeSwap.selector,
                abi.encodeWithSelector(PropAMMAuctionHook.NoValidQuotes.selector),
                abi.encodeWithSelector(Hooks.HookCallFailed.selector)
            )
        );
        swap(auctionPoolKey, true, -1e18, _buildTargetedHookData(targets));
    }

    function test_targeted_withAttestation() public {
        Attestation memory att = Attestation({
            attester: attester,
            swapper: address(swapRouter),
            deadline: block.timestamp + 1 hours,
            swapHash: keccak256("test")
        });
        bytes memory attestationData = MockAttestationSigner.sign(vm, attesterPk, att, address(attestationRegistry));

        TargetedQuoter[] memory targets = new TargetedQuoter[](2);
        targets[0] = TargetedQuoter({poolKey: quoterAPoolKey, curveUpdateData: ""});
        targets[1] = TargetedQuoter({poolKey: quoterBPoolKey, curveUpdateData: ""});

        // A: 5% bidFee ≈ 0.95 + 5bps → ~0.9505; B: 1% bidFee ≈ 0.99, no discount → 0.99
        // B still wins → nested swap through B at 1%
        BalanceDelta delta =
            swap(auctionPoolKey, true, -1e18, _buildTargetedHookDataWithAttestation(attestationData, targets));

        assertEq(delta.amount0(), -1e18);
        assertApproxEqRel(uint256(int256(delta.amount1())), 0.99e18, 0.01e18);
    }

    // ──── Targeted with curve update ────

    bytes32 private constant PRICING_UPDATE_TYPEHASH = keccak256(
        "PricingUpdate(uint24 bidFeePips,uint24 askFeePips,uint16 attestedDiscountBps,bool live,bytes32 poolId,uint256 deadline)"
    );

    function _signPricingUpdate(
        SpreadQuoterBase.PricingState memory state,
        PoolId poolId,
        uint256 deadline,
        uint256 signerPk,
        address quoter
    ) internal view returns (bytes memory sig) {
        bytes32 structHash = keccak256(
            abi.encode(
                PRICING_UPDATE_TYPEHASH,
                state.bidFeePips,
                state.askFeePips,
                state.attestedDiscountBps,
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
                quoter
            )
        );
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", domainSeparator, structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(signerPk, digest);
        sig = abi.encodePacked(r, s, v);
    }

    function _buildCurveUpdateData(
        SpreadQuoterBase.PricingState memory state,
        PoolKey memory poolKey_,
        uint256 deadline,
        uint256 signerPk,
        address quoter
    ) internal view returns (bytes memory) {
        bytes memory sig = _signPricingUpdate(state, poolKey_.toId(), deadline, signerPk, quoter);
        return abi.encode(state, poolKey_.toId(), deadline, sig);
    }

    function test_targeted_curveUpdate_flipsWinner() public {
        // A normally has 5% bidFee (loses to B's 1% for zeroForOne).
        // Send a targeted curve update giving A a 0.5% bidFee → A should now win.
        (address priceSignerA, uint256 priceSignerAPk) = makeAddrAndKey("priceSignerA");
        vm.prank(ownerA);
        quoterA.setPriceSigner(priceSignerA);

        SpreadQuoterBase.PricingState memory newStateA = SpreadQuoterBase.PricingState({
            bidFeePips: 5_000, // 0.5%
            askFeePips: 10_000,
            attestedDiscountBps: 0,
            live: true
        });

        bytes memory curveUpdateA = _buildCurveUpdateData(
            newStateA, quoterAPoolKey, block.timestamp + 1 hours, priceSignerAPk, address(quoterA)
        );

        TargetedQuoter[] memory targets = new TargetedQuoter[](2);
        targets[0] = TargetedQuoter({poolKey: quoterAPoolKey, curveUpdateData: curveUpdateA});
        targets[1] = TargetedQuoter({poolKey: quoterBPoolKey, curveUpdateData: ""});

        BalanceDelta delta = swap(auctionPoolKey, true, -1e18, _buildTargetedHookData(targets));

        assertEq(delta.amount0(), -1e18);
        int128 output = delta.amount1();
        assertTrue(output > 0);
        // A wins with 0.5% fee → ~0.995e18 (better than B's ~0.99e18)
        assertApproxEqRel(uint256(int256(output)), 0.995e18, 0.01e18);
    }

    function test_targeted_curveUpdate_appliedOnNestedSwap() public {
        // Verify the curve update is actually persisted via the nested swap
        (address priceSignerA, uint256 priceSignerAPk) = makeAddrAndKey("priceSignerA");
        vm.prank(ownerA);
        quoterA.setPriceSigner(priceSignerA);

        SpreadQuoterBase.PricingState memory newStateA = SpreadQuoterBase.PricingState({
            bidFeePips: 5_000, // 0.5%
            askFeePips: 10_000,
            attestedDiscountBps: 0,
            live: true
        });

        bytes memory curveUpdateA = _buildCurveUpdateData(
            newStateA, quoterAPoolKey, block.timestamp + 1 hours, priceSignerAPk, address(quoterA)
        );

        // Target only A so it's the winner
        TargetedQuoter[] memory targets = new TargetedQuoter[](1);
        targets[0] = TargetedQuoter({poolKey: quoterAPoolKey, curveUpdateData: curveUpdateA});

        swap(auctionPoolKey, true, -1e18, _buildTargetedHookData(targets));

        // After the nested swap, A's stored pricing should be updated
        (uint24 bidFeePips,,,) = quoterA.pricingState(quoterAPoolKey.toId());
        assertEq(bidFeePips, 5_000);
    }

    function test_targeted_emitsAuctionExecutedWithWinner() public {
        TargetedQuoter[] memory targets = new TargetedQuoter[](2);
        targets[0] = TargetedQuoter({poolKey: quoterAPoolKey, curveUpdateData: ""});
        targets[1] = TargetedQuoter({poolKey: quoterBPoolKey, curveUpdateData: ""});

        // B wins with lower bidFee (1%) for zeroForOne
        vm.expectEmit(true, false, false, false);
        emit PropAMMAuctionHook.AuctionExecuted(address(quoterB), true, -1e18, 0);
        swap(auctionPoolKey, true, -1e18, _buildTargetedHookData(targets));
    }

    // ════════════════════════════════════════════
    //  Strict Mode
    // ════════════════════════════════════════════

    function _buildStrictHookData(TargetedQuoter[] memory targets) internal pure returns (bytes memory) {
        return abi.encode(AuctionHookData({attestationData: "", targets: targets, strict: true}));
    }

    function test_strict_passesWhenQuoteMatchesExecution() public {
        TargetedQuoter[] memory targets = new TargetedQuoter[](2);
        targets[0] = TargetedQuoter({poolKey: quoterAPoolKey, curveUpdateData: ""});
        targets[1] = TargetedQuoter({poolKey: quoterBPoolKey, curveUpdateData: ""});

        // Strict mode should pass — spread quoter's indicative matches execution exactly
        BalanceDelta delta = swap(auctionPoolKey, true, -1e18, _buildStrictHookData(targets));
        assertEq(delta.amount0(), -1e18);
        assertTrue(delta.amount1() > 0);
    }

    function test_strict_passesDiscoveryWithEmptyHookData() public {
        // Discovery mode with strict — no hookData means strict=false (default), should work
        BalanceDelta delta = swap(auctionPoolKey, true, -1e18, "");
        assertEq(delta.amount0(), -1e18);
        assertTrue(delta.amount1() > 0);
    }

    function test_strict_exactOutput() public {
        TargetedQuoter[] memory targets = new TargetedQuoter[](1);
        targets[0] = TargetedQuoter({poolKey: quoterBPoolKey, curveUpdateData: ""});

        // Exact output with strict mode
        BalanceDelta delta = swap(auctionPoolKey, true, 0.5e18, _buildStrictHookData(targets));
        assertEq(delta.amount1(), int128(0.5e18));
        assertTrue(delta.amount0() < 0);
    }
}
