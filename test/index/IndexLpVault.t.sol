// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import "forge-std/Test.sol";
import {IERC721} from "forge-std/interfaces/IERC721.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {LiquidityAmounts} from "@uniswap/v4-core/test/utils/LiquidityAmounts.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {PositionInfo, PositionInfoLibrary} from "@uniswap/v4-periphery/src/libraries/PositionInfoLibrary.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";
import {PoolConfigLib, PoolEntry} from "../../script/index-vault/PoolConfigLib.sol";
import {IndexLpVault} from "../../src/index/IndexLpVault.sol";
import {IIndexLpVault} from "../../src/index/interfaces/IIndexLpVault.sol";
import {IndexVaultMath} from "../../src/index/libraries/IndexVaultMath.sol";
import {IndexVaultTestBase} from "./base/IndexVaultTestBase.sol";

/// @notice The vault against the real 4663 PoolManager, PositionManager, Permit2 and tokens (fork; skipped without RPC_4663)
contract IndexLpVaultTest is IndexVaultTestBase {
    using PoolIdLibrary for PoolKey;
    using PositionInfoLibrary for PositionInfo;

    uint256 constant N = 10;
    uint256 constant NVDA = 0; // stock is currency0
    uint256 constant AAPL = 1; // stock is currency0
    uint256 constant MSFT = 2; // stock is currency1

    function test_setup_mintsTenPositionsOnFirstDeposit() public {
        _approveAll(alice);
        (uint256[] memory s, uint256[] memory q, uint256 expectedShares) = vault.previewDeposit(100e18);
        uint256 firstId = IPositionManager(POSM).nextTokenId();
        vm.prank(alice);
        uint256 shares = vault.deposit(s, q, 0, alice);
        assertEq(vault.constituentCount(), N);
        for (uint256 i = 0; i < N; i++) {
            IIndexLpVault.ConstituentView memory c = vault.constituent(i);
            // lazily minted in constituent order, one PositionManager NFT each, owned by the vault
            assertEq(c.tokenId, firstId + i, "sequential mints");
            assertEq(IERC721(POSM).ownerOf(c.tokenId), address(vault));
            assertGt(IPositionManager(POSM).getPositionLiquidity(c.tokenId), 0);
            (PoolKey memory key,) = IPositionManager(POSM).getPoolAndPositionInfo(c.tokenId);
            assertEq(PoolId.unwrap(key.toId()), PoolId.unwrap(_key(i).toId()));
            assertEq(c.stock, pools[i].stock);
            assertEq(c.poolId, PoolId.unwrap(_key(i).toId()));
            assertEq(c.targetBps, pools[i].targetBps);
            assertEq(c.tickLower, pools[i].tickLower);
            assertEq(c.tickUpper, pools[i].tickUpper);
        }
        assertEq(vault.balanceOf(alice), shares);
        assertApproxEqRel(shares, expectedShares, 0.001e18);
        assertApproxEqRel(vault.nav(), 100e18, 0.01e18);
    }

    /// @dev Review focus 1: amounts off the pool ratio take min liquidity and the unused side goes back to the depositor
    function test_deposit_sweepsDust() public {
        _approveAll(alice);
        (uint256[] memory s, uint256[] memory q,) = vault.previewDeposit(100e18);
        for (uint256 i = 0; i < N; i++) {
            s[i] = s[i] * 110 / 100;
        }
        (uint256[] memory aliceBefore, uint256 aliceIndexBefore) = _balances(alice);
        (uint256[] memory posmBefore, uint256 posmIndexBefore) = _balances(POSM);
        vm.prank(alice);
        vault.deposit(s, q, 0, alice);

        (
            uint256[] memory positionStock,
            uint256[] memory positionIndex,
            uint256[] memory idleStock,
            uint256 idleIndex
        ) = vault.holdings();
        (uint256[] memory aliceAfter, uint256 aliceIndexAfter) = _balances(alice);
        uint256 positionIndexTotal;
        for (uint256 i = 0; i < N; i++) {
            // the pool charged the position's amounts rounded up; holdings reports them rounded down
            assertLe(aliceBefore[i] - aliceAfter[i], positionStock[i] + 1, "stock not taken by the position came back");
            assertLt(aliceBefore[i] - aliceAfter[i], s[i], "the 10% excess came back");
            assertLe(idleStock[i], 1e12, "no stock idle in the vault");
            positionIndexTotal += positionIndex[i];
        }
        assertLe(aliceIndexBefore - aliceIndexAfter, positionIndexTotal + N);
        assertLe(idleIndex, 1e12);
        // and nothing stranded in the PositionManager
        (uint256[] memory posmAfter, uint256 posmIndexAfter) = _balances(POSM);
        assertEq(posmIndexAfter, posmIndexBefore);
        for (uint256 i = 0; i < N; i++) {
            assertEq(posmAfter[i], posmBefore[i]);
        }
    }

    function test_firstDeposit_deadShares() public {
        uint256 shares = _deposit(alice, 100e18);
        assertEq(vault.balanceOf(address(0xdead)), 1000);
        assertEq(vault.totalSupply(), shares + 1000);
        // the first deposit mints its NAV in shares: 1 share = 1 index-token wei
        assertEq(vault.totalSupply(), vault.nav());
    }

    /// @dev Review focus 3: a dust first deposit plus a donation cannot capture a later depositor's value
    function test_firstDeposit_donationCannotCaptureLaterDeposits() public {
        _fundAll(bob);
        uint256 bobShares = _deposit(bob, 5000);
        assertGt(bobShares, 0);
        vm.prank(bob);
        IERC20(QQQ).transfer(address(vault), 10e18);

        uint256 aliceShares = _deposit(alice, 100e18);
        uint256 nav = vault.nav();
        uint256 supply = vault.totalSupply();
        assertApproxEqRel(aliceShares * nav / supply, 100e18, 0.0001e18, "alice keeps her deposit's value");
        assertLt(bobShares * nav / supply, 10e18, "the donation is the attacker's loss");
    }

    /// @dev Review focus 4: after NVDA rallies the routed amounts favour the underweight pools, and depositing exactly
    ///      those amounts lands every allocation closer to target, within 1 bps of dust
    function test_previewDeposit_routesTowardTargets() public {
        _deposit(alice, 100e18);
        _movePrice(alice, NVDA, 11000);
        _syncReference(NVDA); // the keeper follows the rally
        vault.collectFees(); // previews exclude uncollected fees, which the deposit collects first
        (, uint16[] memory bps,) = vault.allocations();
        assertGt(bps[NVDA], pools[NVDA].targetBps, "NVDA overweight after its rally");
        uint256 deviationBefore = _maxAllocationDeviationBps();

        (uint256[] memory s, uint256[] memory q, uint256 previewShares) = vault.previewDeposit(50e18);
        for (uint256 i = 0; i < N; i++) {
            uint256 routed = _valueOf(i, s[i], q[i]);
            uint256 proRata = uint256(50e18) * pools[i].targetBps / 10_000;
            if (bps[i] < pools[i].targetBps) assertGt(routed, proRata, "underweight gets more than pro-rata");
            if (bps[i] > pools[i].targetBps) assertLt(routed, proRata, "overweight gets less than pro-rata");
        }

        (uint256[] memory aliceBefore, uint256 aliceIndexBefore) = _balances(alice);
        vm.prank(alice);
        uint256 shares = vault.deposit(s, q, 0, alice);
        assertApproxEqRel(shares, previewShares, 1e9, "the preview prices as the deposit does");
        _assertSpentWithinOneBps(aliceBefore, aliceIndexBefore, s, q);
        assertLt(_maxAllocationDeviationBps(), deviationBefore);
    }

    function test_redeem_proRata() public {
        _deposit(alice, 100e18);
        _fundAll(bob);
        _deposit(bob, 50e18);
        uint256 aliceShares = vault.balanceOf(alice);
        uint256 supply = vault.totalSupply();
        uint256 half = aliceShares / 2;
        (uint256[] memory positionStock, uint256[] memory positionIndex,,) = vault.holdings();
        (uint256[] memory previewStock, uint256[] memory previewIndex) = vault.previewRedeem(half);

        (uint256[] memory stockOut, uint256[] memory indexOut) = _redeem(alice, half, previewStock, previewIndex);
        uint256 indexOutTotal;
        for (uint256 i = 0; i < N; i++) {
            // half of alice's share of each position
            assertApproxEqAbs(stockOut[i], positionStock[i] * half / supply, 2);
            assertApproxEqAbs(indexOut[i], positionIndex[i] * half / supply, 2);
            // the preview is exact while nothing moves
            assertEq(stockOut[i], previewStock[i]);
            assertEq(indexOut[i], previewIndex[i]);
            indexOutTotal += indexOut[i];
        }
        assertEq(IERC20(QQQ).balanceOf(alice) - _lastIndexBalance, indexOutTotal);
        assertEq(vault.balanceOf(alice), aliceShares - half, "shares burned");
        assertEq(vault.totalSupply(), supply - half);
    }

    /// @dev Review focus 2: a pool pushed out of range holds one asset; redeem pays it, the other minimum at zero
    function test_redeem_outOfRangePool() public {
        _deposit(alice, 100e18);
        // MSFT is currency1: selling MSFT into the pool past tickUpper leaves the position all MSFT
        _swap(alice, MSFT, false, 200e18, TickMath.getSqrtPriceAtTick(pools[MSFT].tickUpper + 200));
        (, int24 tick) = _slot0(MSFT);
        assertGe(tick, pools[MSFT].tickUpper);
        (,,, uint16[] memory proximity) = vault.rangeStatus();
        assertGt(proximity[MSFT], 10_000, "reported out of range");
        (uint256[] memory positionStock, uint256[] memory positionIndex,,) = vault.holdings();
        assertGt(positionStock[MSFT], 0);
        assertEq(positionIndex[MSFT], 0);

        uint256 shares = vault.balanceOf(alice) / 2;
        (uint256[] memory previewStock, uint256[] memory previewIndex) = vault.previewRedeem(shares);
        assertEq(previewIndex[MSFT], 0);
        uint256 msftBefore = IERC20(pools[MSFT].stock).balanceOf(alice);
        (uint256[] memory stockOut, uint256[] memory indexOut) = _redeem(alice, shares, previewStock, previewIndex);
        assertGt(stockOut[MSFT], 0);
        assertEq(indexOut[MSFT], 0);
        assertEq(IERC20(pools[MSFT].stock).balanceOf(alice) - msftBefore, stockOut[MSFT]);
    }

    function test_collectFees_increasesNav() public {
        _deposit(alice, 100e18);
        uint256 navBefore = vault.nav();
        _roundTrip(NVDA, 2e18);
        assertEq(vault.nav(), navBefore, "accrued fees are not in nav until collected");

        vm.prank(bob); // permissionless
        vault.collectFees();
        assertGt(vault.nav(), navBefore);
        (,, uint256[] memory idleStock, uint256 idleIndex) = vault.holdings();
        assertGt(idleStock[NVDA], 0);
        assertGt(idleIndex, 0);
    }

    function test_pause_blocksDepositNotRedeem() public {
        uint256 shares = _deposit(alice, 100e18);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        vm.prank(alice);
        vault.setDepositsPaused(true);

        vm.expectEmit(address(vault));
        emit IIndexLpVault.DepositsPaused(true);
        vm.prank(owner);
        vault.setDepositsPaused(true);
        assertTrue(vault.depositsPaused());
        (uint256[] memory s, uint256[] memory q,) = vault.previewDeposit(10e18);
        vm.expectRevert(IIndexLpVault.DepositsArePaused.selector);
        vm.prank(alice);
        vault.deposit(s, q, 0, alice);

        uint256[] memory zeros = new uint256[](N);
        vm.prank(alice);
        vault.redeem(shares, zeros, zeros, alice);
        assertEq(vault.balanceOf(alice), 0);
        assertEq(vault.totalSupply(), 1000, "only the dead shares are left");

        vm.prank(owner);
        vault.setDepositsPaused(false);
        assertGt(_deposit(alice, 10e18), 0, "deposits resume");
    }

    function test_rerange_ownerOnly_and_recentres() public {
        _deposit(alice, 100e18);
        _movePrice(alice, NVDA, 11500); // +15%: still inside NVDA's +-25% range, but off centre
        uint256 oldId = vault.constituent(NVDA).tokenId;
        (int24 lower, int24 upper) = _centredRange(NVDA);

        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        vm.prank(alice);
        vault.rerange(NVDA, lower, upper);
        // the pool sits 15% off a reference the keeper has not moved yet
        vm.expectRevert(abi.encodeWithSelector(IIndexLpVault.PriceDeviation.selector, NVDA));
        vm.prank(owner);
        vault.rerange(NVDA, lower, upper);
        _syncReference(NVDA);

        uint256 navBefore = vault.nav();
        uint256 newId = IPositionManager(POSM).nextTokenId();
        vm.expectEmit(address(vault));
        emit IIndexLpVault.Reranged(NVDA, lower, upper, newId);
        vm.prank(owner);
        vault.rerange(NVDA, lower, upper);

        assertEq(vault.constituent(NVDA).tokenId, newId);
        assertEq(IERC721(POSM).ownerOf(newId), address(vault));
        assertGt(IPositionManager(POSM).getPositionLiquidity(newId), 0);
        // the old position is emptied into the vault; its NFT stays with the vault
        assertEq(IPositionManager(POSM).getPositionLiquidity(oldId), 0);
        assertEq(IERC721(POSM).ownerOf(oldId), address(vault));
        (, int24[] memory lowers, int24[] memory uppers, uint16[] memory proximity) = vault.rangeStatus();
        assertEq(lowers[NVDA], lower);
        assertEq(uppers[NVDA], upper);
        assertLt(proximity[NVDA], 100, "re-centred");
        assertGe(vault.nav() + N, navBefore, "nothing lost: fees collected, leftovers idle");
    }

    function test_rangeStatus_reportsProximity() public {
        _deposit(alice, 100e18);
        (int24[] memory ticks, int24[] memory lowers, int24[] memory uppers, uint16[] memory proximity) =
            vault.rangeStatus();
        for (uint256 i = 0; i < N; i++) {
            (, int24 tick) = _slot0(i);
            assertEq(ticks[i], tick);
            assertEq(lowers[i], pools[i].tickLower);
            assertEq(uppers[i], pools[i].tickUpper);
            assertLe(proximity[i], 50, "ranges are centred at mint");
        }

        _movePrice(alice, NVDA, 11000); // toward NVDA's upper edge
        (,,, uint16[] memory after_) = vault.rangeStatus();
        assertGt(after_[NVDA], proximity[NVDA]);
        assertLt(after_[NVDA], 10_000);
        (, int24 t) = _slot0(NVDA);
        int256 halfWidth = (int256(pools[NVDA].tickUpper) - pools[NVDA].tickLower) / 2;
        int256 expected = 10_000 * (halfWidth - (int256(pools[NVDA].tickUpper) - t)) / halfWidth;
        assertEq(uint256(after_[NVDA]), uint256(expected));
    }

    function test_holdings_matchesPositionsAndIdle() public {
        _deposit(alice, 100e18);
        _assertHoldingsMatch();

        _roundTrip(AAPL, 1e18);
        vault.collectFees();
        (,, uint256[] memory idleStock, uint256 idleIndex) = vault.holdings();
        for (uint256 i = 0; i < N; i++) {
            assertEq(idleStock[i], IERC20(pools[i].stock).balanceOf(address(vault)));
        }
        assertEq(idleIndex, IERC20(QQQ).balanceOf(address(vault)));
        assertGt(idleStock[AAPL], 0);
        assertGt(idleIndex, 0);
        _assertHoldingsMatch();
    }

    function test_setup_ownerOnlyAndIdempotent() public {
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        vm.prank(alice);
        vault.setup();
        vm.prank(owner);
        vault.setup();
        for (uint256 i = 0; i <= N; i++) {
            address token = i < N ? pools[i].stock : QQQ;
            assertEq(IERC20(token).allowance(address(vault), PERMIT2), type(uint256).max);
            (uint160 amount, uint48 expiration,) = IAllowanceTransfer(PERMIT2).allowance(address(vault), token, POSM);
            assertEq(amount, type(uint160).max);
            assertEq(expiration, type(uint48).max);
        }
    }

    function test_guards() public {
        _approveAll(alice);
        uint256[] memory zeros = new uint256[](N);
        vm.startPrank(alice);
        vm.expectRevert(IIndexLpVault.LengthMismatch.selector);
        vault.deposit(new uint256[](N - 1), zeros, 0, alice);
        vm.expectRevert(IIndexLpVault.ZeroShares.selector);
        vault.deposit(zeros, zeros, 0, alice);
        (uint256[] memory s, uint256[] memory q, uint256 expected) = vault.previewDeposit(10e18);
        vm.expectRevert(IIndexLpVault.SlippageExceeded.selector);
        vault.deposit(s, q, expected * 2, alice);
        uint256 shares = vault.deposit(s, q, expected * 999 / 1000, alice);

        vm.expectRevert(IIndexLpVault.LengthMismatch.selector);
        vault.redeem(shares, zeros, new uint256[](N + 1), alice);
        vm.expectRevert(IIndexLpVault.ZeroShares.selector);
        vault.redeem(0, zeros, zeros, alice);
        (uint256[] memory stockOut, uint256[] memory indexOut) = vault.previewRedeem(shares);
        stockOut[AAPL] += 1;
        vm.expectRevert(IIndexLpVault.SlippageExceeded.selector);
        vault.redeem(shares, stockOut, indexOut, alice);
        vm.stopPrank();
    }

    /// @dev tokenId bookkeeping: a deposit that gives some constituents no liquidity skips them, and a later deposit
    ///      mints exactly those, each id the PositionManager assigned to that constituent's pool
    function test_deposit_mintsSkippedConstituentsLater() public {
        _approveAll(alice);
        (uint256[] memory s, uint256[] memory q,) = vault.previewDeposit(100e18);
        for (uint256 i = 5; i < N; i++) {
            (s[i], q[i]) = (0, 0);
        }
        uint256 firstId = IPositionManager(POSM).nextTokenId();
        vm.prank(alice);
        vault.deposit(s, q, 0, alice);
        for (uint256 i = 0; i < N; i++) {
            assertEq(vault.constituent(i).tokenId, i < 5 ? firstId + i : 0);
        }

        uint256 secondId = IPositionManager(POSM).nextTokenId();
        (s, q,) = vault.previewDeposit(50e18);
        vm.prank(alice);
        vault.deposit(s, q, 0, alice);
        for (uint256 i = 0; i < N; i++) {
            uint256 tokenId = vault.constituent(i).tokenId;
            assertEq(tokenId, i < 5 ? firstId + i : secondId + i - 5);
            assertEq(IERC721(POSM).ownerOf(tokenId), address(vault));
            (PoolKey memory key,) = IPositionManager(POSM).getPoolAndPositionInfo(tokenId);
            assertEq(PoolId.unwrap(key.toId()), vault.constituent(i).poolId, "the id is this constituent's position");
        }
        _assertHoldingsMatch();
    }

    /// @dev With nothing to mint, rerange only moves the range; the next deposit mints there
    function test_rerange_beforeAnyDeposit_mintsLazilyAtTheNewRange() public {
        (int24 lower, int24 upper) = (pools[AAPL].tickLower - 100, pools[AAPL].tickUpper + 100);
        vm.expectEmit(address(vault));
        emit IIndexLpVault.Reranged(AAPL, lower, upper, 0);
        vm.prank(owner);
        vault.rerange(AAPL, lower, upper);
        assertEq(vault.constituent(AAPL).tokenId, 0);

        _deposit(alice, 100e18);
        IIndexLpVault.ConstituentView memory c = vault.constituent(AAPL);
        assertGt(c.tokenId, 0);
        (, PositionInfo info) = IPositionManager(POSM).getPoolAndPositionInfo(c.tokenId);
        assertEq(info.tickLower(), lower);
        assertEq(info.tickUpper(), upper);

        vm.expectRevert(abi.encodeWithSelector(IndexLpVault.InvalidRange.selector, AAPL));
        vm.prank(owner);
        vault.rerange(AAPL, lower + 5, upper);
    }

    /// @dev After fees sit idle, a redemption pays its share of every idle balance: the arrays add up to exactly what
    ///      arrives, the idle index share is spread over indexOut, and the payout is at least the preview
    function test_redeem_paysIdleBalancesProRata() public {
        _deposit(alice, 100e18);
        _roundTrip(NVDA, 2e18);
        vault.collectFees();
        (,, uint256[] memory idleStock, uint256 idleIndex) = vault.holdings();
        assertGt(idleStock[NVDA], 0);
        assertGt(idleIndex, 0);

        uint256 shares = vault.balanceOf(alice) / 3;
        uint256 supply = vault.totalSupply();
        _assertRedeemPaysWhatItReports(shares);
        (,, uint256[] memory idleStockAfter, uint256 idleIndexAfter) = vault.holdings();
        assertEq(idleStock[NVDA] - idleStockAfter[NVDA], idleStock[NVDA] * shares / supply);
        assertEq(idleIndex - idleIndexAfter, idleIndex * shares / supply);
    }

    /// @dev Preview and deposit price identically at fixed prices: first deposit and a later one
    function test_previewDeposit_sharesMatchDeposit() public {
        _approveAll(alice);
        (uint256[] memory s, uint256[] memory q, uint256 preview) = vault.previewDeposit(100e18);
        vm.prank(alice);
        uint256 shares = vault.deposit(s, q, 0, alice);
        emit log_named_uint("first deposit: |preview - minted| (share wei)", _absDiff(preview, shares));
        assertApproxEqRel(shares, preview, 1e9);

        _fundAll(bob);
        _approveAll(bob);
        (s, q, preview) = vault.previewDeposit(37e18);
        vm.prank(bob);
        shares = vault.deposit(s, q, 0, bob);
        emit log_named_uint("later deposit: |preview - minted| (share wei)", _absDiff(preview, shares));
        assertApproxEqRel(shares, preview, 1e9);
    }

    /// @dev The band is 1% in price either way from the hook reference, whichever side of the pair the stock is: just
    ///      past it the preview and the deposit revert `PriceDeviation(i)`, just inside the deposit goes through
    function test_deposit_priceBand() public {
        _deposit(alice, 100e18);
        _fundAll(bob);
        _approveAll(bob);
        (uint256[] memory s, uint256[] memory q,) = vault.previewDeposit(10e18);
        uint256[2] memory constituents = [NVDA, MSFT]; // the stock is currency0, then currency1
        for (uint256 k = 0; k < 2; k++) {
            _assertBand(constituents[k], 0.9899e18, false, s, q); // stock -1.01%
            _assertBand(constituents[k], 1.0102e18, false, s, q); // stock +1.02% (1/1.0102 < 0.99)
            _assertBand(constituents[k], 0.9901e18, true, s, q); // stock -0.99%
            _assertBand(constituents[k], 1.01e18, true, s, q); // stock +1.00% (1/1.01 > 0.99)
        }
    }

    function test_redeem_worksWithAPoolOutOfBand() public {
        uint256 shares = _deposit(alice, 100e18);
        _moveStockPrice(alice, 4, 0.95e18); // MU (stock is currency1), 5% under its reference
        vm.expectRevert(abi.encodeWithSelector(IIndexLpVault.PriceDeviation.selector, 4));
        vault.previewDeposit(1e18);
        (uint256[] memory previewStock, uint256[] memory previewIndex) = vault.previewRedeem(shares / 2);
        (uint256[] memory stockOut,) = _redeem(alice, shares / 2, previewStock, previewIndex);
        assertGt(stockOut[4], 0);
        assertEq(vault.balanceOf(alice), shares - shares / 2);
    }

    /// @dev Tokens already in the vault are not claimable by a first deposit that adds nothing, and the first deposit
    ///      mints only the value it added
    function test_firstDeposit_mintsOnTheValueAdded() public {
        vm.prank(alice);
        IERC20(QQQ).transfer(address(vault), 10e18);
        uint256[] memory zeros = new uint256[](N);
        vm.expectRevert(IIndexLpVault.ZeroShares.selector);
        vm.prank(bob);
        vault.deposit(zeros, zeros, 0, bob);

        uint256 shares = _deposit(alice, 50e18);
        assertEq(shares + 1000, vault.nav() - 10e18, "shares are the value added, not the vault's balance");
        assertEq(vault.totalSupply(), shares + 1000);
    }

    /// @dev Review cycle: push the five largest pools' stock prices down 10% through the PoolManager, deposit, let the
    ///      hook's corrective fee decay, swap back to the exact starting prices and redeem. The deposit is the shape that
    ///      profits from spot pricing (only the five pools left alone, bought into a depressed NAV; a routed deposit
    ///      mirrors the vault's own mix and gains nothing even at spot). The band is widened so the deposit goes through
    ///      at all: reference pricing alone leaves the attacker no gain.
    function test_manipulationCycle_netsTheAttackerNoGain() public {
        _deposit(alice, 100e18);
        vm.prank(owner);
        vault.setMaxDeviationBps(1500);
        _fundAll(bob);
        _approveAll(bob);
        uint160[5] memory start;
        for (uint256 i = 0; i < 5; i++) {
            (start[i],) = _slot0(i);
        }
        (uint256[] memory s, uint256[] memory q,) = vault.previewDeposit(100e18);
        for (uint256 i = 0; i < 5; i++) {
            (s[i], q[i]) = (0, 0);
        }
        uint256 before = _valueAtReference(bob);

        for (uint256 i = 0; i < 5; i++) {
            _moveStockPrice(bob, i, 0.9e18);
        }
        uint256 mid = _valueAtReference(bob);
        vm.prank(bob);
        uint256 shares = vault.deposit(s, q, 0, bob);
        uint256 deposited = mid - _valueAtReference(bob);

        vm.roll(block.number + 5000);
        for (uint256 i = 0; i < 5; i++) {
            _swapToPrice(bob, i, start[i]);
        }
        uint256 beforeRedeem = _valueAtReference(bob);
        uint256[] memory zeros = new uint256[](N);
        vm.prank(bob);
        vault.redeem(shares, zeros, zeros, bob);
        uint256 redeemed = _valueAtReference(bob) - beforeRedeem;
        uint256 after_ = _valueAtReference(bob);

        emit log_named_uint("attacker value before (QQQ wei)", before);
        emit log_named_uint("attacker value after  (QQQ wei)", after_);
        emit log_named_uint("deposited at reference (QQQ wei)", deposited);
        emit log_named_uint("redeemed at reference  (QQQ wei)", redeemed);
        assertLe(redeemed, deposited + 5 * N, "the deposit/redeem leg returns no more than it took");
        assertLe(after_, before + 5 * N, "the whole cycle nets the attacker nothing");
    }

    /// @dev At fixed prices, a deposit (routed or off-ratio, first or later) followed by redeeming every share it
    ///      minted never returns more value than it took, up to the floor rounding of the eleven valuations and of the
    ///      NAV difference (a few wei per constituent)
    /// forge-config: default.fuzz.runs = 32
    function testFuzz_depositThenRedeem_returnsNoMoreThanDeposited(uint256 indexValue, uint256 tiltBps, bool first)
        public
    {
        indexValue = bound(indexValue, 1e14, 100e18);
        tiltBps = bound(tiltBps, 5000, 15_000);
        if (!first) _deposit(alice, 100e18);
        _fundAll(bob);
        _approveAll(bob);
        (uint256[] memory s, uint256[] memory q,) = vault.previewDeposit(indexValue);
        for (uint256 i = 0; i < N; i++) {
            s[i] = s[i] * tiltBps / 10_000;
        }
        uint256 before = _valueAtReference(bob);
        vm.prank(bob);
        uint256 shares = vault.deposit(s, q, 0, bob);
        uint256[] memory zeros = new uint256[](N);
        vm.prank(bob);
        vault.redeem(shares, zeros, zeros, bob);
        assertLe(_valueAtReference(bob), before + 5 * N);
    }

    // ---------------------------------------------------------------------------------------------------------------

    uint256 internal _lastIndexBalance;

    /// @dev Redeems with minimums at 99.5% of the preview, as the page does; records the redeemer's prior index balance
    function _redeem(address who, uint256 shares, uint256[] memory previewStock, uint256[] memory previewIndex)
        internal
        returns (uint256[] memory stockOut, uint256[] memory indexOut)
    {
        uint256[] memory minStock = new uint256[](N);
        uint256[] memory minIndex = new uint256[](N);
        for (uint256 i = 0; i < N; i++) {
            minStock[i] = previewStock[i] * 995 / 1000;
            minIndex[i] = previewIndex[i] * 995 / 1000;
        }
        _lastIndexBalance = IERC20(QQQ).balanceOf(who);
        vm.prank(who);
        (stockOut, indexOut) = vault.redeem(shares, minStock, minIndex, who);
    }

    function _absDiff(uint256 a, uint256 b) internal pure returns (uint256) {
        return a > b ? a - b : b - a;
    }

    /// @dev Moves constituent i's stock price by `stockRatioWad` (in a state snapshot that is rolled back) and checks
    ///      whether bob's deposit of the in-band amounts goes through or reverts `PriceDeviation(i)`
    function _assertBand(uint256 i, uint256 stockRatioWad, bool inside, uint256[] memory s, uint256[] memory q)
        internal
    {
        uint256 snapshot = vm.snapshotState();
        _moveStockPrice(alice, i, stockRatioWad);
        if (inside) {
            vm.prank(bob);
            assertGt(vault.deposit(s, q, 0, bob), 0);
        } else {
            vm.expectRevert(abi.encodeWithSelector(IIndexLpVault.PriceDeviation.selector, i));
            vault.previewDeposit(1e18);
            vm.expectRevert(abi.encodeWithSelector(IIndexLpVault.PriceDeviation.selector, i));
            vm.prank(bob);
            vault.deposit(s, q, 0, bob);
        }
        vm.revertToState(snapshot);
    }

    /// @dev The arrays add up to exactly what arrives, and the payout is at least the preview (fees collected first)
    function _assertRedeemPaysWhatItReports(uint256 shares) internal {
        (uint256[] memory previewStock, uint256[] memory previewIndex) = vault.previewRedeem(shares);
        (uint256[] memory aliceBefore,) = _balances(alice);
        (uint256[] memory stockOut, uint256[] memory indexOut) = _redeem(alice, shares, previewStock, previewIndex);
        (uint256[] memory aliceAfter, uint256 aliceIndexAfter) = _balances(alice);
        uint256 indexOutTotal;
        for (uint256 i = 0; i < N; i++) {
            assertEq(aliceAfter[i] - aliceBefore[i], stockOut[i], "stock arrays add up to what arrives");
            assertGe(stockOut[i], previewStock[i]);
            assertGe(indexOut[i], previewIndex[i]);
            indexOutTotal += indexOut[i];
        }
        assertEq(aliceIndexAfter - _lastIndexBalance, indexOutTotal, "index arrays add up to what arrives");
    }

    /// @dev Sells `amountIn` of currency0 into pool i, then buys back to exactly the starting price: fees, no price effect
    function _roundTrip(uint256 i, uint256 amountIn) internal {
        (uint160 sqrtP0,) = _slot0(i);
        _swap(alice, i, true, amountIn, TickMath.MIN_SQRT_PRICE + 1);
        _swap(alice, i, false, IERC20(pools[i].currency1).balanceOf(alice) / 2, sqrtP0);
        (uint160 sqrtP1,) = _slot0(i);
        assertEq(sqrtP1, sqrtP0, "round trip restored the price");
    }

    function _assertSpentWithinOneBps(
        uint256[] memory stocksBefore,
        uint256 indexBefore,
        uint256[] memory s,
        uint256[] memory q
    ) internal view {
        (uint256[] memory stocksAfter, uint256 indexAfter) = _balances(alice);
        uint256 indexTotal;
        for (uint256 i = 0; i < N; i++) {
            if (s[i] != 0) assertApproxEqRel(stocksBefore[i] - stocksAfter[i], s[i], 1e14);
            indexTotal += q[i];
        }
        assertApproxEqRel(indexBefore - indexAfter, indexTotal, 1e14);
    }

    /// @dev holdings() equals getAmountsForLiquidity of each position within 1 wei, and its value sum equals nav()
    function _assertHoldingsMatch() internal view {
        (
            uint256[] memory positionStock,
            uint256[] memory positionIndex,
            uint256[] memory idleStock,
            uint256 idleIndex
        ) = vault.holdings();
        uint256 sum = idleIndex;
        for (uint256 i = 0; i < N; i++) {
            (uint256 stockAmount, uint256 indexAmount) = _positionAmounts(i);
            assertApproxEqAbs(positionStock[i], stockAmount, 1);
            assertApproxEqAbs(positionIndex[i], indexAmount, 1);
            sum += _valueOf(i, positionStock[i] + idleStock[i], positionIndex[i]);
        }
        assertApproxEqAbs(sum, vault.nav(), N);
    }

    function _positionAmounts(uint256 i) internal view returns (uint256 stockAmount, uint256 indexAmount) {
        IIndexLpVault.ConstituentView memory c = vault.constituent(i);
        (uint160 sqrtP,) = _slot0(i);
        (uint256 amount0, uint256 amount1) = LiquidityAmounts.getAmountsForLiquidity(
            sqrtP,
            TickMath.getSqrtPriceAtTick(c.tickLower),
            TickMath.getSqrtPriceAtTick(c.tickUpper),
            IPositionManager(POSM).getPositionLiquidity(c.tokenId)
        );
        (stockAmount, indexAmount) = pools[i].stockIsCurrency0 ? (amount0, amount1) : (amount1, amount0);
    }

    /// @dev Pool i's current range width, re-centred on its current tick and aligned to the tick spacing
    function _centredRange(uint256 i) internal view returns (int24 lower, int24 upper) {
        (, int24 tick) = _slot0(i);
        int24 spacing = pools[i].tickSpacing;
        int24 width = pools[i].tickUpper - pools[i].tickLower;
        int24 start = tick - width / 2;
        lower = start / spacing * spacing;
        if (start < 0 && start % spacing != 0) lower -= spacing;
        upper = lower + width;
    }
}

