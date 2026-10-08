// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {FixedPoint96} from "@uniswap/v4-core/src/libraries/FixedPoint96.sol";
import {SqrtPriceMath} from "@uniswap/v4-core/src/libraries/SqrtPriceMath.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {Actions} from "@uniswap/v4-periphery/src/libraries/Actions.sol";
import {LiquidityAmounts} from "@uniswap/v4-periphery/src/libraries/LiquidityAmounts.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";
import {IIndexLpVault} from "./interfaces/IIndexLpVault.sol";

/// @title IndexLpVault
/// @notice Holds one v4 PositionManager position per `stock / index token` pool and issues itself as the share token.
///         Deposits bring both tokens of every pool (`previewDeposit` routes value toward the target weights), mint or
///         increase the positions in one `modifyLiquidities` call and return whatever the positions did not take.
///         Redemptions pay the same fraction of every position and idle balance and are never paused.
/// @dev Values use each pool's spot price: the owner-free paths (deposit, redeem) are protected by the caller's
///      `minShares` / per-token minimums, not by an oracle.
contract IndexLpVault is IIndexLpVault, ERC20, Ownable2Step, ReentrancyGuardTransient {
    using SafeERC20 for IERC20;
    using SafeCast for uint256;
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    /// @dev `tokenId` is 0 until a deposit (or `rerange`) gives the constituent liquidity
    struct Constituent {
        PoolKey key;
        bool stockIsCurrency0;
        uint16 targetBps;
        int24 tickLower;
        int24 tickUpper;
        uint256 tokenId;
    }

    /// @dev Pool prices, position liquidity and idle balances, read once per call and kept current by the call
    struct Snapshot {
        uint160[] sqrtPriceX96;
        uint128[] liquidity;
        uint256[] idleStock;
        uint256 idleIndex;
    }

    /// @dev What a redemption of some shares pays, per constituent
    struct Payout {
        uint256[] stockOut;
        uint256[] indexOut;
        uint128[] liquidity;
        uint256[] idleStock;
        uint256 idleIndex;
    }

    uint256 internal constant BPS = 10_000;
    /// @dev Value of a position is computed per this much liquidity to turn a value into liquidity
    uint128 internal constant UNIT_LIQUIDITY = 1e18;
    address internal constant DEAD = address(0xdead);
    /// @notice A constituent is in band while |bps − targetBps| ≤ BAND_BPS × targetBps / 10000 (±25% of its target)
    uint256 public constant BAND_BPS = 2500;
    /// @notice Shares minted to 0xdead by the first deposit, so the share price cannot be inflated from a dust supply
    uint256 public constant DEAD_SHARES = 1000;

    IPoolManager public immutable poolManager;
    IPositionManager public immutable positionManager;
    IAllowanceTransfer public immutable permit2;
    /// @inheritdoc IIndexLpVault
    address public immutable indexToken;

    bool public depositsPaused;
    Constituent[] internal _constituents;

    /// @notice The constituents' target weights do not sum to 10000
    error InvalidTargets();
    /// @notice Constituent i's range is inverted, off its tick spacing or outside the usable ticks
    error InvalidRange(uint256 i);
    /// @notice Constituent i's key does not sort its currencies, does not pair its stock with the index token, or
    ///         repeats an earlier constituent's stock
    error InvalidConstituent(uint256 i);
    /// @notice Shares exist but the vault holds nothing to price a deposit against
    error ZeroNav();

    /// @param positionManager_ The v4 PositionManager the positions are minted on
    /// @param permit2_ Permit2, through which the PositionManager pulls the vault's tokens
    /// @param indexToken_ The token every pool pairs with; all values are expressed in it
    /// @param inits The constituents, their target weights summing to 10000
    constructor(
        IPoolManager poolManager_,
        address positionManager_,
        address permit2_,
        address indexToken_,
        ConstituentInit[] memory inits,
        string memory name_,
        string memory symbol_,
        address owner_
    ) ERC20(name_, symbol_) Ownable(owner_) {
        poolManager = poolManager_;
        positionManager = IPositionManager(positionManager_);
        permit2 = IAllowanceTransfer(permit2_);
        indexToken = indexToken_;
        uint256 totalBps;
        for (uint256 i; i < inits.length; ++i) {
            ConstituentInit memory init = inits[i];
            _validateConstituent(i, init, indexToken_);
            for (uint256 j; j < i; ++j) {
                if (inits[j].stock == init.stock) revert InvalidConstituent(i);
            }
            totalBps += init.targetBps;
            _constituents.push(
                Constituent({
                    key: PoolKey(
                        Currency.wrap(init.currency0),
                        Currency.wrap(init.currency1),
                        init.fee,
                        init.tickSpacing,
                        IHooks(init.hooks)
                    ),
                    stockIsCurrency0: init.currency0 == init.stock,
                    targetBps: init.targetBps,
                    tickLower: init.tickLower,
                    tickUpper: init.tickUpper,
                    tokenId: 0
                })
            );
        }
        if (totalBps != BPS) revert InvalidTargets();
    }

    // ------------------------------------------------------------------------------------------------- views

    function constituentCount() external view returns (uint256) {
        return _constituents.length;
    }

    function constituent(uint256 i) external view returns (ConstituentView memory) {
        Constituent storage c = _constituents[i];
        return ConstituentView({
            stock: _stock(c),
            poolId: PoolId.unwrap(c.key.toId()),
            tokenId: c.tokenId,
            targetBps: c.targetBps,
            tickLower: c.tickLower,
            tickUpper: c.tickUpper
        });
    }

    /// @inheritdoc IIndexLpVault
    function nav() external view returns (uint256 navInIndex) {
        (, navInIndex) = _values(_snapshot());
    }

    /// @inheritdoc IIndexLpVault
    function allocations()
        external
        view
        returns (uint256[] memory valueInIndex, uint16[] memory bps, bool[] memory inBand)
    {
        uint256 total;
        (valueInIndex, total) = _values(_snapshot());
        uint256 n = valueInIndex.length;
        bps = new uint16[](n);
        inBand = new bool[](n);
        for (uint256 i; i < n; ++i) {
            uint256 actual = total == 0 ? 0 : valueInIndex[i] * BPS / total;
            uint256 target = _constituents[i].targetBps;
            bps[i] = uint16(actual);
            inBand[i] = (actual > target ? actual - target : target - actual) * BPS <= BAND_BPS * target;
        }
    }

    /// @inheritdoc IIndexLpVault
    function rangeStatus()
        external
        view
        returns (
            int24[] memory currentTick,
            int24[] memory lower,
            int24[] memory upper,
            uint16[] memory edgeProximityBps
        )
    {
        uint256 n = _constituents.length;
        currentTick = new int24[](n);
        lower = new int24[](n);
        upper = new int24[](n);
        edgeProximityBps = new uint16[](n);
        for (uint256 i; i < n; ++i) {
            Constituent storage c = _constituents[i];
            (, int24 tick,,) = poolManager.getSlot0(c.key.toId());
            (currentTick[i], lower[i], upper[i]) = (tick, c.tickLower, c.tickUpper);
            edgeProximityBps[i] = _edgeProximityBps(tick, c.tickLower, c.tickUpper);
        }
    }

    /// @inheritdoc IIndexLpVault
    /// @dev The first deposit's shares are its NAV after (idle donations included) less the dead shares
    function previewDeposit(uint256 indexValue)
        external
        view
        returns (uint256[] memory stockAmounts, uint256[] memory indexAmounts, uint256 shares)
    {
        Snapshot memory s = _snapshot();
        (uint256[] memory values, uint256 navNow) = _values(s);
        uint256[] memory alloc = _route(indexValue, navNow, values);
        uint256 n = alloc.length;
        stockAmounts = new uint256[](n);
        indexAmounts = new uint256[](n);
        for (uint256 i; i < n; ++i) {
            (stockAmounts[i], indexAmounts[i]) = _amountsForValue(_constituents[i], s.sqrtPriceX96[i], alloc[i]);
        }
        uint256 supply = totalSupply();
        if (supply == 0) {
            shares = navNow + indexValue > DEAD_SHARES ? navNow + indexValue - DEAD_SHARES : 0;
        } else if (navNow != 0) {
            shares = FullMath.mulDiv(indexValue, supply, navNow);
        }
    }

    /// @inheritdoc IIndexLpVault
    /// @dev `stockOut[i]` adds the share of the idle stock to the position's stock; the share of the idle index token
    ///      is split across `indexOut` by target weight. Fees accrued since the last collection are not included (the
    ///      redemption collects them first, so it pays at least this).
    function previewRedeem(uint256 shares)
        external
        view
        returns (uint256[] memory stockOut, uint256[] memory indexOut)
    {
        Payout memory p = _payout(_snapshot(), shares, totalSupply());
        return (p.stockOut, p.indexOut);
    }

    /// @inheritdoc IIndexLpVault
    function holdings()
        external
        view
        returns (
            uint256[] memory positionStock,
            uint256[] memory positionIndex,
            uint256[] memory idleStock,
            uint256 idleIndex
        )
    {
        Snapshot memory s = _snapshot();
        uint256 n = s.liquidity.length;
        positionStock = new uint256[](n);
        positionIndex = new uint256[](n);
        for (uint256 i; i < n; ++i) {
            (positionStock[i], positionIndex[i]) = _positionAmounts(_constituents[i], s.sqrtPriceX96[i], s.liquidity[i]);
        }
        (idleStock, idleIndex) = (s.idleStock, s.idleIndex);
    }

    // ------------------------------------------------------------------------------------------------- actions

    /// @inheritdoc IIndexLpVault
    /// @dev Fees are collected first so the deposit is priced against a NAV that includes them. The tokens a position
    ///      does not take stay in the vault after the PositionManager's Permit2 pulls, so they are refunded from here
    ///      (a PositionManager SWEEP would find nothing to sweep).
    function deposit(uint256[] calldata stockAmounts, uint256[] calldata indexAmounts, uint256 minShares, address to)
        external
        nonReentrant
        returns (uint256 shares)
    {
        if (depositsPaused) revert DepositsArePaused();
        uint256 n = _constituents.length;
        if (stockAmounts.length != n || indexAmounts.length != n) revert LengthMismatch();
        (Snapshot memory s, uint256 navBefore) = _collectFees();
        uint256 supply = totalSupply();

        _pull(stockAmounts, indexAmounts);
        uint128[] memory added = _addLiquidity(s.sqrtPriceX96, stockAmounts, indexAmounts);
        _refund(s);

        // prices did not move and idle balances are back where they were: only the positions grew
        for (uint256 i; i < n; ++i) {
            s.liquidity[i] += added[i];
        }
        (, uint256 navAfter) = _values(s);
        shares = _mintShares(to, supply, navBefore, navAfter, minShares);
        emit Deposit(msg.sender, to, shares, navAfter);
    }

    /// @inheritdoc IIndexLpVault
    /// @dev The minimums apply to the returned per-constituent amounts (position plus idle share), which equal what the
    ///      pool pays: the same round-down amounts at the same price the decrease executes at.
    function redeem(uint256 shares, uint256[] calldata minStock, uint256[] calldata minIndex, address to)
        external
        nonReentrant
        returns (uint256[] memory stockOut, uint256[] memory indexOut)
    {
        uint256 n = _constituents.length;
        if (minStock.length != n || minIndex.length != n) revert LengthMismatch();
        if (shares == 0) revert ZeroShares();
        (Snapshot memory s,) = _collectFees();
        Payout memory p = _payout(s, shares, totalSupply());
        for (uint256 i; i < n; ++i) {
            if (p.stockOut[i] < minStock[i] || p.indexOut[i] < minIndex[i]) revert SlippageExceeded();
        }

        _burn(msg.sender, shares);
        _decreaseAndTake(p.liquidity, false, to);
        _payIdle(p, to);

        for (uint256 i; i < n; ++i) {
            s.liquidity[i] -= p.liquidity[i];
            s.idleStock[i] -= p.idleStock[i];
        }
        s.idleIndex -= p.idleIndex;
        (, uint256 navAfter) = _values(s);
        emit Redeem(msg.sender, to, shares, navAfter);
        return (p.stockOut, p.indexOut);
    }

    /// @inheritdoc IIndexLpVault
    function collectFees() external nonReentrant {
        _collectFees();
    }

    /// @inheritdoc IIndexLpVault
    function setup() external onlyOwner {
        uint256 n = _constituents.length;
        for (uint256 i; i <= n; ++i) {
            address token = i < n ? _stock(_constituents[i]) : indexToken;
            IERC20(token).forceApprove(address(permit2), type(uint256).max);
            permit2.approve(token, address(positionManager), type(uint160).max, type(uint48).max);
        }
    }

    /// @inheritdoc IIndexLpVault
    function setDepositsPaused(bool paused) external onlyOwner {
        depositsPaused = paused;
        emit DepositsPaused(paused);
    }

    /// @inheritdoc IIndexLpVault
    /// @dev Burns the old position (its NFT goes away) and mints with the vault's whole balance of both tokens as the
    ///      maximums, so what the new range cannot take stays idle. Liquidity 0 leaves `tokenId` 0 for the next deposit.
    function rerange(uint256 i, int24 tickLower, int24 tickUpper) external onlyOwner nonReentrant {
        Constituent storage c = _constituents[i];
        _checkRange(i, tickLower, tickUpper, c.key.tickSpacing);
        _collectFees();
        if (c.tokenId != 0) _burnPosition(c);
        (c.tickLower, c.tickUpper) = (tickLower, tickUpper);
        c.tokenId = _mintFromBalances(c);
        emit Reranged(i, tickLower, tickUpper, c.tokenId);
    }

    // ------------------------------------------------------------------------------------------------- internals

    /// @dev DECREASE_LIQUIDITY(tokenId, 0) + TAKE_PAIR to the vault for every position holding liquidity (a 0-decrease
    ///      on an empty position reverts in the pool), then re-reads the idle balances
    /// @return s The state after collection
    /// @return navNow The NAV after collection, as emitted
    function _collectFees() internal returns (Snapshot memory s, uint256 navNow) {
        s = _snapshot();
        if (_decreaseAndTake(s.liquidity, true, address(this))) _readIdle(s);
        (, navNow) = _values(s);
        emit FeesCollected(navNow);
    }

    /// @dev One DECREASE_LIQUIDITY per constituent with `liquidity[i] != 0` (of `liquidity[i]`, or 0 when `feesOnly`),
    ///      then a TAKE_PAIR of each one's currencies to `recipient`; the first TAKE_PAIR takes the index token owed by
    ///      all of them, so it moves once. Returns whether any action ran.
    function _decreaseAndTake(uint128[] memory liquidity, bool feesOnly, address recipient)
        internal
        returns (bool touched)
    {
        uint256 n = liquidity.length;
        bytes memory actions = new bytes(2 * n);
        bytes[] memory params = new bytes[](2 * n);
        uint256 k;
        for (uint256 i; i < n; ++i) {
            if (liquidity[i] == 0) continue;
            actions[k] = bytes1(uint8(Actions.DECREASE_LIQUIDITY));
            params[k++] = _modifyParams(_constituents[i].tokenId, feesOnly ? 0 : liquidity[i], 0, 0);
        }
        for (uint256 i; i < n; ++i) {
            if (liquidity[i] == 0) continue;
            actions[k] = bytes1(uint8(Actions.TAKE_PAIR));
            params[k++] = _takePairParams(_constituents[i].key, recipient);
        }
        touched = k != 0;
        _modify(actions, params, k);
    }

    /// @dev One MINT_POSITION (first use; the i-th mint of the call gets `nextTokenId + i`) or INCREASE_LIQUIDITY per
    ///      constituent the amounts give liquidity, the amounts as maximums, then a SETTLE_PAIR per such constituent
    ///      (the index token is settled once, by the first). Constituents left at liquidity 0 are skipped.
    function _addLiquidity(
        uint160[] memory sqrtPriceX96,
        uint256[] calldata stockAmounts,
        uint256[] calldata indexAmounts
    ) internal returns (uint128[] memory added) {
        uint256 n = sqrtPriceX96.length;
        added = new uint128[](n);
        bytes memory actions = new bytes(2 * n);
        bytes[] memory params = new bytes[](2 * n);
        uint256 k;
        uint256 nextId = positionManager.nextTokenId();
        for (uint256 i; i < n; ++i) {
            bool minted;
            (added[i], minted, params[k]) =
                _addAction(_constituents[i], sqrtPriceX96[i], stockAmounts[i], indexAmounts[i], nextId);
            if (added[i] == 0) continue;
            actions[k++] = bytes1(uint8(minted ? Actions.MINT_POSITION : Actions.INCREASE_LIQUIDITY));
            if (minted) ++nextId;
        }
        for (uint256 i; i < n; ++i) {
            if (added[i] == 0) continue;
            actions[k] = bytes1(uint8(Actions.SETTLE_PAIR));
            params[k++] = abi.encode(_constituents[i].key.currency0, _constituents[i].key.currency1);
        }
        _modify(actions, params, k);
    }

    /// @dev The liquidity the amounts buy at `sqrtPriceX96` and its action: MINT_POSITION (recording `nextId` as the
    ///      constituent's token id) when it has no position yet, INCREASE_LIQUIDITY otherwise; the amounts are maximums
    function _addAction(
        Constituent storage c,
        uint160 sqrtPriceX96,
        uint256 stockAmount,
        uint256 indexAmount,
        uint256 nextId
    ) internal returns (uint128 liquidity, bool minted, bytes memory params) {
        (uint256 amount0, uint256 amount1) =
            c.stockIsCurrency0 ? (stockAmount, indexAmount) : (indexAmount, stockAmount);
        liquidity = _liquidityForAmounts(c, sqrtPriceX96, amount0, amount1);
        if (liquidity == 0) return (0, false, params);
        minted = c.tokenId == 0;
        if (minted) c.tokenId = nextId;
        params = minted
            ? _mintParams(c, liquidity, amount0, amount1)
            : _modifyParams(c.tokenId, liquidity, amount0, amount1);
    }

    /// @dev BURN_POSITION (removes any liquidity left, fees included) + TAKE_PAIR to the vault
    function _burnPosition(Constituent storage c) internal {
        bytes[] memory params = new bytes[](2);
        params[0] = abi.encode(c.tokenId, uint128(0), uint128(0), bytes(""));
        params[1] = _takePairParams(c.key, address(this));
        _modify(abi.encodePacked(uint8(Actions.BURN_POSITION), uint8(Actions.TAKE_PAIR)), params, 2);
    }

    /// @dev MINT_POSITION over the constituent's (new) range with the vault's balances of its two tokens as maximums
    ///      + SETTLE_PAIR. Returns the new token id, or 0 when the balances give no liquidity.
    function _mintFromBalances(Constituent storage c) internal returns (uint256 tokenId) {
        (uint160 sqrtPriceX96,,,) = poolManager.getSlot0(c.key.toId());
        uint256 amount0 = IERC20(Currency.unwrap(c.key.currency0)).balanceOf(address(this));
        uint256 amount1 = IERC20(Currency.unwrap(c.key.currency1)).balanceOf(address(this));
        uint128 liquidity = _liquidityForAmounts(c, sqrtPriceX96, amount0, amount1);
        if (liquidity == 0) return 0;
        tokenId = positionManager.nextTokenId();
        bytes[] memory params = new bytes[](2);
        params[0] = _mintParams(c, liquidity, amount0, amount1);
        params[1] = abi.encode(c.key.currency0, c.key.currency1);
        _modify(abi.encodePacked(uint8(Actions.MINT_POSITION), uint8(Actions.SETTLE_PAIR)), params, 2);
    }

    /// @dev Runs the first `count` actions in one unlock; a no-op for 0
    function _modify(bytes memory actions, bytes[] memory params, uint256 count) internal {
        if (count == 0) return;
        assembly ("memory-safe") {
            mstore(actions, count)
            mstore(params, count)
        }
        positionManager.modifyLiquidities(abi.encode(actions, params), block.timestamp);
    }

    function _mintParams(Constituent storage c, uint128 liquidity, uint256 amount0Max, uint256 amount1Max)
        internal
        view
        returns (bytes memory)
    {
        PoolKey memory key = c.key;
        return abi.encode(
            key,
            c.tickLower,
            c.tickUpper,
            uint256(liquidity),
            amount0Max.toUint128(),
            amount1Max.toUint128(),
            address(this),
            bytes("")
        );
    }

    /// @dev INCREASE_LIQUIDITY (amounts are maximums) and DECREASE_LIQUIDITY (amounts are minimums) share a layout
    function _modifyParams(uint256 tokenId, uint128 liquidity, uint256 amount0, uint256 amount1)
        internal
        pure
        returns (bytes memory)
    {
        return abi.encode(tokenId, uint256(liquidity), amount0.toUint128(), amount1.toUint128(), bytes(""));
    }

    function _takePairParams(PoolKey storage key, address recipient) internal view returns (bytes memory) {
        return abi.encode(key.currency0, key.currency1, recipient);
    }

    /// @dev Pulls each stock amount and the index amounts' sum from the caller
    function _pull(uint256[] calldata stockAmounts, uint256[] calldata indexAmounts) internal {
        uint256 indexTotal;
        for (uint256 i; i < stockAmounts.length; ++i) {
            indexTotal += indexAmounts[i];
            if (stockAmounts[i] != 0) {
                IERC20(_stock(_constituents[i])).safeTransferFrom(msg.sender, address(this), stockAmounts[i]);
            }
        }
        if (indexTotal != 0) IERC20(indexToken).safeTransferFrom(msg.sender, address(this), indexTotal);
    }

    /// @dev Returns to the caller every token balance above its pre-deposit level (`s` was read before the pull). The
    ///      subtraction reverts if a deposit ever dipped into the vault's own idle balances.
    function _refund(Snapshot memory s) internal {
        uint256 n = s.idleStock.length;
        for (uint256 i; i < n; ++i) {
            _refundExcess(_stock(_constituents[i]), s.idleStock[i]);
        }
        _refundExcess(indexToken, s.idleIndex);
    }

    function _refundExcess(address token, uint256 idleBefore) internal {
        uint256 excess = IERC20(token).balanceOf(address(this)) - idleBefore;
        if (excess != 0) IERC20(token).safeTransfer(msg.sender, excess);
    }

    function _payIdle(Payout memory p, address to) internal {
        uint256 n = p.idleStock.length;
        for (uint256 i; i < n; ++i) {
            if (p.idleStock[i] != 0) IERC20(_stock(_constituents[i])).safeTransfer(to, p.idleStock[i]);
        }
        if (p.idleIndex != 0) IERC20(indexToken).safeTransfer(to, p.idleIndex);
    }

    /// @dev First deposit: its NAV in shares, `DEAD_SHARES` of them to 0xdead. Later: the NAV it added at the NAV per
    ///      share before it, rounded down.
    function _mintShares(address to, uint256 supply, uint256 navBefore, uint256 navAfter, uint256 minShares)
        internal
        returns (uint256 shares)
    {
        if (supply == 0) {
            shares = navAfter > DEAD_SHARES ? navAfter - DEAD_SHARES : 0;
        } else {
            if (navBefore == 0) revert ZeroNav();
            shares = FullMath.mulDiv(navAfter - navBefore, supply, navBefore);
        }
        if (shares == 0) revert ZeroShares();
        if (shares < minShares) revert SlippageExceeded();
        if (supply == 0) _mint(DEAD, DEAD_SHARES);
        _mint(to, shares);
    }

    /// @dev `shares / supply` of every position's liquidity and idle balance, rounded down; the idle index token's share
    ///      is attributed to the constituents by target weight (the last takes the rounding remainder)
    function _payout(Snapshot memory s, uint256 shares, uint256 supply) internal view returns (Payout memory p) {
        uint256 n = s.liquidity.length;
        p.stockOut = new uint256[](n);
        p.indexOut = new uint256[](n);
        p.liquidity = new uint128[](n);
        p.idleStock = new uint256[](n);
        if (supply == 0) return p;
        p.idleIndex = FullMath.mulDiv(s.idleIndex, shares, supply);
        uint256 idleIndexLeft = p.idleIndex;
        for (uint256 i; i < n; ++i) {
            Constituent storage c = _constituents[i];
            p.liquidity[i] = FullMath.mulDiv(s.liquidity[i], shares, supply).toUint128();
            (p.stockOut[i], p.indexOut[i]) = _positionAmounts(c, s.sqrtPriceX96[i], p.liquidity[i]);
            p.idleStock[i] = FullMath.mulDiv(s.idleStock[i], shares, supply);
            p.stockOut[i] += p.idleStock[i];
            uint256 indexPart = i + 1 == n ? idleIndexLeft : p.idleIndex * c.targetBps / BPS;
            p.indexOut[i] += indexPart;
            idleIndexLeft -= indexPart;
        }
    }

    /// @dev Target after the deposit minus current value per constituent (0 when over); the deposit is split by those
    ///      shortfalls, or, if they sum below it, covers them and splits the rest by target weight
    function _route(uint256 indexValue, uint256 navNow, uint256[] memory values)
        internal
        view
        returns (uint256[] memory alloc)
    {
        uint256 n = values.length;
        alloc = new uint256[](n);
        uint256 shortfall;
        for (uint256 i; i < n; ++i) {
            uint256 target = (navNow + indexValue) * _constituents[i].targetBps / BPS;
            if (target > values[i]) {
                alloc[i] = target - values[i];
                shortfall += alloc[i];
            }
        }
        if (shortfall >= indexValue) {
            for (uint256 i; i < n; ++i) {
                alloc[i] = shortfall == 0 ? 0 : FullMath.mulDiv(indexValue, alloc[i], shortfall);
            }
        } else {
            uint256 rest = indexValue - shortfall;
            for (uint256 i; i < n; ++i) {
                alloc[i] += rest * _constituents[i].targetBps / BPS;
            }
        }
    }

    /// @dev The token amounts (round down) of the liquidity worth `value` over the constituent's range at `sqrtPriceX96`
    function _amountsForValue(Constituent storage c, uint160 sqrtPriceX96, uint256 value)
        internal
        view
        returns (uint256 stockAmount, uint256 indexAmount)
    {
        if (value == 0) return (0, 0);
        (uint256 unitStock, uint256 unitIndex) = _positionAmounts(c, sqrtPriceX96, UNIT_LIQUIDITY);
        uint256 unitValue = unitIndex + _stockToIndex(c.stockIsCurrency0, unitStock, sqrtPriceX96);
        if (unitValue == 0) return (0, 0);
        return _positionAmounts(c, sqrtPriceX96, FullMath.mulDiv(value, UNIT_LIQUIDITY, unitValue).toUint128());
    }

    /// @dev Pool prices and position liquidity per constituent, then the idle balances
    function _snapshot() internal view returns (Snapshot memory s) {
        uint256 n = _constituents.length;
        s.sqrtPriceX96 = new uint160[](n);
        s.liquidity = new uint128[](n);
        s.idleStock = new uint256[](n);
        for (uint256 i; i < n; ++i) {
            Constituent storage c = _constituents[i];
            (s.sqrtPriceX96[i],,,) = poolManager.getSlot0(c.key.toId());
            uint256 tokenId = c.tokenId;
            if (tokenId != 0) s.liquidity[i] = positionManager.getPositionLiquidity(tokenId);
        }
        _readIdle(s);
    }

    function _readIdle(Snapshot memory s) internal view {
        uint256 n = s.idleStock.length;
        for (uint256 i; i < n; ++i) {
            s.idleStock[i] = IERC20(_stock(_constituents[i])).balanceOf(address(this));
        }
        s.idleIndex = IERC20(indexToken).balanceOf(address(this));
    }

    /// @dev Per constituent: its position's index amount plus its position and idle stock at the pool price. `navNow`
    ///      adds the idle index token.
    function _values(Snapshot memory s) internal view returns (uint256[] memory values, uint256 navNow) {
        uint256 n = s.liquidity.length;
        values = new uint256[](n);
        navNow = s.idleIndex;
        for (uint256 i; i < n; ++i) {
            Constituent storage c = _constituents[i];
            (uint256 stockAmount, uint256 indexAmount) = _positionAmounts(c, s.sqrtPriceX96[i], s.liquidity[i]);
            values[i] = indexAmount + _stockToIndex(c.stockIsCurrency0, stockAmount + s.idleStock[i], s.sqrtPriceX96[i]);
            navNow += values[i];
        }
    }

    /// @dev The position's (stock, index) amounts for `liquidity` at `sqrtPriceX96`, rounded down as the pool pays them
    function _positionAmounts(Constituent storage c, uint160 sqrtPriceX96, uint128 liquidity)
        internal
        view
        returns (uint256 stockAmount, uint256 indexAmount)
    {
        if (liquidity == 0) return (0, 0);
        (uint256 amount0, uint256 amount1) = _amountsForLiquidity(
            sqrtPriceX96, TickMath.getSqrtPriceAtTick(c.tickLower), TickMath.getSqrtPriceAtTick(c.tickUpper), liquidity
        );
        return c.stockIsCurrency0 ? (amount0, amount1) : (amount1, amount0);
    }

    function _liquidityForAmounts(Constituent storage c, uint160 sqrtPriceX96, uint256 amount0, uint256 amount1)
        internal
        view
        returns (uint128)
    {
        return LiquidityAmounts.getLiquidityForAmounts(
            sqrtPriceX96,
            TickMath.getSqrtPriceAtTick(c.tickLower),
            TickMath.getSqrtPriceAtTick(c.tickUpper),
            amount0,
            amount1
        );
    }

    /// @dev LiquidityAmounts.getAmountsForLiquidity (v4-periphery's copy lacks it) with v4-core's own round-down math,
    ///      so the amounts are exactly what a decrease of `liquidity` pays at `sqrtPriceX96`
    function _amountsForLiquidity(uint160 sqrtPriceX96, uint160 sqrtPriceAX96, uint160 sqrtPriceBX96, uint128 liquidity)
        internal
        pure
        returns (uint256 amount0, uint256 amount1)
    {
        if (sqrtPriceX96 <= sqrtPriceAX96) {
            amount0 = SqrtPriceMath.getAmount0Delta(sqrtPriceAX96, sqrtPriceBX96, liquidity, false);
        } else if (sqrtPriceX96 < sqrtPriceBX96) {
            amount0 = SqrtPriceMath.getAmount0Delta(sqrtPriceX96, sqrtPriceBX96, liquidity, false);
            amount1 = SqrtPriceMath.getAmount1Delta(sqrtPriceAX96, sqrtPriceX96, liquidity, false);
        } else {
            amount1 = SqrtPriceMath.getAmount1Delta(sqrtPriceAX96, sqrtPriceBX96, liquidity, false);
        }
    }

    /// @dev `amount` of stock in index-token wei at `sqrtPriceX96` (currency1 per currency0): × P when the stock is
    ///      currency0, ÷ P otherwise. Two mulDivs by 2^96 keep 18-decimal amounts clear of overflow up to MAX_SQRT_PRICE.
    function _stockToIndex(bool stockIsCurrency0, uint256 amount, uint160 sqrtPriceX96)
        internal
        pure
        returns (uint256)
    {
        if (amount == 0 || sqrtPriceX96 == 0) return 0;
        return stockIsCurrency0
            ? FullMath.mulDiv(FullMath.mulDiv(amount, sqrtPriceX96, FixedPoint96.Q96), sqrtPriceX96, FixedPoint96.Q96)
            : FullMath.mulDiv(FullMath.mulDiv(amount, FixedPoint96.Q96, sqrtPriceX96), FixedPoint96.Q96, sqrtPriceX96);
    }

    /// @dev 10000 × (halfWidth − distance to the nearer edge) / halfWidth, clamped to [0, 20000]; computed over the
    ///      whole width (identical for the even widths of tick-spaced ranges, and never a division by zero)
    function _edgeProximityBps(int24 tick, int24 tickLower, int24 tickUpper) internal pure returns (uint16) {
        int256 width = int256(tickUpper) - tickLower;
        int256 below = int256(tick) - tickLower;
        int256 above = int256(tickUpper) - tick;
        int256 nearest = below < above ? below : above;
        int256 bps = 10_000 * (width - 2 * nearest) / width;
        return uint16(uint256(bps > 20_000 ? int256(20_000) : bps));
    }

    function _stock(Constituent storage c) internal view returns (address) {
        return Currency.unwrap(c.stockIsCurrency0 ? c.key.currency0 : c.key.currency1);
    }

    function _validateConstituent(uint256 i, ConstituentInit memory init, address index) internal pure {
        bool paired = (init.currency0 == init.stock && init.currency1 == index)
            || (init.currency0 == index && init.currency1 == init.stock);
        if (init.currency0 >= init.currency1 || !paired) revert InvalidConstituent(i);
        _checkRange(i, init.tickLower, init.tickUpper, init.tickSpacing);
    }

    function _checkRange(uint256 i, int24 tickLower, int24 tickUpper, int24 tickSpacing) internal pure {
        if (
            tickSpacing <= 0 || tickLower >= tickUpper || tickLower % tickSpacing != 0 || tickUpper % tickSpacing != 0
                || tickLower < TickMath.MIN_TICK || tickUpper > TickMath.MAX_TICK
        ) revert InvalidRange(i);
    }
}
