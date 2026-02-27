// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {toBeforeSwapDelta, BeforeSwapDelta} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {SwapParams, ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {BaseHook} from "../base/BaseHook.sol";
import {IPropAMMIndex, QuoterEntry} from "./interfaces/IPropAMMIndex.sol";
import {IQuoterHook, QuoterHookData} from "./interfaces/IQuoterHook.sol";
import {AuctionHookData, TargetedQuoter} from "./types/AuctionTypes.sol";

/// @title PropAMMAuctionHook
/// @notice Stateless atomic auction hook on a virtual (zero-liquidity) pool.
///         Discovers quoters via PropAMMIndex, queries indicative quotes, then
///         executes a nested swap on the winner's pool. Delta forwarding ensures
///         the auction hook's net position is zero — the outer caller receives
///         the winner's execution as their swap result.
///
///         Two call paths via hookData encoding (AuctionHookData):
///
///         1. Discovery (targets empty): Queries all registered quoters from the
///            PropAMMIndex with attestation-only hookData. No per-quoter curve updates.
///
///         2. Targeted (targets non-empty): Queries only the specified quoters,
///            each receiving its own curve update alongside the shared attestation.
contract PropAMMAuctionHook is BaseHook {
    IPropAMMIndex public immutable index;

    error NoValidQuotes();
    error LiquidityNotAllowed();

    event AuctionExecuted(
        address indexed winner,
        bool zeroForOne,
        int256 amountSpecified,
        uint256 bestQuote
    );

    constructor(IPoolManager _poolManager, IPropAMMIndex _index) BaseHook(_poolManager) {
        index = _index;
    }

    // ──── Hook Permissions ────

    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: false,
            afterInitialize: false,
            beforeAddLiquidity: true, // block liquidity on virtual pool
            beforeRemoveLiquidity: false,
            afterAddLiquidity: false,
            afterRemoveLiquidity: false,
            beforeSwap: true, // core auction logic
            afterSwap: false,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: true, // forward winner's delta
            afterSwapReturnDelta: false,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    // ──── Lifecycle ────

    function _beforeAddLiquidity(address, PoolKey calldata, ModifyLiquidityParams calldata, bytes calldata)
        internal
        pure
        override
        returns (bytes4)
    {
        revert LiquidityNotAllowed();
    }

    function _beforeSwap(
        address,
        PoolKey calldata key,
        SwapParams calldata params,
        bytes calldata hookData
    ) internal override returns (bytes4, BeforeSwapDelta, uint24) {
        // 1. Run auction and get winner + their specific hookData
        (PoolKey memory winnerPoolKey, address winner, uint256 bestQuote, bytes memory winnerHookData) =
            _auction(key.currency0, key.currency1, params, hookData);

        // 2. Execute nested swap on winner's pool with their hookData
        BalanceDelta nestedDelta = poolManager.swap(
            winnerPoolKey,
            SwapParams({
                zeroForOne: params.zeroForOne,
                amountSpecified: params.amountSpecified,
                sqrtPriceLimitX96: params.zeroForOne
                    ? TickMath.MIN_SQRT_PRICE + 1
                    : TickMath.MAX_SQRT_PRICE - 1
            }),
            winnerHookData
        );

        // 3. Convert BalanceDelta → BeforeSwapDelta (negate to offset hook's nested delta)
        BeforeSwapDelta bsd = _toBeforeSwapDelta(nestedDelta, params);

        emit AuctionExecuted(winner, params.zeroForOne, params.amountSpecified, bestQuote);

        return (IHooks.beforeSwap.selector, bsd, 0);
    }

    // ──── Internal: Auction Router ────

    /// @dev Decode AuctionHookData and dispatch to the appropriate auction path.
    function _auction(
        Currency currency0,
        Currency currency1,
        SwapParams calldata params,
        bytes calldata hookData
    )
        internal
        view
        returns (PoolKey memory winnerPoolKey, address winner, uint256 bestQuote, bytes memory winnerHookData)
    {
        if (hookData.length == 0) {
            (winnerPoolKey, winner, bestQuote) = _runDiscovery(currency0, currency1, params, "");
            return (winnerPoolKey, winner, bestQuote, "");
        }

        AuctionHookData memory ahd = abi.decode(hookData, (AuctionHookData));

        if (ahd.targets.length == 0) {
            // Discovery: query all registered quoters with attestation only
            bytes memory quoteHookData = _buildAttestationHookData(ahd.attestationData);
            (winnerPoolKey, winner, bestQuote) = _runDiscovery(currency0, currency1, params, quoteHookData);
            winnerHookData = quoteHookData;
        } else {
            // Targeted: query specified quoters with per-quoter curve data
            (winnerPoolKey, winner, bestQuote, winnerHookData) =
                _runTargeted(params, ahd.attestationData, ahd.targets);
        }
    }

    // ──── Internal: Discovery Path ────

    /// @dev Query all registered quoters for the pair, return the best one.
    function _runDiscovery(
        Currency currency0,
        Currency currency1,
        SwapParams calldata params,
        bytes memory quoteHookData
    ) internal view returns (PoolKey memory winnerPoolKey, address winner, uint256 bestQuote) {
        QuoterEntry[] memory quoters = index.getQuoters(currency0, currency1);
        bool isExactInput = params.amountSpecified < 0;
        bool foundValid;

        for (uint256 i = 0; i < quoters.length; i++) {
            if (!quoters[i].isLive) continue;

            try IQuoterHook(quoters[i].hook).getIndicativeQuote{gas: quoters[i].maxGas}(
                quoters[i].poolKey, params.zeroForOne, params.amountSpecified, quoteHookData
            ) returns (uint256 quote) {
                if (quote == 0) continue;

                bool isBetter = !foundValid
                    || (isExactInput ? quote > bestQuote : quote < bestQuote);

                if (isBetter) {
                    bestQuote = quote;
                    winnerPoolKey = quoters[i].poolKey;
                    winner = quoters[i].hook;
                    foundValid = true;
                }
            } catch {}
        }

        if (!foundValid) revert NoValidQuotes();
    }

    // ──── Internal: Targeted Path ────

    /// @dev Query specific quoters with per-quoter curve data, return the best one.
    function _runTargeted(
        SwapParams calldata params,
        bytes memory attestationData,
        TargetedQuoter[] memory targets
    )
        internal
        view
        returns (PoolKey memory winnerPoolKey, address winner, uint256 bestQuote, bytes memory winnerHookData)
    {
        bool isExactInput = params.amountSpecified < 0;
        bool foundValid;

        for (uint256 i = 0; i < targets.length; i++) {
            (uint256 quote, bytes memory quoterHookData) =
                _queryTarget(targets[i], attestationData, params.zeroForOne, params.amountSpecified);

            if (quote == 0) continue;

            bool isBetter = !foundValid
                || (isExactInput ? quote > bestQuote : quote < bestQuote);

            if (isBetter) {
                bestQuote = quote;
                winnerPoolKey = targets[i].poolKey;
                winner = address(targets[i].poolKey.hooks);
                winnerHookData = quoterHookData;
                foundValid = true;
            }
        }

        if (!foundValid) revert NoValidQuotes();
    }

    /// @dev Query a single targeted quoter. Returns 0 if the quoter is not registered,
    ///      not live, or fails to produce a valid quote.
    function _queryTarget(
        TargetedQuoter memory target,
        bytes memory attestationData,
        bool zeroForOne,
        int256 amountSpecified
    ) internal view returns (uint256 quote, bytes memory quoterHookData) {
        address hook = address(target.poolKey.hooks);

        try index.getQuoter(hook, target.poolKey) returns (QuoterEntry memory entry) {
            if (!entry.isLive) return (0, "");

            quoterHookData = abi.encode(
                QuoterHookData({
                    attestationData: attestationData,
                    curveUpdateData: target.curveUpdateData
                })
            );

            try IQuoterHook(hook).getIndicativeQuote{gas: entry.maxGas}(
                target.poolKey, zeroForOne, amountSpecified, quoterHookData
            ) returns (uint256 q) {
                quote = q;
            } catch {}
        } catch {}
    }

    // ──── Internal: Helpers ────

    /// @dev Build attestation-only QuoterHookData, or empty bytes if no attestation.
    function _buildAttestationHookData(bytes memory attestationData)
        internal
        pure
        returns (bytes memory)
    {
        if (attestationData.length == 0) return "";
        return abi.encode(QuoterHookData({attestationData: attestationData, curveUpdateData: ""}));
    }

    /// @dev Negate the nested swap's BalanceDelta into a BeforeSwapDelta that offsets it.
    function _toBeforeSwapDelta(BalanceDelta nestedDelta, SwapParams calldata params)
        internal
        pure
        returns (BeforeSwapDelta)
    {
        bool isExactInput = params.amountSpecified < 0;
        int128 specified;
        int128 unspecified;

        if (isExactInput == params.zeroForOne) {
            specified = -nestedDelta.amount0();
            unspecified = -nestedDelta.amount1();
        } else {
            specified = -nestedDelta.amount1();
            unspecified = -nestedDelta.amount0();
        }

        return toBeforeSwapDelta(specified, unspecified);
    }
}