/// @notice Constructor validation; no fork needed (the constructor makes no calls), so this runs in CI
contract IndexLpVaultConstructorTest is Test {
    address constant POOL_MANAGER = 0x8366a39CC670B4001A1121B8F6A443A643e40951;
    address constant POSM = 0x58daec3116aae6D93017bAAea7749052E8a04fA7;
    address constant PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;
    address constant QQQ = 0xD5f3879160bc7c32ebb4dC785F8a4F505888de68;
    address constant HOOK = address(0xA0C0);
    address owner = makeAddr("owner");

    function test_constructor_acceptsTheFixture() public {
        IIndexLpVault.ConstituentInit[] memory inits = _inits();
        IndexLpVault vault = _deploy(inits);
        assertEq(vault.indexToken(), QQQ);
        assertEq(vault.owner(), owner);
        assertEq(vault.name(), "uniQQQ10");
        assertEq(vault.constituentCount(), inits.length);
        for (uint256 i = 0; i < inits.length; i++) {
            IIndexLpVault.ConstituentView memory c = vault.constituent(i);
            PoolKey memory key = PoolKey(
                Currency.wrap(inits[i].currency0),
                Currency.wrap(inits[i].currency1),
                inits[i].fee,
                inits[i].tickSpacing,
                IHooks(HOOK)
            );
            assertEq(c.stock, inits[i].stock);
            assertEq(c.poolId, PoolId.unwrap(PoolIdLibrary.toId(key)));
            assertEq(c.tokenId, 0, "positions are minted lazily");
            assertEq(c.targetBps, inits[i].targetBps);
            assertEq(c.tickLower, inits[i].tickLower);
            assertEq(c.tickUpper, inits[i].tickUpper);
        }
    }

    /// @dev CI's `forge build --sizes` skips any contract with a `setup()` function, so the limit is checked here
    function test_runtimeFitsTheContractSizeLimit() public {
        IndexLpVault vault = _deploy(_inits());
        emit log_named_uint("IndexLpVault runtime size (bytes)", address(vault).code.length);
        assertLe(address(vault).code.length, 24_576);
    }

    function test_setMaxDeviationBps_ownerOnlyAndBounded() public {
        IndexLpVault vault = _deploy(_inits());
        assertEq(vault.maxDeviationBps(), 100);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, address(this)));
        vault.setMaxDeviationBps(200);
        vm.startPrank(owner);
        vm.expectRevert(abi.encodeWithSelector(IndexLpVault.InvalidMaxDeviation.selector, 0));
        vault.setMaxDeviationBps(0);
        vm.expectRevert(abi.encodeWithSelector(IndexLpVault.InvalidMaxDeviation.selector, 10_000));
        vault.setMaxDeviationBps(10_000);
        vm.expectEmit(address(vault));
        emit IIndexLpVault.MaxDeviationBpsSet(9999);
        vault.setMaxDeviationBps(9999);
        vm.stopPrank();
        assertEq(vault.maxDeviationBps(), 9999);
    }

    function test_constructor_revertsWhenTargetsDoNotSumTo10000() public {
        IIndexLpVault.ConstituentInit[] memory inits = _inits();
        inits[3].targetBps += 1;
        vm.expectRevert(IndexLpVault.InvalidTargets.selector);
        _deploy(inits);
    }

    function test_constructor_revertsOnABadRange() public {
        IIndexLpVault.ConstituentInit[] memory inits = _inits();
        inits[4].tickLower += 5; // off the tick spacing
        vm.expectRevert(abi.encodeWithSelector(IndexLpVault.InvalidRange.selector, 4));
        _deploy(inits);

        inits = _inits();
        (inits[4].tickLower, inits[4].tickUpper) = (inits[4].tickUpper, inits[4].tickLower);
        vm.expectRevert(abi.encodeWithSelector(IndexLpVault.InvalidRange.selector, 4));
        _deploy(inits);

        inits = _inits();
        inits[4].tickUpper = 887_280; // past MAX_TICK
        vm.expectRevert(abi.encodeWithSelector(IndexLpVault.InvalidRange.selector, 4));
        _deploy(inits);
    }

    function test_constructor_revertsWhenAKeyLacksTheIndexToken() public {
        IIndexLpVault.ConstituentInit[] memory inits = _inits();
        // NVDA paired with AAPL instead of QQQ
        inits[0].currency1 = inits[1].stock;
        (inits[0].currency0, inits[0].currency1) = inits[0].currency0 < inits[0].currency1
            ? (inits[0].currency0, inits[0].currency1)
            : (inits[0].currency1, inits[0].currency0);
        vm.expectRevert(abi.encodeWithSelector(IndexLpVault.InvalidConstituent.selector, 0));
        _deploy(inits);
    }

    function test_constructor_revertsOnUnsortedCurrencies() public {
        IIndexLpVault.ConstituentInit[] memory inits = _inits();
        (inits[2].currency0, inits[2].currency1) = (inits[2].currency1, inits[2].currency0);
        vm.expectRevert(abi.encodeWithSelector(IndexLpVault.InvalidConstituent.selector, 2));
        _deploy(inits);
    }

    /// @dev A repeated stock would count its idle balance twice in nav()
    function test_constructor_revertsOnARepeatedStock() public {
        IIndexLpVault.ConstituentInit[] memory inits = _inits();
        // AMD's slot repeats NVDA's pool, keeping AMD's weight so the targets still sum to 10000
        IIndexLpVault.ConstituentInit memory nvda = inits[0];
        inits[5] = IIndexLpVault.ConstituentInit(
            nvda.stock,
            nvda.currency0,
            nvda.currency1,
            nvda.fee,
            nvda.tickSpacing,
            nvda.hooks,
            nvda.tickLower,
            nvda.tickUpper,
            inits[5].targetBps
        );
        vm.expectRevert(abi.encodeWithSelector(IndexLpVault.InvalidConstituent.selector, 5));
        _deploy(inits);
    }

    function _deploy(IIndexLpVault.ConstituentInit[] memory inits) internal returns (IndexLpVault) {
        return new IndexLpVault(IPoolManager(POOL_MANAGER), POSM, PERMIT2, QQQ, inits, "uniQQQ10", "uniQQQ10", owner);
    }

    function _inits() internal view returns (IIndexLpVault.ConstituentInit[] memory inits) {
        PoolEntry[] memory pools = PoolConfigLib.load(vm, "test/index/fixtures/pools.qqq10.json");
        inits = new IIndexLpVault.ConstituentInit[](pools.length);
        for (uint256 i = 0; i < pools.length; i++) {
            inits[i] = IIndexLpVault.ConstituentInit(
                pools[i].stock,
                pools[i].currency0,
                pools[i].currency1,
                pools[i].fee,
                pools[i].tickSpacing,
                HOOK,
                pools[i].tickLower,
                pools[i].tickUpper,
                pools[i].targetBps
            );
        }
    }
}

