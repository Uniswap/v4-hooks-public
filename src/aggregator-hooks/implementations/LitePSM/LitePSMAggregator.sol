// SPDX-License-Identifier: MIT
pragma solidity 0.8.29;

import {BaseAggregatorHook} from "../../BaseAggregatorHook.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {ILitePSM} from "./interfaces/ILitePSM.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @title LitePSMAggregator
/// @notice Singleton Uniswap V4 hook that routes gem ↔ stable swaps through a MakerDAO LitePSM
/// @dev Compatible with both LitePSMWrapper (USDS/USDC) and the underlying LitePSM-DAI-USDC.
///      The gem token (USDC) is resolved from litePSM.gem() at construction; the counterpart
///      stable (USDS or DAI) is passed in by the deployer.
///      Because the PSM uses 6-decimal gem and 18-decimal stable, all amount conversions
///      use the immutable to18ConversionFactor read from the PSM at construction time.
///      tin  = fee on gem→stable (sellGem); tout = fee on stable→gem (buyGem). Both in WAD units.
contract LitePSMAggregator is BaseAggregatorHook {
    using SafeERC20 for IERC20;

    uint256 private constant WAD = 1e18;

    /// @notice The LitePSM (or LitePSMWrapper) contract
    ILitePSM public immutable litePSM;

    /// @notice The USDC (gem) token address — pulled from litePSM.gem() at construction
    address public immutable gemToken;

    /// @notice The stable token address (USDS or DAI) — supplied by the deployer
    address public immutable stableToken;

    /// @notice Decimal conversion factor from gem to 18 decimals (10^12 for USDC)
    /// @dev Cached from litePSM.to18ConversionFactor() to avoid repeated SLOADs
    uint256 public immutable to18ConversionFactor;

    /// @notice Token addresses stored per registered V4 pool
    struct PoolTokens {
        address token0;
        address token1;
    }

    /// @notice Maps Uniswap V4 pool IDs to their token addresses
    mapping(PoolId => PoolTokens) public poolIdToTokens;

    /// @notice Canonical pool per token pair — enforces one pool per USDC/USDS pair
    mapping(bytes32 => PoolId) private _canonicalPoolByPair;

    error TokensNotSupported(address token0, address token1);
    error PairAlreadyHasCanonicalPool(PoolId existingPoolId, address token0, address token1);
    error ExactOutExceedsCapacity();

    /// @param _manager The Uniswap V4 PoolManager contract
    /// @param _litePSM The LitePSM or LitePSMWrapper contract
    /// @param _stableToken The stable token address — USDS for LitePSMWrapper, DAI for LitePSM-DAI-USDC (18 decimals)
    constructor(IPoolManager _manager, ILitePSM _litePSM, address _stableToken)
        BaseAggregatorHook(_manager, "LitePSMAggregator v1.0")
    {
        litePSM = _litePSM;
        gemToken = _litePSM.gem();
        stableToken = _stableToken;
        to18ConversionFactor = _litePSM.to18ConversionFactor();
    }

    /// @inheritdoc BaseAggregatorHook
    function pseudoTotalValueLocked(PoolId poolId) external view override returns (uint256 amount0, uint256 amount1) {
        PoolTokens storage tokens = poolIdToTokens[poolId];
        if (tokens.token0 == address(0)) revert PoolDoesNotExist();

        uint256 gemBalance = IERC20(gemToken).balanceOf(litePSM.pocket());
        uint256 stableBalance = IERC20(stableToken).balanceOf(address(litePSM));

        if (tokens.token0 == gemToken) {
            amount0 = gemBalance;
            amount1 = stableBalance;
        } else {
            amount0 = stableBalance;
            amount1 = gemBalance;
        }
    }

    function protocolFeeFlags() external pure override returns (uint256) {
        return 1 << 12;
    }

    /// @inheritdoc BaseAggregatorHook
    /// @dev Quotes without fees; BaseAggregatorHook.quote() applies protocol fees on top.
    ///      Reads tin/tout fresh each call since governance can change them.
    ///
    ///      Capacity limits are applied to prevent quoting liquidity that the PSM cannot fill:
    ///      - sellGem (gem→USDS): capped at `buf / to18ConversionFactor` (gem units). This uses
    ///        `buf` as a proxy for the true cap of `min(buf, lineRoom) / to18`, since `lineRoom`
    ///        is only accessible via the Vat and is not exposed by the LitePSMWrapper. In practice
    ///        buf is kept below the debt ceiling, so this proxy is conservative and accurate.
    ///      - buyGem (USDS→gem): capped at the gem balance held in `pocket()`. This is exact.
    ///
    ///      When an amount exceeds available capacity:
    ///      - Exact-in: returns 0 (the full input cannot be processed)
    ///      - Exact-out: reverts with ExactOutExceedsCapacity (the desired output cannot be sourced)
    function _rawQuote(bool zeroToOne, int256 amountSpecified, PoolId poolId)
        internal
        view
        override
        returns (uint256 amountUnspecified)
    {
        PoolTokens storage tokens = poolIdToTokens[poolId];
        if (tokens.token0 == address(0)) revert PoolDoesNotExist();

        address tokenIn = zeroToOne ? tokens.token0 : tokens.token1;
        bool isSellingGem = tokenIn == gemToken;

        uint256 tin = litePSM.tin();
        uint256 tout = litePSM.tout();

        // sellGem capacity in gem units: buf (WAD) / to18ConversionFactor
        uint256 sellGemCap = litePSM.buf() / to18ConversionFactor;
        // buyGem capacity: exact gem balance available in the pocket
        uint256 buyGemCap = IERC20(gemToken).balanceOf(litePSM.pocket());

        if (amountSpecified < 0) {
            uint256 amountIn = uint256(-amountSpecified);
            if (isSellingGem) {
                // Exact-in gem → USDS
                if (amountIn > sellGemCap) return 0;
                amountUnspecified = amountIn * to18ConversionFactor * (WAD - tin) / WAD;
            } else {
                // Exact-in USDS → gem: compute gem output then check cap
                uint256 gemOut = amountIn * WAD / (to18ConversionFactor * (WAD + tout));
                if (gemOut > buyGemCap) return 0;
                amountUnspecified = gemOut;
            }
        } else {
            uint256 amountOut = uint256(amountSpecified);
            if (isSellingGem) {
                // Exact-out USDS: convert to required gem input and compare against sellGemCap.
                // Division-first avoids overflow when sellGemCap is large (e.g. buf = type(uint256).max).
                uint256 denom = to18ConversionFactor * (WAD - tin);
                uint256 gemRequired = (amountOut * WAD + denom - 1) / denom;
                if (gemRequired > sellGemCap) revert ExactOutExceedsCapacity();
                amountUnspecified = gemRequired;
            } else {
                // Exact-out gem: check directly against pocket balance
                if (amountOut > buyGemCap) revert ExactOutExceedsCapacity();
                amountUnspecified = (amountOut * to18ConversionFactor * (WAD + tout) + WAD - 1) / WAD;
            }
        }
    }

    function _beforeInitialize(address, PoolKey calldata key, uint160) internal override returns (bytes4) {
        address token0 = Currency.unwrap(key.currency0);
        address token1 = Currency.unwrap(key.currency1);

        bool validPair = (token0 == gemToken && token1 == stableToken) || (token0 == stableToken && token1 == gemToken);
        if (!validPair) revert TokensNotSupported(token0, token1);

        bytes32 pairKey = _canonicalPairKey(token0, token1);
        PoolId existing = _canonicalPoolByPair[pairKey];
        if (PoolId.unwrap(existing) != bytes32(0)) {
            revert PairAlreadyHasCanonicalPool(existing, token0, token1);
        }
        _canonicalPoolByPair[pairKey] = key.toId();

        poolIdToTokens[key.toId()] = PoolTokens({token0: token0, token1: token1});

        // Max-approve PSM once; forceApprove handles the case where approval was previously set
        IERC20(gemToken).forceApprove(address(litePSM), type(uint256).max);
        IERC20(stableToken).forceApprove(address(litePSM), type(uint256).max);

        emit AggregatorPoolRegistered(key.toId());
        pollTokenJar();
        return IHooks.beforeInitialize.selector;
    }

    function _conductSwap(Currency settleCurrency, Currency takeCurrency, SwapParams calldata params, PoolId)
        internal
        override
        returns (uint256 amountSettle, uint256 amountTake, bool hasSettled)
    {
        address tokenIn = Currency.unwrap(takeCurrency);
        address tokenOut = Currency.unwrap(settleCurrency);
        bool isSellingGem = tokenIn == gemToken;

        if (params.amountSpecified < 0) {
            // ── EXACT IN ──────────────────────────────────────────────────────────
            amountTake = uint256(-params.amountSpecified);
            poolManager.take(takeCurrency, address(this), amountTake);

            if (isSellingGem) {
                // USDC → USDS: sellGem returns exact usdsOut
                amountSettle = litePSM.sellGem(address(this), amountTake);
            } else {
                // USDS → USDC: compute max gemAmt from usdsGiven, tiny dust (<1 µUSDS) stays in hook
                uint256 tout = litePSM.tout();
                uint256 gemAmt = amountTake * WAD / (to18ConversionFactor * (WAD + tout));
                litePSM.buyGem(address(this), gemAmt);
                amountSettle = gemAmt;
            }
        } else {
            // ── EXACT OUT ─────────────────────────────────────────────────────────
            amountSettle = uint256(params.amountSpecified);

            if (isSellingGem) {
                // USDC → USDS: compute USDC needed (ceil) to guarantee >= usdsWanted
                uint256 tin = litePSM.tin();
                uint256 denom = to18ConversionFactor * (WAD - tin);
                amountTake = (amountSettle * WAD + denom - 1) / denom;
                poolManager.take(takeCurrency, address(this), amountTake);
                litePSM.sellGem(address(this), amountTake);
                // Any USDS excess (< 1 µUSDS) over amountSettle stays in hook as dust
            } else {
                // USDS → USDC: take ceiling USDS from PM
                uint256 tout = litePSM.tout();
                uint256 usdsNeeded = (amountSettle * to18ConversionFactor * (WAD + tout) + WAD - 1) / WAD;
                poolManager.take(takeCurrency, address(this), usdsNeeded);
                litePSM.buyGem(address(this), amountSettle);
                // Charge the user the full amount taken from the PM; any USDS excess (< 1 µUSDS) stays in hook as dust
                amountTake = usdsNeeded;
            }
        }

        // Settle output to PoolManager (sync → transfer → settle pattern)
        poolManager.sync(settleCurrency);
        IERC20(tokenOut).safeTransfer(address(poolManager), amountSettle);
        poolManager.settle();
        hasSettled = true;
    }

    function _canonicalPairKey(address token0, address token1) private pure returns (bytes32) {
        (address t0, address t1) = token0 < token1 ? (token0, token1) : (token1, token0);
        return keccak256(abi.encode(t0, t1));
    }
}
