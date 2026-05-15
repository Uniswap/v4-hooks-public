// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {CustomRevert} from "@uniswap/v4-core/src/libraries/CustomRevert.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {NativeBookHook} from "../../src/alf/NativeBookHook.sol";

contract NativeBookHookTest is Test, Deployers {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    NativeBookHook public hook;
    MockERC20 token0;
    MockERC20 token1;

    address owner = makeAddr("owner");
    address maker;
    address maker2;
    address relayer = makeAddr("relayer");
    uint256 makerPk;
    uint256 maker2Pk;

    PoolKey testPoolKey;
    PoolId testPoolId;

    uint24 constant FEE_PIPS = 1_000;
    int24 constant TICK_SPACING = 10;
    int24 constant BIN_SPACING = 60;

    event PoolLivenessUpdated(PoolId indexed poolId, address indexed updater, bool oldLive, bool newLive);
    event InventoryDeposited(
        address indexed maker,
        address indexed currency,
        address indexed depositor,
        uint256 requestedAmount,
        uint256 amount
    );
    event InventoryWithdrawn(
        address indexed maker, address indexed currency, address indexed recipient, uint256 amount
    );
    event LadderReplaced(
        PoolId indexed poolId,
        address indexed maker,
        address indexed submitter,
        uint256 bidCount,
        uint256 askCount,
        uint40 expiry,
        uint256 nonce,
        uint256 deadline,
        bool viaSignature
    );
    event LadderCanceled(
        PoolId indexed poolId,
        address indexed maker,
        address indexed submitter,
        uint256 binsRemoved,
        uint256 amount0,
        uint256 amount1,
        uint256 nonce,
        uint256 deadline,
        bool viaSignature
    );
    event BinPosted(
        PoolId indexed poolId,
        address indexed maker,
        bytes32 indexed positionId,
        NativeBookHook.Side side,
        int24 tickLower,
        int24 tickUpper,
        int8 offset,
        uint128 capacity,
        uint128 liquidity,
        uint40 expiry
    );
    event FeesClaimed(
        PoolId indexed poolId,
        address indexed maker,
        bytes32 indexed positionId,
        address caller,
        uint256 amount0,
        uint256 amount1
    );
    event PositionsRetired(
        PoolId indexed poolId, address indexed caller, uint256 candidateCount, uint256 maxRetire, uint256 retired
    );

    function setUp() public {
        (maker, makerPk) = makeAddrAndKey("maker");
        (maker2, maker2Pk) = makeAddrAndKey("maker2");

        deployFreshManagerAndRouters();
        deployMintAndApprove2Currencies();

        token0 = MockERC20(Currency.unwrap(currency0));
        token1 = MockERC20(Currency.unwrap(currency1));

        uint160 flags = uint160(
            Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG
                | Hooks.BEFORE_SWAP_FLAG
        );
        hook = NativeBookHook(address(uint160(uint256(type(uint160).max) & clearAllHookPermissionsMask | flags)));
        deployCodeTo("NativeBookHook", abi.encode(manager, owner), address(hook));

        testPoolKey = PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: FEE_PIPS,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(address(hook))
        });
        testPoolId = testPoolKey.toId();

        vm.prank(owner);
        hook.initializePool(testPoolKey, TickMath.getSqrtPriceAtTick(0), _defaultConfig());

        _seedPassiveLiquidity();
        _fundAndApproveMaker(maker);
        _fundAndApproveMaker(maker2);
    }

    function test_replaceLadder_postsCanonicalBidAndAskBins() public {
        NativeBookHook.BinCapacity[] memory bids = new NativeBookHook.BinCapacity[](1);
        bids[0] = NativeBookHook.BinCapacity({offset: -1, amount: 100 ether});
        NativeBookHook.BinCapacity[] memory asks = new NativeBookHook.BinCapacity[](1);
        asks[0] = NativeBookHook.BinCapacity({offset: 1, amount: 100 ether});

        vm.prank(maker);
        hook.replaceLadder(testPoolKey, bids, asks, 1 hours, 0, 0);

        assertEq(hook.makerPositionCount(testPoolId, maker), 2);

        bytes32 bidId = hook.makerPositionAt(testPoolId, maker, 0);
        bytes32 askId = hook.makerPositionAt(testPoolId, maker, 1);
        (
            ,
            PoolId bidPoolId,
            NativeBookHook.Side bidSide,
            int24 bidLower,
            int24 bidUpper,
            uint128 bidLiquidity,,
            bool bidActive
        ) = hook.positions(bidId);
        (
            ,
            PoolId askPoolId,
            NativeBookHook.Side askSide,
            int24 askLower,
            int24 askUpper,
            uint128 askLiquidity,,
            bool askActive
        ) = hook.positions(askId);

        assertEq(PoolId.unwrap(bidPoolId), PoolId.unwrap(testPoolId));
        assertEq(PoolId.unwrap(askPoolId), PoolId.unwrap(testPoolId));
        assertEq(uint8(bidSide), uint8(NativeBookHook.Side.Bid));
        assertEq(uint8(askSide), uint8(NativeBookHook.Side.Ask));
        assertEq(bidLower, -BIN_SPACING);
        assertEq(bidUpper, 0);
        assertEq(askLower, BIN_SPACING);
        assertEq(askUpper, 2 * BIN_SPACING);
        assertGt(bidLiquidity, 0);
        assertGt(askLiquidity, 0);
        assertTrue(bidActive);
        assertTrue(askActive);
    }

    function test_replaceLadder_replacesPreviousBins() public {
        NativeBookHook.BinCapacity[] memory bids = new NativeBookHook.BinCapacity[](1);
        NativeBookHook.BinCapacity[] memory asks = new NativeBookHook.BinCapacity[](1);
        bids[0] = NativeBookHook.BinCapacity({offset: -1, amount: 100 ether});
        asks[0] = NativeBookHook.BinCapacity({offset: 1, amount: 100 ether});

        vm.startPrank(maker);
        hook.replaceLadder(testPoolKey, bids, asks, 1 hours, 0, 0);
        bids[0] = NativeBookHook.BinCapacity({offset: -2, amount: 75 ether});
        asks = new NativeBookHook.BinCapacity[](0);
        hook.replaceLadder(testPoolKey, bids, asks, 1 hours, 0, 0);
        vm.stopPrank();

        assertEq(hook.makerPositionCount(testPoolId, maker), 1);
        bytes32 positionId = hook.makerPositionAt(testPoolId, maker, 0);
        (,,, int24 tickLower, int24 tickUpper,,,,) = _readPosition(positionId);
        assertEq(tickLower, -2 * BIN_SPACING);
        assertEq(tickUpper, -BIN_SPACING);
    }

    function test_replaceLadder_sameBinDoesNotDuplicatePosition() public {
        NativeBookHook.BinCapacity[] memory bids = new NativeBookHook.BinCapacity[](1);
        NativeBookHook.BinCapacity[] memory asks = new NativeBookHook.BinCapacity[](0);
        bids[0] = NativeBookHook.BinCapacity({offset: -1, amount: 100 ether});

        vm.startPrank(maker);
        hook.replaceLadder(testPoolKey, bids, asks, 1 hours, 0, 0);
        bytes32 firstId = hook.makerPositionAt(testPoolId, maker, 0);
        bids[0] = NativeBookHook.BinCapacity({offset: -1, amount: 75 ether});
        hook.replaceLadder(testPoolKey, bids, asks, 1 hours, 0, 0);
        vm.stopPrank();

        assertEq(hook.makerPositionCount(testPoolId, maker), 1);
        assertEq(hook.activePositionCount(testPoolId), 1);
        assertEq(hook.makerPositionAt(testPoolId, maker, 0), firstId);
        (,,,,, uint128 liquidity,,,) = _readPosition(firstId);
        assertGt(liquidity, 0);
    }

    function testFuzz_replaceLadder_tracksCanonicalBins(uint8 bidCountRaw, uint8 askCountRaw, uint40 ttlRaw) public {
        uint256 bidCount = bound(bidCountRaw, 0, 4);
        uint256 askCount = bound(askCountRaw, 0, 4);
        uint40 ttl = uint40(bound(ttlRaw, 1, 1 days));

        NativeBookHook.BinCapacity[] memory bids = new NativeBookHook.BinCapacity[](bidCount);
        for (uint256 i; i < bidCount; ++i) {
            bids[i] = NativeBookHook.BinCapacity({offset: -int8(uint8(i + 1)), amount: 100 ether});
        }
        NativeBookHook.BinCapacity[] memory asks = new NativeBookHook.BinCapacity[](askCount);
        for (uint256 i; i < askCount; ++i) {
            asks[i] = NativeBookHook.BinCapacity({offset: int8(uint8(i + 1)), amount: 100 ether});
        }

        vm.prank(maker);
        hook.replaceLadder(testPoolKey, bids, asks, ttl, 0, 0);

        uint256 totalCount = bidCount + askCount;
        assertEq(hook.makerPositionCount(testPoolId, maker), totalCount);
        assertEq(hook.activePositionCount(testPoolId), totalCount);
        for (uint256 i; i < totalCount; ++i) {
            bytes32 positionId = hook.makerPositionAt(testPoolId, maker, i);
            (address maker_, PoolId poolId,, int24 tickLower, int24 tickUpper, uint128 liquidity,, bool active,) =
                _readPosition(positionId);
            assertEq(maker_, maker);
            assertEq(PoolId.unwrap(poolId), PoolId.unwrap(testPoolId));
            assertEq(tickUpper - tickLower, BIN_SPACING);
            assertGt(liquidity, 0);
            assertTrue(active);
        }
    }

    function test_multipleMakersCanQuoteSameCanonicalBin() public {
        NativeBookHook.BinCapacity[] memory bids = new NativeBookHook.BinCapacity[](1);
        NativeBookHook.BinCapacity[] memory asks = new NativeBookHook.BinCapacity[](0);
        bids[0] = NativeBookHook.BinCapacity({offset: -1, amount: 100 ether});

        vm.prank(maker);
        hook.replaceLadder(testPoolKey, bids, asks, 1 hours, 0, 0);
        vm.prank(maker2);
        hook.replaceLadder(testPoolKey, bids, asks, 1 hours, 0, 0);

        bytes32 maker1Id = hook.makerPositionAt(testPoolId, maker, 0);
        bytes32 maker2Id = hook.makerPositionAt(testPoolId, maker2, 0);
        assertNotEq(maker1Id, maker2Id);
        assertEq(hook.makerPositionCount(testPoolId, maker), 1);
        assertEq(hook.makerPositionCount(testPoolId, maker2), 1);
        assertEq(hook.activePositionCount(testPoolId), 2);

        (,,, int24 maker1Lower, int24 maker1Upper,,,,) = _readPosition(maker1Id);
        (,,, int24 maker2Lower, int24 maker2Upper,,,,) = _readPosition(maker2Id);
        assertEq(maker1Lower, maker2Lower);
        assertEq(maker1Upper, maker2Upper);
    }

    function test_depositCreditsMakerInventory() public {
        address depositor = makeAddr("depositor");
        token0.transfer(depositor, 100 ether);

        vm.startPrank(depositor);
        token0.approve(address(hook), 100 ether);
        vm.expectEmit(true, true, true, true, address(hook));
        emit InventoryDeposited(maker, Currency.unwrap(currency0), depositor, 100 ether, 100 ether);
        hook.depositFor(maker, currency0, 100 ether);
        vm.stopPrank();

        assertEq(hook.inventoryBalance(maker, currency0), 500_100 ether);
    }

    function test_withdrawDebitsMakerInventoryAndTransfersToRecipient() public {
        address recipient = makeAddr("recipient");
        uint256 hookBalanceBefore = hook.inventoryBalance(maker, currency0);
        uint256 recipientBalanceBefore = token0.balanceOf(recipient);

        vm.expectEmit(true, true, true, true, address(hook));
        emit InventoryWithdrawn(maker, Currency.unwrap(currency0), recipient, 10 ether);
        vm.prank(maker);
        hook.withdraw(currency0, 10 ether, recipient);

        assertEq(hook.inventoryBalance(maker, currency0), hookBalanceBefore - 10 ether);
        assertEq(token0.balanceOf(recipient), recipientBalanceBefore + 10 ether);
    }

    function test_replaceLadder_revertsWhenCustodiedInventoryIsInsufficient() public {
        address emptyMaker = makeAddr("emptyMaker");
        NativeBookHook.BinCapacity[] memory bids = new NativeBookHook.BinCapacity[](1);
        bids[0] = NativeBookHook.BinCapacity({offset: -1, amount: 100 ether});
        NativeBookHook.BinCapacity[] memory asks = new NativeBookHook.BinCapacity[](0);

        vm.expectRevert(
            abi.encodeWithSelector(
                NativeBookHook.InsufficientInventory.selector, emptyMaker, Currency.unwrap(currency1), 0, 100 ether
            )
        );
        vm.prank(emptyMaker);
        hook.replaceLadder(testPoolKey, bids, asks, 1 hours, 0, 0);
    }

    function test_replaceLadder_revertsForDuplicateBidOffset() public {
        NativeBookHook.BinCapacity[] memory bids = new NativeBookHook.BinCapacity[](2);
        bids[0] = NativeBookHook.BinCapacity({offset: -1, amount: 100 ether});
        bids[1] = NativeBookHook.BinCapacity({offset: -1, amount: 50 ether});
        NativeBookHook.BinCapacity[] memory asks = new NativeBookHook.BinCapacity[](0);

        vm.expectRevert(NativeBookHook.DuplicateBinOffset.selector);
        vm.prank(maker);
        hook.replaceLadder(testPoolKey, bids, asks, 1 hours, 0, 0);
    }

    function test_replaceLadder_revertsForDuplicateAskOffset() public {
        NativeBookHook.BinCapacity[] memory bids = new NativeBookHook.BinCapacity[](0);
        NativeBookHook.BinCapacity[] memory asks = new NativeBookHook.BinCapacity[](2);
        asks[0] = NativeBookHook.BinCapacity({offset: 1, amount: 100 ether});
        asks[1] = NativeBookHook.BinCapacity({offset: 1, amount: 50 ether});

        vm.expectRevert(NativeBookHook.DuplicateBinOffset.selector);
        vm.prank(maker);
        hook.replaceLadder(testPoolKey, bids, asks, 1 hours, 0, 0);
    }

    function test_replaceLadderWithSig_allowsRelayerToPostMakerLadder() public {
        NativeBookHook.BinCapacity[] memory bids = new NativeBookHook.BinCapacity[](1);
        bids[0] = NativeBookHook.BinCapacity({offset: -1, amount: 100 ether});
        NativeBookHook.BinCapacity[] memory asks = new NativeBookHook.BinCapacity[](1);
        asks[0] = NativeBookHook.BinCapacity({offset: 1, amount: 100 ether});
        uint256 deadline = block.timestamp + 1 hours;
        bytes memory signature = _signReplaceLadder(makerPk, maker, bids, asks, 1 hours, deadline);

        vm.prank(relayer);
        hook.replaceLadderWithSig(testPoolKey, maker, bids, asks, 1 hours, 0, 0, deadline, signature);

        assertEq(hook.nonces(maker), 1);
        assertEq(hook.makerPositionCount(testPoolId, maker), 2);
    }

    function test_replaceLadderWithSig_emitsRelayerAndNonceContext() public {
        NativeBookHook.BinCapacity[] memory bids = new NativeBookHook.BinCapacity[](1);
        bids[0] = NativeBookHook.BinCapacity({offset: -1, amount: 100 ether});
        NativeBookHook.BinCapacity[] memory asks = new NativeBookHook.BinCapacity[](0);
        uint40 ttl = 1 hours;
        uint40 expiry = uint40(block.timestamp) + ttl;
        uint256 deadline = block.timestamp + 2 hours;
        uint256 nonce = hook.nonces(maker);
        bytes memory signature = _signReplaceLadder(makerPk, maker, bids, asks, ttl, deadline);

        vm.expectEmit(true, true, true, true, address(hook));
        emit LadderReplaced(testPoolId, maker, relayer, 1, 0, expiry, nonce, deadline, true);
        vm.prank(relayer);
        hook.replaceLadderWithSig(testPoolKey, maker, bids, asks, ttl, 0, 0, deadline, signature);
    }

    function test_replaceLadderWithSig_replacesExistingLadder() public {
        NativeBookHook.BinCapacity[] memory bids = new NativeBookHook.BinCapacity[](1);
        bids[0] = NativeBookHook.BinCapacity({offset: -1, amount: 100 ether});
        NativeBookHook.BinCapacity[] memory asks = new NativeBookHook.BinCapacity[](0);

        vm.prank(maker);
        hook.replaceLadder(testPoolKey, bids, asks, 1 hours, 0, 0);
        assertEq(hook.makerPositionCount(testPoolId, maker), 1);

        bids[0] = NativeBookHook.BinCapacity({offset: -2, amount: 75 ether});
        uint256 deadline = block.timestamp + 1 hours;
        bytes memory signature = _signReplaceLadder(makerPk, maker, bids, asks, 1 hours, deadline);

        vm.prank(relayer);
        hook.replaceLadderWithSig(testPoolKey, maker, bids, asks, 1 hours, 0, 0, deadline, signature);

        bytes32 positionId = hook.makerPositionAt(testPoolId, maker, 0);
        (,,, int24 tickLower, int24 tickUpper,,,,) = _readPosition(positionId);
        assertEq(hook.makerPositionCount(testPoolId, maker), 1);
        assertEq(tickLower, -2 * BIN_SPACING);
        assertEq(tickUpper, -BIN_SPACING);
    }

    function test_replaceLadderWithSig_revertsOnReplay() public {
        NativeBookHook.BinCapacity[] memory bids = new NativeBookHook.BinCapacity[](1);
        bids[0] = NativeBookHook.BinCapacity({offset: -1, amount: 100 ether});
        NativeBookHook.BinCapacity[] memory asks = new NativeBookHook.BinCapacity[](0);
        uint256 deadline = block.timestamp + 1 hours;
        bytes memory signature = _signReplaceLadder(makerPk, maker, bids, asks, 1 hours, deadline);

        vm.prank(relayer);
        hook.replaceLadderWithSig(testPoolKey, maker, bids, asks, 1 hours, 0, 0, deadline, signature);

        vm.expectRevert(NativeBookHook.InvalidSignature.selector);
        vm.prank(relayer);
        hook.replaceLadderWithSig(testPoolKey, maker, bids, asks, 1 hours, 0, 0, deadline, signature);
        assertEq(hook.nonces(maker), 1);
    }

    function test_replaceLadderWithSig_revertsWhenExpired() public {
        NativeBookHook.BinCapacity[] memory bids = new NativeBookHook.BinCapacity[](1);
        bids[0] = NativeBookHook.BinCapacity({offset: -1, amount: 100 ether});
        NativeBookHook.BinCapacity[] memory asks = new NativeBookHook.BinCapacity[](0);
        uint256 deadline = 1 days;
        bytes memory signature = _signReplaceLadder(makerPk, maker, bids, asks, 1 hours, deadline);

        vm.warp(deadline + 1);
        vm.expectRevert(NativeBookHook.SignatureExpired.selector);
        vm.prank(relayer);
        hook.replaceLadderWithSig(testPoolKey, maker, bids, asks, 1 hours, 0, 0, deadline, signature);
        assertEq(hook.nonces(maker), 0);
    }

    function test_replaceLadderWithSig_revertsForWrongSigner() public {
        NativeBookHook.BinCapacity[] memory bids = new NativeBookHook.BinCapacity[](1);
        bids[0] = NativeBookHook.BinCapacity({offset: -1, amount: 100 ether});
        NativeBookHook.BinCapacity[] memory asks = new NativeBookHook.BinCapacity[](0);
        uint256 deadline = block.timestamp + 1 hours;
        bytes memory signature = _signReplaceLadder(maker2Pk, maker, bids, asks, 1 hours, deadline);

        vm.expectRevert(NativeBookHook.InvalidSignature.selector);
        vm.prank(relayer);
        hook.replaceLadderWithSig(testPoolKey, maker, bids, asks, 1 hours, 0, 0, deadline, signature);
        assertEq(hook.nonces(maker), 0);
    }

    function test_replaceLadderWithSig_revertsWhenRefTickMovesOutsideBound() public {
        NativeBookHook.BinCapacity[] memory bids = new NativeBookHook.BinCapacity[](1);
        bids[0] = NativeBookHook.BinCapacity({offset: -1, amount: 100 ether});
        NativeBookHook.BinCapacity[] memory asks = new NativeBookHook.BinCapacity[](0);
        uint256 deadline = block.timestamp + 1 hours;
        bytes memory signature = _signReplaceLadder(makerPk, maker, bids, asks, 1 hours, 60, 0, deadline);

        vm.expectRevert(abi.encodeWithSelector(NativeBookHook.RefTickSlippage.selector, 60, 0, 0));
        vm.prank(relayer);
        hook.replaceLadderWithSig(testPoolKey, maker, bids, asks, 1 hours, 60, 0, deadline, signature);
    }

    function test_replaceLadderWithSig_revertsWhenExpiryWouldExceedDeadline() public {
        NativeBookHook.BinCapacity[] memory bids = new NativeBookHook.BinCapacity[](1);
        bids[0] = NativeBookHook.BinCapacity({offset: -1, amount: 100 ether});
        NativeBookHook.BinCapacity[] memory asks = new NativeBookHook.BinCapacity[](0);
        uint40 ttl = 1 hours;
        uint256 deadline = block.timestamp + ttl;
        bytes memory signature = _signReplaceLadder(makerPk, maker, bids, asks, ttl, deadline);

        vm.warp(block.timestamp + 1);
        vm.expectRevert(NativeBookHook.InvalidQuoteTtl.selector);
        vm.prank(relayer);
        hook.replaceLadderWithSig(testPoolKey, maker, bids, asks, ttl, 0, 0, deadline, signature);
    }

    function test_directReplaceInvalidatesOlderSignedReplace() public {
        NativeBookHook.BinCapacity[] memory bids = new NativeBookHook.BinCapacity[](1);
        bids[0] = NativeBookHook.BinCapacity({offset: -1, amount: 100 ether});
        NativeBookHook.BinCapacity[] memory asks = new NativeBookHook.BinCapacity[](0);
        uint256 deadline = block.timestamp + 1 hours;
        bytes memory staleSignature = _signReplaceLadder(makerPk, maker, bids, asks, 1 hours, deadline);

        vm.prank(maker);
        hook.replaceLadder(testPoolKey, bids, asks, 1 hours, 0, 0);

        vm.expectRevert(NativeBookHook.InvalidSignature.selector);
        vm.prank(relayer);
        hook.replaceLadderWithSig(testPoolKey, maker, bids, asks, 1 hours, 0, 0, deadline, staleSignature);
        assertEq(hook.nonces(maker), 1);
    }

    function test_expiredBinRetiresOnGenericSwapWithoutHookData() public {
        NativeBookHook.BinCapacity[] memory bids = new NativeBookHook.BinCapacity[](1);
        NativeBookHook.BinCapacity[] memory asks = new NativeBookHook.BinCapacity[](0);
        bids[0] = NativeBookHook.BinCapacity({offset: -1, amount: 100 ether});

        vm.prank(maker);
        hook.replaceLadder(testPoolKey, bids, asks, 1, 0, 0);
        assertEq(hook.makerPositionCount(testPoolId, maker), 1);

        vm.warp(block.timestamp + 2);
        BalanceDelta delta = swap(testPoolKey, true, -1 ether, "");

        assertLt(delta.amount0(), 0);
        assertGt(delta.amount1(), 0);
        assertEq(hook.makerPositionCount(testPoolId, maker), 0);
    }

    function test_expiredBinCanBeRetiredByKeeper() public {
        NativeBookHook.BinCapacity[] memory bids = new NativeBookHook.BinCapacity[](1);
        NativeBookHook.BinCapacity[] memory asks = new NativeBookHook.BinCapacity[](0);
        bids[0] = NativeBookHook.BinCapacity({offset: -1, amount: 100 ether});

        vm.prank(maker);
        hook.replaceLadder(testPoolKey, bids, asks, 1, 0, 0);
        bytes32 positionId = hook.makerPositionAt(testPoolId, maker, 0);

        vm.warp(block.timestamp + 2);
        hook.retirePosition(testPoolKey, positionId);

        assertEq(hook.makerPositionCount(testPoolId, maker), 0);
        assertEq(hook.activePositionCount(testPoolId), 0);
    }

    function test_retirePosition_revertsBeforeExpiryWhenNotCrossed() public {
        NativeBookHook.BinCapacity[] memory bids = new NativeBookHook.BinCapacity[](1);
        NativeBookHook.BinCapacity[] memory asks = new NativeBookHook.BinCapacity[](0);
        bids[0] = NativeBookHook.BinCapacity({offset: -1, amount: 100 ether});

        vm.prank(maker);
        hook.replaceLadder(testPoolKey, bids, asks, 1 hours, 0, 0);
        bytes32 positionId = hook.makerPositionAt(testPoolId, maker, 0);

        vm.expectRevert(NativeBookHook.PositionNotRetirable.selector);
        hook.retirePosition(testPoolKey, positionId);
    }

    function test_retirePositions_retiresBoundedExpiredBatchAndSkipsFreshIds() public {
        NativeBookHook.BinCapacity[] memory bids = new NativeBookHook.BinCapacity[](3);
        bids[0] = NativeBookHook.BinCapacity({offset: -1, amount: 100 ether});
        bids[1] = NativeBookHook.BinCapacity({offset: -2, amount: 100 ether});
        bids[2] = NativeBookHook.BinCapacity({offset: -3, amount: 100 ether});
        NativeBookHook.BinCapacity[] memory asks = new NativeBookHook.BinCapacity[](0);

        vm.prank(maker);
        hook.replaceLadder(testPoolKey, bids, asks, 1, 0, 0);
        bytes32[] memory ids = new bytes32[](4);
        ids[0] = hook.makerPositionAt(testPoolId, maker, 0);
        ids[1] = bytes32(uint256(123));
        ids[2] = hook.makerPositionAt(testPoolId, maker, 1);
        ids[3] = hook.makerPositionAt(testPoolId, maker, 2);

        vm.warp(block.timestamp + 2);
        uint256 retired = hook.retirePositions(testPoolKey, ids, 2);

        assertEq(retired, 2);
        assertEq(hook.makerPositionCount(testPoolId, maker), 1);

        retired = hook.retirePositions(testPoolKey, ids, 4);
        assertEq(retired, 1);
        assertEq(hook.makerPositionCount(testPoolId, maker), 0);
    }

    function test_retirePositions_emitsBatchSummary() public {
        NativeBookHook.BinCapacity[] memory bids = new NativeBookHook.BinCapacity[](2);
        bids[0] = NativeBookHook.BinCapacity({offset: -1, amount: 100 ether});
        bids[1] = NativeBookHook.BinCapacity({offset: -2, amount: 100 ether});
        NativeBookHook.BinCapacity[] memory asks = new NativeBookHook.BinCapacity[](0);

        vm.prank(maker);
        hook.replaceLadder(testPoolKey, bids, asks, 1, 0, 0);
        bytes32[] memory ids = new bytes32[](3);
        ids[0] = bytes32(uint256(123));
        ids[1] = hook.makerPositionAt(testPoolId, maker, 0);
        ids[2] = hook.makerPositionAt(testPoolId, maker, 1);

        vm.warp(block.timestamp + 2);
        vm.expectEmit(true, true, false, true, address(hook));
        emit PositionsRetired(testPoolId, address(this), 3, 2, 2);
        hook.retirePositions(testPoolKey, ids, 2);
    }

    function test_genericSwapExactInputAcceptsArbitraryHookData() public {
        BalanceDelta delta = swap(testPoolKey, true, 1 ether, abi.encode("ignored-by-native-book"));

        assertLt(delta.amount0(), 0);
        assertGt(delta.amount1(), 0);
    }

    function test_genericSwapExactOutputOneForZeroAcceptsEmptyHookData() public {
        BalanceDelta delta = swap(testPoolKey, false, -1 ether, "");

        assertGt(delta.amount0(), 0);
        assertLt(delta.amount1(), 0);
    }

    function test_swapRevertsWhenPoolNotLive() public {
        vm.prank(owner);
        hook.setPoolLive(testPoolKey, false);

        _expectHookWrappedError(
            IHooks.beforeSwap.selector, abi.encodeWithSelector(NativeBookHook.PoolNotLive.selector, testPoolId)
        );
        swap(testPoolKey, true, 1 ether, "");
    }

    function test_setPoolLive_emitsOldAndNewValues() public {
        vm.expectEmit(true, true, false, true, address(hook));
        emit PoolLivenessUpdated(testPoolId, owner, true, false);
        vm.prank(owner);
        hook.setPoolLive(testPoolKey, false);
    }

    function test_crossedAskCanBeRetiredAfterGenericSwap() public {
        NativeBookHook.BinCapacity[] memory bids = new NativeBookHook.BinCapacity[](0);
        NativeBookHook.BinCapacity[] memory asks = new NativeBookHook.BinCapacity[](1);
        asks[0] = NativeBookHook.BinCapacity({offset: 1, amount: 100 ether});

        vm.prank(maker);
        hook.replaceLadder(testPoolKey, bids, asks, 1 hours, 0, 0);
        uint256 makerToken1BeforeRetire = hook.inventoryBalance(maker, currency1);

        swap(testPoolKey, false, 110 ether, "");
        (, int24 currentTick,,) = manager.getSlot0(testPoolId);

        assertGe(currentTick, 2 * BIN_SPACING);
        assertEq(hook.makerPositionCount(testPoolId, maker), 1);
        hook.retirePosition(testPoolKey, hook.makerPositionAt(testPoolId, maker, 0));
        assertEq(hook.makerPositionCount(testPoolId, maker), 0);
        assertGt(hook.inventoryBalance(maker, currency1), makerToken1BeforeRetire);
    }

    function test_claimFeesCollectsAccruedFeesWithoutRemovingPosition() public {
        NativeBookHook.BinCapacity[] memory bids = new NativeBookHook.BinCapacity[](0);
        NativeBookHook.BinCapacity[] memory asks = new NativeBookHook.BinCapacity[](1);
        asks[0] = NativeBookHook.BinCapacity({offset: 1, amount: 100 ether});

        vm.prank(maker);
        hook.replaceLadder(testPoolKey, bids, asks, 1 hours, 0, 0);
        bytes32 positionId = hook.makerPositionAt(testPoolId, maker, 0);

        swap(testPoolKey, false, 110 ether, "");
        uint256 makerToken1BeforeClaim = hook.inventoryBalance(maker, currency1);

        hook.claimFees(testPoolKey, positionId);

        assertEq(hook.makerPositionCount(testPoolId, maker), 1);
        assertGt(hook.inventoryBalance(maker, currency1), makerToken1BeforeClaim);
    }

    function test_claimFees_emitsCallerAndClaimedAmounts() public {
        NativeBookHook.BinCapacity[] memory bids = new NativeBookHook.BinCapacity[](0);
        NativeBookHook.BinCapacity[] memory asks = new NativeBookHook.BinCapacity[](1);
        asks[0] = NativeBookHook.BinCapacity({offset: 1, amount: 100 ether});

        vm.prank(maker);
        hook.replaceLadder(testPoolKey, bids, asks, 1 hours, 0, 0);
        bytes32 positionId = hook.makerPositionAt(testPoolId, maker, 0);
        swap(testPoolKey, false, 110 ether, "");

        vm.recordLogs();
        vm.prank(relayer);
        hook.claimFees(testPoolKey, positionId);
        Vm.Log[] memory entries = vm.getRecordedLogs();

        bytes32 signature = keccak256("FeesClaimed(bytes32,address,bytes32,address,uint256,uint256)");
        bool found;
        for (uint256 i; i < entries.length; ++i) {
            if (entries[i].topics[0] == signature) {
                assertEq(entries[i].topics[1], PoolId.unwrap(testPoolId));
                assertEq(address(uint160(uint256(entries[i].topics[2]))), maker);
                assertEq(entries[i].topics[3], positionId);
                (address caller, uint256 amount0, uint256 amount1) =
                    abi.decode(entries[i].data, (address, uint256, uint256));
                assertEq(caller, relayer);
                assertEq(amount0, 0);
                assertGt(amount1, 0);
                found = true;
            }
        }
        assertTrue(found);
    }

    function test_claimFees_revertsForInvalidPosition() public {
        vm.expectRevert(NativeBookHook.InvalidPosition.selector);
        hook.claimFees(testPoolKey, bytes32(uint256(123)));
    }

    function test_directOneBinLiquidityIsReservedForBook() public {
        _expectHookWrappedError(IHooks.beforeAddLiquidity.selector, NativeBookHook.ReservedBookRange.selector);
        modifyLiquidityRouter.modifyLiquidity(
            testPoolKey,
            ModifyLiquidityParams({
                tickLower: BIN_SPACING, tickUpper: 2 * BIN_SPACING, liquidityDelta: 1 ether, salt: bytes32(uint256(1))
            }),
            ""
        );
    }

    function test_replaceLadder_emitsPositionIdOnBinPosted() public {
        NativeBookHook.BinCapacity[] memory bids = new NativeBookHook.BinCapacity[](1);
        bids[0] = NativeBookHook.BinCapacity({offset: -1, amount: 100 ether});
        NativeBookHook.BinCapacity[] memory asks = new NativeBookHook.BinCapacity[](0);
        bytes32 positionId = keccak256(abi.encode(testPoolId, maker, NativeBookHook.Side.Bid, -BIN_SPACING));

        vm.expectEmit(true, true, true, false, address(hook));
        emit BinPosted(testPoolId, maker, positionId, NativeBookHook.Side.Bid, 0, 0, 0, 0, 0, 0);
        vm.prank(maker);
        hook.replaceLadder(testPoolKey, bids, asks, 1 hours, 0, 0);
    }

    function test_broadPassiveLiquidityCanBeAddedAndRemoved() public {
        ModifyLiquidityParams memory params = ModifyLiquidityParams({
            tickLower: -2 * BIN_SPACING, tickUpper: 2 * BIN_SPACING, liquidityDelta: 1 ether, salt: bytes32(uint256(77))
        });

        modifyLiquidityRouter.modifyLiquidity(testPoolKey, params, "");
        params.liquidityDelta = -1 ether;
        modifyLiquidityRouter.modifyLiquidity(testPoolKey, params, "");
    }

    function test_cancelLadder_removesAllMakerBins() public {
        NativeBookHook.BinCapacity[] memory bids = new NativeBookHook.BinCapacity[](1);
        bids[0] = NativeBookHook.BinCapacity({offset: -1, amount: 100 ether});
        NativeBookHook.BinCapacity[] memory asks = new NativeBookHook.BinCapacity[](1);
        asks[0] = NativeBookHook.BinCapacity({offset: 1, amount: 100 ether});

        vm.startPrank(maker);
        hook.replaceLadder(testPoolKey, bids, asks, 1 hours, 0, 0);
        hook.cancelLadder(testPoolKey);
        vm.stopPrank();

        assertEq(hook.makerPositionCount(testPoolId, maker), 0);
        assertEq(hook.activePositionCount(testPoolId), 0);
    }

    function test_cancelLadderWithSig_allowsRelayerToCancelMakerLadder() public {
        NativeBookHook.BinCapacity[] memory bids = new NativeBookHook.BinCapacity[](1);
        bids[0] = NativeBookHook.BinCapacity({offset: -1, amount: 100 ether});
        NativeBookHook.BinCapacity[] memory asks = new NativeBookHook.BinCapacity[](1);
        asks[0] = NativeBookHook.BinCapacity({offset: 1, amount: 100 ether});

        vm.prank(maker);
        hook.replaceLadder(testPoolKey, bids, asks, 1 hours, 0, 0);
        assertEq(hook.makerPositionCount(testPoolId, maker), 2);

        uint256 deadline = block.timestamp + 1 hours;
        bytes memory signature = _signCancelLadder(makerPk, maker, deadline);

        vm.prank(relayer);
        hook.cancelLadderWithSig(testPoolKey, maker, deadline, signature);

        assertEq(hook.nonces(maker), 2);
        assertEq(hook.makerPositionCount(testPoolId, maker), 0);
        assertEq(hook.activePositionCount(testPoolId), 0);
    }

    function test_cancelLadderWithSig_emitsRelayerAndNonceContext() public {
        NativeBookHook.BinCapacity[] memory bids = new NativeBookHook.BinCapacity[](1);
        bids[0] = NativeBookHook.BinCapacity({offset: -1, amount: 100 ether});
        NativeBookHook.BinCapacity[] memory asks = new NativeBookHook.BinCapacity[](0);

        vm.prank(maker);
        hook.replaceLadder(testPoolKey, bids, asks, 1 hours, 0, 0);

        uint256 deadline = block.timestamp + 1 hours;
        uint256 nonce = hook.nonces(maker);
        bytes memory signature = _signCancelLadder(makerPk, maker, deadline);

        vm.expectEmit(true, true, true, false, address(hook));
        emit LadderCanceled(testPoolId, maker, relayer, 1, 0, 0, nonce, deadline, true);
        vm.prank(relayer);
        hook.cancelLadderWithSig(testPoolKey, maker, deadline, signature);
    }

    function test_cancelLadderWithSig_revertsOnReplay() public {
        NativeBookHook.BinCapacity[] memory bids = new NativeBookHook.BinCapacity[](1);
        bids[0] = NativeBookHook.BinCapacity({offset: -1, amount: 100 ether});
        NativeBookHook.BinCapacity[] memory asks = new NativeBookHook.BinCapacity[](0);

        vm.prank(maker);
        hook.replaceLadder(testPoolKey, bids, asks, 1 hours, 0, 0);

        uint256 deadline = block.timestamp + 1 hours;
        bytes memory signature = _signCancelLadder(makerPk, maker, deadline);

        vm.prank(relayer);
        hook.cancelLadderWithSig(testPoolKey, maker, deadline, signature);

        vm.expectRevert(NativeBookHook.InvalidSignature.selector);
        vm.prank(relayer);
        hook.cancelLadderWithSig(testPoolKey, maker, deadline, signature);
        assertEq(hook.nonces(maker), 2);
    }

    function test_directCancelInvalidatesOlderSignedCancel() public {
        NativeBookHook.BinCapacity[] memory bids = new NativeBookHook.BinCapacity[](1);
        bids[0] = NativeBookHook.BinCapacity({offset: -1, amount: 100 ether});
        NativeBookHook.BinCapacity[] memory asks = new NativeBookHook.BinCapacity[](0);

        vm.prank(maker);
        hook.replaceLadder(testPoolKey, bids, asks, 1 hours, 0, 0);

        uint256 deadline = block.timestamp + 1 hours;
        bytes memory staleSignature = _signCancelLadder(makerPk, maker, deadline);

        vm.prank(maker);
        hook.cancelLadder(testPoolKey);

        vm.expectRevert(NativeBookHook.InvalidSignature.selector);
        vm.prank(relayer);
        hook.cancelLadderWithSig(testPoolKey, maker, deadline, staleSignature);
        assertEq(hook.nonces(maker), 2);
    }

    function test_cancelLadderWithSig_revertsWhenExpired() public {
        uint256 deadline = 1 days;
        bytes memory signature = _signCancelLadder(makerPk, maker, deadline);

        vm.warp(deadline + 1);
        vm.expectRevert(NativeBookHook.SignatureExpired.selector);
        vm.prank(relayer);
        hook.cancelLadderWithSig(testPoolKey, maker, deadline, signature);
        assertEq(hook.nonces(maker), 0);
    }

    function test_cancelLadderWithSig_revertsForWrongSigner() public {
        uint256 deadline = block.timestamp + 1 hours;
        bytes memory signature = _signCancelLadder(maker2Pk, maker, deadline);

        vm.expectRevert(NativeBookHook.InvalidSignature.selector);
        vm.prank(relayer);
        hook.cancelLadderWithSig(testPoolKey, maker, deadline, signature);
        assertEq(hook.nonces(maker), 0);
    }

    function test_cancelLadderReturnsUnfilledInventory() public {
        uint256 token0Before = hook.inventoryBalance(maker, currency0);
        uint256 token1Before = hook.inventoryBalance(maker, currency1);

        NativeBookHook.BinCapacity[] memory bids = new NativeBookHook.BinCapacity[](1);
        bids[0] = NativeBookHook.BinCapacity({offset: -1, amount: 100 ether});
        NativeBookHook.BinCapacity[] memory asks = new NativeBookHook.BinCapacity[](1);
        asks[0] = NativeBookHook.BinCapacity({offset: 1, amount: 100 ether});

        vm.startPrank(maker);
        hook.replaceLadder(testPoolKey, bids, asks, 1 hours, 0, 0);
        assertLt(hook.inventoryBalance(maker, currency0), token0Before);
        assertLt(hook.inventoryBalance(maker, currency1), token1Before);
        hook.cancelLadder(testPoolKey);
        vm.stopPrank();

        assertApproxEqAbs(hook.inventoryBalance(maker, currency0), token0Before, 1);
        assertApproxEqAbs(hook.inventoryBalance(maker, currency1), token1Before, 1);
    }

    function test_initializePool_validatesConfig() public {
        NativeBookHook.PoolConfig memory config = _defaultConfig();
        config.binSpacingTicks = 55;

        vm.expectRevert(NativeBookHook.InvalidPoolConfig.selector);
        vm.prank(owner);
        hook.initializePool(testPoolKey, TickMath.getSqrtPriceAtTick(0), config);
    }

    function test_initializePool_revertsForZeroMinBinLiquidity() public {
        NativeBookHook.PoolConfig memory config = _defaultConfig();
        config.minBinLiquidity = 0;

        vm.expectRevert(NativeBookHook.InvalidPoolConfig.selector);
        vm.prank(owner);
        hook.initializePool(testPoolKey, TickMath.getSqrtPriceAtTick(0), config);
    }

    function test_directPoolManagerInitializeIsBlocked() public {
        _expectHookWrappedError(IHooks.beforeInitialize.selector, NativeBookHook.DirectInitializeBlocked.selector);
        manager.initialize(testPoolKey, TickMath.getSqrtPriceAtTick(0));
    }

    function test_replaceLadder_revertsForTooLongTtl() public {
        NativeBookHook.BinCapacity[] memory bids = new NativeBookHook.BinCapacity[](0);
        NativeBookHook.BinCapacity[] memory asks = new NativeBookHook.BinCapacity[](0);

        vm.expectRevert(NativeBookHook.InvalidQuoteTtl.selector);
        vm.prank(maker);
        hook.replaceLadder(testPoolKey, bids, asks, 1 days + 1, 0, 0);
    }

    function test_replaceLadder_revertsForTooManyBins() public {
        NativeBookHook.BinCapacity[] memory bids = new NativeBookHook.BinCapacity[](9);
        NativeBookHook.BinCapacity[] memory asks = new NativeBookHook.BinCapacity[](0);

        vm.expectRevert(NativeBookHook.InvalidPoolConfig.selector);
        vm.prank(maker);
        hook.replaceLadder(testPoolKey, bids, asks, 1 hours, 0, 0);
    }

    function test_replaceLadder_revertsForWrongSideOffset() public {
        NativeBookHook.BinCapacity[] memory bids = new NativeBookHook.BinCapacity[](1);
        NativeBookHook.BinCapacity[] memory asks = new NativeBookHook.BinCapacity[](0);
        bids[0] = NativeBookHook.BinCapacity({offset: 1, amount: 100 ether});

        vm.expectRevert(NativeBookHook.InvalidBinOffset.selector);
        vm.prank(maker);
        hook.replaceLadder(testPoolKey, bids, asks, 1 hours, 0, 0);
    }

    function test_gas_replaceLadder_twoSided() public {
        NativeBookHook.BinCapacity[] memory bids = new NativeBookHook.BinCapacity[](2);
        bids[0] = NativeBookHook.BinCapacity({offset: -1, amount: 100 ether});
        bids[1] = NativeBookHook.BinCapacity({offset: -2, amount: 100 ether});
        NativeBookHook.BinCapacity[] memory asks = new NativeBookHook.BinCapacity[](2);
        asks[0] = NativeBookHook.BinCapacity({offset: 1, amount: 100 ether});
        asks[1] = NativeBookHook.BinCapacity({offset: 2, amount: 100 ether});

        vm.prank(maker);
        hook.replaceLadder(testPoolKey, bids, asks, 1 hours, 0, 0);
        vm.snapshotGasLastCall("NativeBookHook_replaceLadder_twoSided");
    }

    function test_gas_replaceLadderWithSig_twoSided() public {
        NativeBookHook.BinCapacity[] memory bids = new NativeBookHook.BinCapacity[](2);
        bids[0] = NativeBookHook.BinCapacity({offset: -1, amount: 100 ether});
        bids[1] = NativeBookHook.BinCapacity({offset: -2, amount: 100 ether});
        NativeBookHook.BinCapacity[] memory asks = new NativeBookHook.BinCapacity[](2);
        asks[0] = NativeBookHook.BinCapacity({offset: 1, amount: 100 ether});
        asks[1] = NativeBookHook.BinCapacity({offset: 2, amount: 100 ether});
        uint256 deadline = block.timestamp + 1 hours;
        bytes memory signature = _signReplaceLadder(makerPk, maker, bids, asks, 1 hours, deadline);

        vm.prank(relayer);
        hook.replaceLadderWithSig(testPoolKey, maker, bids, asks, 1 hours, 0, 0, deadline, signature);
        vm.snapshotGasLastCall("NativeBookHook_replaceLadderWithSig_twoSided");
    }

    function test_gas_swapWithoutRetire() public {
        BalanceDelta delta = swap(testPoolKey, true, 1 ether, "");
        assertLt(delta.amount0(), 0);
        assertGt(delta.amount1(), 0);
        vm.snapshotGasLastCall("NativeBookHook_swap_noRetire");
    }

    function test_gas_swapRetireExpired() public {
        NativeBookHook.BinCapacity[] memory bids = new NativeBookHook.BinCapacity[](1);
        NativeBookHook.BinCapacity[] memory asks = new NativeBookHook.BinCapacity[](0);
        bids[0] = NativeBookHook.BinCapacity({offset: -1, amount: 100 ether});

        vm.prank(maker);
        hook.replaceLadder(testPoolKey, bids, asks, 1, 0, 0);
        vm.warp(block.timestamp + 2);

        swap(testPoolKey, true, 1 ether, "");
        vm.snapshotGasLastCall("NativeBookHook_swap_retireExpired");
    }

    function test_gas_retirePositions_expiredBatch() public {
        NativeBookHook.BinCapacity[] memory bids = new NativeBookHook.BinCapacity[](3);
        bids[0] = NativeBookHook.BinCapacity({offset: -1, amount: 100 ether});
        bids[1] = NativeBookHook.BinCapacity({offset: -2, amount: 100 ether});
        bids[2] = NativeBookHook.BinCapacity({offset: -3, amount: 100 ether});
        NativeBookHook.BinCapacity[] memory asks = new NativeBookHook.BinCapacity[](0);

        vm.prank(maker);
        hook.replaceLadder(testPoolKey, bids, asks, 1, 0, 0);
        bytes32[] memory ids = new bytes32[](3);
        ids[0] = hook.makerPositionAt(testPoolId, maker, 0);
        ids[1] = hook.makerPositionAt(testPoolId, maker, 1);
        ids[2] = hook.makerPositionAt(testPoolId, maker, 2);
        vm.warp(block.timestamp + 2);

        hook.retirePositions(testPoolKey, ids, 3);
        vm.snapshotGasLastCall("NativeBookHook_retirePositions_expiredBatch");
    }

    function test_gas_claimFees_crossedAsk() public {
        NativeBookHook.BinCapacity[] memory bids = new NativeBookHook.BinCapacity[](0);
        NativeBookHook.BinCapacity[] memory asks = new NativeBookHook.BinCapacity[](1);
        asks[0] = NativeBookHook.BinCapacity({offset: 1, amount: 100 ether});

        vm.prank(maker);
        hook.replaceLadder(testPoolKey, bids, asks, 1 hours, 0, 0);
        bytes32 positionId = hook.makerPositionAt(testPoolId, maker, 0);
        swap(testPoolKey, false, 110 ether, "");

        hook.claimFees(testPoolKey, positionId);
        vm.snapshotGasLastCall("NativeBookHook_claimFees_crossedAsk");
    }

    function _defaultConfig() internal pure returns (NativeBookHook.PoolConfig memory) {
        return NativeBookHook.PoolConfig({
            binSpacingTicks: BIN_SPACING,
            binsPerSide: 4,
            maxMakerBins: 8,
            maxRetirePerSwap: 4,
            maxQuoteTtl: 1 days,
            minBinLiquidity: 1
        });
    }

    function _seedPassiveLiquidity() internal {
        modifyLiquidityRouter.modifyLiquidity(
            testPoolKey,
            ModifyLiquidityParams({
                tickLower: -10 * BIN_SPACING, tickUpper: 10 * BIN_SPACING, liquidityDelta: 100 ether, salt: 0
            }),
            ""
        );
    }

    function _fundAndApproveMaker(address account) internal {
        token0.transfer(account, 1_000_000 ether);
        token1.transfer(account, 1_000_000 ether);
        vm.startPrank(account);
        token0.approve(address(hook), type(uint256).max);
        token1.approve(address(hook), type(uint256).max);
        hook.deposit(currency0, 500_000 ether);
        hook.deposit(currency1, 500_000 ether);
        vm.stopPrank();
    }

    function _expectHookWrappedError(bytes4 hookSelector, bytes4 reasonSelector) internal {
        _expectHookWrappedError(hookSelector, abi.encodeWithSelector(reasonSelector));
    }

    function _signReplaceLadder(
        uint256 privateKey,
        address maker_,
        NativeBookHook.BinCapacity[] memory bids,
        NativeBookHook.BinCapacity[] memory asks,
        uint40 ttl,
        uint256 deadline
    ) internal view returns (bytes memory) {
        return _signReplaceLadder(privateKey, maker_, bids, asks, ttl, 0, 0, deadline);
    }

    function _signReplaceLadder(
        uint256 privateKey,
        address maker_,
        NativeBookHook.BinCapacity[] memory bids,
        NativeBookHook.BinCapacity[] memory asks,
        uint40 ttl,
        int24 expectedRefTick,
        uint24 maxTickDeviation,
        uint256 deadline
    ) internal view returns (bytes memory) {
        bytes32 digest = hook.hashReplaceLadder(
            testPoolKey, maker_, bids, asks, ttl, expectedRefTick, maxTickDeviation, hook.nonces(maker_), deadline
        );
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(privateKey, digest);
        return abi.encodePacked(r, s, v);
    }

    function _signCancelLadder(uint256 privateKey, address maker_, uint256 deadline)
        internal
        view
        returns (bytes memory)
    {
        bytes32 digest = hook.hashCancelLadder(testPoolKey, maker_, hook.nonces(maker_), deadline);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(privateKey, digest);
        return abi.encodePacked(r, s, v);
    }

    function _expectHookWrappedError(bytes4 hookSelector, bytes memory reason) internal {
        vm.expectRevert(
            abi.encodeWithSelector(
                CustomRevert.WrappedError.selector,
                address(hook),
                hookSelector,
                reason,
                abi.encodeWithSelector(Hooks.HookCallFailed.selector)
            )
        );
    }

    function _readPosition(bytes32 positionId)
        internal
        view
        returns (
            address maker_,
            PoolId poolId,
            NativeBookHook.Side side,
            int24 tickLower,
            int24 tickUpper,
            uint128 liquidity,
            uint40 expiry,
            bool active,
            bool dummy
        )
    {
        (maker_, poolId, side, tickLower, tickUpper, liquidity, expiry, active) = hook.positions(positionId);
        dummy = false;
    }
}