/// @notice Exposes IndexVaultMath to unit tests
contract IndexVaultMathHarness {
    function stockToIndex(bool stockIsCurrency0, uint256 amount, uint160 sqrtPriceX96) external pure returns (uint256) {
        return IndexVaultMath.stockToIndex(stockIsCurrency0, amount, sqrtPriceX96);
    }

    function amountsForLiquidity(uint160 sqrtPriceX96, uint160 sqrtPriceAX96, uint160 sqrtPriceBX96, uint128 liquidity)
        external
        pure
        returns (uint256, uint256)
    {
        return IndexVaultMath.amountsForLiquidity(sqrtPriceX96, sqrtPriceAX96, sqrtPriceBX96, liquidity);
    }

    function edgeProximityBps(int24 tick, int24 tickLower, int24 tickUpper) external pure returns (uint16) {
        return IndexVaultMath.edgeProximityBps(tick, tickLower, tickUpper);
    }

    function withinBand(uint160 sqrtPriceX96, uint160 referenceSqrtPriceX96, uint256 maxDeviationBps)
        external
        pure
        returns (bool)
    {
        return IndexVaultMath.withinBand(sqrtPriceX96, referenceSqrtPriceX96, maxDeviationBps);
    }
}

/// @notice The valuation and range math, no fork needed
contract IndexLpVaultMathTest is Test {
    IndexVaultMathHarness harness;

    function setUp() public {
        harness = new IndexVaultMathHarness();
    }

    /// @dev 18-decimal amounts up to 1e12 whole tokens value without overflow at both price extremes
    function test_stockToIndex_noOverflowAtPriceExtremes() public view {
        uint256 amount = 1e30;
        // ~ amount × 2^128 at the top: finite, no FullMath overflow
        assertApproxEqRel(
            harness.stockToIndex(true, amount, TickMath.MAX_SQRT_PRICE),
            FullMath.mulDiv(amount, uint256(TickMath.MAX_SQRT_PRICE >> 64) ** 2, 1 << 64),
            1e9
        );
        assertGt(harness.stockToIndex(false, amount, TickMath.MIN_SQRT_PRICE), amount);
        assertEq(harness.stockToIndex(true, amount, TickMath.MIN_SQRT_PRICE), 0);
        assertEq(harness.stockToIndex(false, amount, TickMath.MAX_SQRT_PRICE), 0);
        assertEq(harness.stockToIndex(true, amount, 0), 0, "uninitialized pool");
    }

    function test_stockToIndex_atPriceOneAndFour() public view {
        uint160 one = uint160(1 << 96);
        assertEq(harness.stockToIndex(true, 5e18, one), 5e18);
        assertEq(harness.stockToIndex(false, 5e18, one), 5e18);
        // sqrtP = 2 => P = 4 currency1 per currency0
        assertEq(harness.stockToIndex(true, 5e18, 2 * one), 20e18);
        assertEq(harness.stockToIndex(false, 20e18, 2 * one), 5e18);
    }

    /// forge-config: default.fuzz.runs = 512
    function testFuzz_amountsForLiquidity_matchesReference(uint160 sqrtP, int24 tickA, int24 tickB, uint128 liquidity)
        public
        view
    {
        sqrtP = uint160(bound(sqrtP, TickMath.MIN_SQRT_PRICE, TickMath.MAX_SQRT_PRICE - 1));
        tickA = int24(bound(tickA, TickMath.MIN_TICK, TickMath.MAX_TICK - 1));
        tickB = int24(bound(tickB, tickA + 1, TickMath.MAX_TICK));
        liquidity = uint128(bound(liquidity, 0, type(uint96).max));
        uint160 sqrtA = TickMath.getSqrtPriceAtTick(tickA);
        uint160 sqrtB = TickMath.getSqrtPriceAtTick(tickB);
        (uint256 a0, uint256 a1) = harness.amountsForLiquidity(sqrtP, sqrtA, sqrtB, liquidity);
        (uint256 e0, uint256 e1) = LiquidityAmounts.getAmountsForLiquidity(sqrtP, sqrtA, sqrtB, liquidity);
        assertEq(a0, e0);
        assertEq(a1, e1);
    }

    function test_edgeProximityBps() public view {
        assertEq(harness.edgeProximityBps(0, -100, 100), 0, "centre");
        assertEq(harness.edgeProximityBps(50, -100, 100), 5000, "half way to the upper edge");
        assertEq(harness.edgeProximityBps(-100, -100, 100), 10_000, "at the lower edge");
        assertEq(harness.edgeProximityBps(100, -100, 100), 10_000, "at the upper edge");
        assertEq(harness.edgeProximityBps(150, -100, 100), 15_000, "half a half-width out of range");
        assertEq(harness.edgeProximityBps(TickMath.MIN_TICK, -100, 100), 20_000, "clamped");
        assertEq(harness.edgeProximityBps(0, 0, 1), 10_000, "width 1 does not divide by zero");
    }

    /// @dev 1% band in price, either direction, from a reference at price 1 (and at a price far from 1)
    function test_withinBand_boundaries() public view {
        uint160 one = uint160(1 << 96);
        assertTrue(harness.withinBand(one, one, 100));
        assertTrue(harness.withinBand(_sqrtPriceOf(0.9901e18, one), one, 100), "-0.99%");
        assertFalse(harness.withinBand(_sqrtPriceOf(0.9899e18, one), one, 100), "-1.01%");
        assertTrue(harness.withinBand(_sqrtPriceOf(1.01e18, one), one, 100), "+1.00%: 1/1.01 > 0.99");
        assertFalse(harness.withinBand(_sqrtPriceOf(1.0102e18, one), one, 100), "+1.02%: 1/1.0102 < 0.99");
        uint160 far = TickMath.getSqrtPriceAtTick(-200_000);
        assertTrue(harness.withinBand(_sqrtPriceOf(1.0099e18, far), far, 100));
        assertFalse(harness.withinBand(_sqrtPriceOf(0.98e18, far), far, 100));
        assertTrue(harness.withinBand(_sqrtPriceOf(0.98e18, far), far, 300), "wider band");
        assertFalse(harness.withinBand(0, one, 100), "uninitialized pool");
        assertFalse(harness.withinBand(one, 0, 100), "no reference");
    }

    /// @dev The sqrt price of `ratioWad / 1e18` times the price at `sqrtPriceX96`
    function _sqrtPriceOf(uint256 ratioWad, uint160 sqrtPriceX96) internal pure returns (uint160) {
        uint256 root = ratioWad;
        uint256 z = (ratioWad + 1) / 2;
        while (z < root) {
            root = z;
            z = (ratioWad / z + z) / 2;
        }
        return uint160(FullMath.mulDiv(sqrtPriceX96, root, 1e9));
    }
}
