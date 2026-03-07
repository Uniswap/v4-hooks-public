// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
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
contract PropAMMAuctionHook is BaseHook, IUnlockCallback {
    using CurrencyLibrary for Currency;

    uint256 internal constant MAX_PIPS = 1_000_000;

    IPropAMMIndex public immutable index;
    uint24 public immutable protocolFeePips; // 1000 = 0.1%, 10_000 = 1%
    address public owner;
    address public feeRecipient;

    error NoValidQuotes();
    error LiquidityNotAllowed();
    error QuoteDeviation(uint256 indicative, uint256 executed);
    error Unauthorized();

    event AuctionExecuted(address indexed winner, bool zeroForOne, int256 amountSpecified, uint256 bestQuote);
    event ProtocolFeesCollected(Currency indexed currency, address indexed recipient, uint256 amount);

    constructor(IPoolManager _poolManager, IPropAMMIndex _index, uint24 _protocolFeePips, address _owner)
        BaseHook(_poolManager)
    {
        index = _index;
        protocolFeePips = _protocolFeePips;
        owner = _owner;
        feeRecipient = _owner;
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

    // ──── View: Offchain Quote ────

    /// @notice Query the auction without executing a swap. Returns the winning quoter,
    ///         their pool key, best indicative quote, and the hookData to pass on execution.
    /// @dev Intended for offchain routers to pre-identify the winner and then use targeted
    ///      mode with a single quoter at execution time, saving re-discovery gas.
    function quote(
        Currency currency0,
        Currency currency1,
        bool zeroForOne,
        int256 amountSpecified,
        bytes calldata hookData
    )
        external
        view
        returns (PoolKey memory winnerPoolKey, address winner, uint256 bestQuote, bytes memory winnerHookData)
    {
        return _auction(currency0, currency1, zeroForOne, amountSpecified, hookData);
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

    function _beforeSwap(address, PoolKey calldata key, SwapParams calldata params, bytes calldata hookData)
        internal
        override
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        uint256 feeAmount;
        int256 swapAmount = params.amountSpecified;

        // 1. Exact input: compute fee upfront, reduce input to nested swap
        if (params.amountSpecified < 0 && protocolFeePips > 0) {
            feeAmount = uint256(-params.amountSpecified) * protocolFeePips / MAX_PIPS;
            swapAmount = params.amountSpecified + int256(feeAmount); // less negative
        }

        // 2. Run auction + execute nested swap on winner's pool
        (BalanceDelta nestedDelta, address winner, uint256 bestQuote) =
            _auctionAndSwap(key, params.zeroForOne, swapAmount, hookData);

        // 3. Exact output: compute fee from realized input
        if (params.amountSpecified >= 0 && protocolFeePips > 0) {
            int128 realizedInput = params.zeroForOne ? nestedDelta.amount0() : nestedDelta.amount1();
            feeAmount = uint256(int256(-realizedInput)) * protocolFeePips / MAX_PIPS;
        }

        // 4. Mint ERC-6909 claims for protocol fee
        if (feeAmount > 0) {
            poolManager.mint(address(this), (params.zeroForOne ? key.currency0 : key.currency1).toId(), feeAmount);
        }

        // 5. Enforce strict mode: revert if execution deviates beyond tolerance
        if (hookData.length > 0) {
            uint24 tol = abi.decode(hookData, (AuctionHookData)).strictTolerancePips;
            if (tol > 0) {
                uint256 executed = _extractOutput(nestedDelta, params);
                uint256 dev = executed > bestQuote ? executed - bestQuote : bestQuote - executed;
                if (dev * MAX_PIPS > bestQuote * tol) revert QuoteDeviation(bestQuote, executed);
            }
        }

        emit AuctionExecuted(winner, params.zeroForOne, params.amountSpecified, bestQuote);

        // 6. Convert BalanceDelta → BeforeSwapDelta (negate + fee adjustment)
        return (IHooks.beforeSwap.selector, _toBeforeSwapDelta(nestedDelta, params, feeAmount), 0);
    }

    // ──── Internal: Auction Router ────

    /// @dev Run auction, then execute nested swap on winner's pool. Returns the
    ///      nested swap delta, winner address, and best indicative quote.
    function _auctionAndSwap(PoolKey calldata key, bool zeroForOne, int256 swapAmount, bytes calldata hookData)
        internal
        returns (BalanceDelta nestedDelta, address winner, uint256 bestQuote)
    {
        PoolKey memory winnerPoolKey;
        bytes memory winnerHookData;
        (winnerPoolKey, winner, bestQuote, winnerHookData) =
            _auction(key.currency0, key.currency1, zeroForOne, swapAmount, hookData);

        nestedDelta = poolManager.swap(
            winnerPoolKey,
            SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: swapAmount,
                sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            winnerHookData
        );
    }

    /// @dev Decode AuctionHookData and dispatch to the appropriate auction path.
    function _auction(
        Currency currency0,
        Currency currency1,
        bool zeroForOne,
        int256 amountSpecified,
        bytes calldata hookData
    )
        internal
        view
        returns (PoolKey memory winnerPoolKey, address winner, uint256 bestQuote, bytes memory winnerHookData)
    {
        if (hookData.length == 0) {
            (winnerPoolKey, winner, bestQuote) = _runDiscovery(currency0, currency1, zeroForOne, amountSpecified, "");
            return (winnerPoolKey, winner, bestQuote, "");
        }

        AuctionHookData memory ahd = abi.decode(hookData, (AuctionHookData));

        if (ahd.targets.length == 0) {
            // Discovery: query all registered quoters with attestation only
            bytes memory quoteHookData = _buildAttestationHookData(ahd.attestationData);
            (winnerPoolKey, winner, bestQuote) =
                _runDiscovery(currency0, currency1, zeroForOne, amountSpecified, quoteHookData);
            winnerHookData = quoteHookData;
        } else {
            // Targeted: query specified quoters with per-quoter curve data
            (winnerPoolKey, winner, bestQuote, winnerHookData) =
                _runTargeted(zeroForOne, amountSpecified, ahd.attestationData, ahd.targets);
        }
    }

    // ──── Internal: Discovery Path ────

    /// @dev Query all registered quoters for the pair, return the best one.
    function _runDiscovery(
        Currency currency0,
        Currency currency1,
        bool zeroForOne,
        int256 amountSpecified,
        bytes memory quoteHookData
    ) internal view returns (PoolKey memory winnerPoolKey, address winner, uint256 bestQuote) {
        QuoterEntry[] memory quoters = index.getQuoters(currency0, currency1);
        bool isExactInput = amountSpecified < 0;
        bool foundValid;

        for (uint256 i = 0; i < quoters.length; i++) {
            if (!quoters[i].isLive) continue;

            try IQuoterHook(quoters[i].hook).getIndicativeQuote{gas: quoters[i].maxGas}(
                quoters[i].poolKey, zeroForOne, amountSpecified, quoteHookData
            ) returns (
                uint256 q
            ) {
                if (q == 0) continue;

                bool isBetter = !foundValid || (isExactInput ? q > bestQuote : q < bestQuote);

                if (isBetter) {
                    bestQuote = q;
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
        bool zeroForOne,
        int256 amountSpecified,
        bytes memory attestationData,
        TargetedQuoter[] memory targets
    )
        internal
        view
        returns (PoolKey memory winnerPoolKey, address winner, uint256 bestQuote, bytes memory winnerHookData)
    {
        bool isExactInput = amountSpecified < 0;
        bool foundValid;

        for (uint256 i = 0; i < targets.length; i++) {
            (uint256 q, bytes memory quoterHookData) =
                _queryTarget(targets[i], attestationData, zeroForOne, amountSpecified);

            if (q == 0) continue;

            bool isBetter = !foundValid || (isExactInput ? q > bestQuote : q < bestQuote);

            if (isBetter) {
                bestQuote = q;
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
    ) internal view returns (uint256 q, bytes memory quoterHookData) {
        address hook = address(target.poolKey.hooks);

        try index.getQuoter(hook, target.poolKey) returns (QuoterEntry memory entry) {
            if (!entry.isLive) return (0, "");

            quoterHookData =
                abi.encode(QuoterHookData({attestationData: attestationData, curveUpdateData: target.curveUpdateData}));

            try IQuoterHook(hook).getIndicativeQuote{gas: entry.maxGas}(
                target.poolKey, zeroForOne, amountSpecified, quoterHookData
            ) returns (
                uint256 indicative
            ) {
                q = indicative;
            } catch {}
        } catch {}
    }

    // ──── Internal: Helpers ────

    /// @dev Build attestation-only QuoterHookData, or empty bytes if no attestation.
    function _buildAttestationHookData(bytes memory attestationData) internal pure returns (bytes memory) {
        if (attestationData.length == 0) return "";
        return abi.encode(QuoterHookData({attestationData: attestationData, curveUpdateData: ""}));
    }

    /// @dev Extract the output amount from the nested swap delta to compare against the indicative quote.
    function _extractOutput(BalanceDelta nestedDelta, SwapParams calldata params) internal pure returns (uint256) {
        bool isExactInput = params.amountSpecified < 0;
        if (isExactInput) {
            // Output is the positive (received) token
            int128 out = params.zeroForOne ? nestedDelta.amount1() : nestedDelta.amount0();
            return uint256(int256(out));
        } else {
            // "Output" per IQuoterHook is the required input (abs of negative delta)
            int128 inp = params.zeroForOne ? nestedDelta.amount0() : nestedDelta.amount1();
            return uint256(int256(-inp));
        }
    }

    /// @dev Negate the nested swap's BalanceDelta into a BeforeSwapDelta that offsets it,
    ///      adding the protocol fee to the appropriate delta component.
    function _toBeforeSwapDelta(BalanceDelta nestedDelta, SwapParams calldata params, uint256 feeAmount)
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

        // Fee goes to specified (exact input) or unspecified (exact output)
        if (feeAmount > 0) {
            if (isExactInput) {
                specified += int128(uint128(feeAmount));
            } else {
                unspecified += int128(uint128(feeAmount));
            }
        }

        return toBeforeSwapDelta(specified, unspecified);
    }

    // ──── Fee Collection ────

    /// @notice Collect accumulated protocol fees for a currency.
    function collectProtocolFees(Currency currency) external {
        uint256 claims = poolManager.balanceOf(address(this), currency.toId());
        if (claims == 0) return;
        poolManager.unlock(abi.encode(currency, claims, feeRecipient));
    }

    /// @inheritdoc IUnlockCallback
    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(poolManager));
        (Currency currency, uint256 amount, address recipient) = abi.decode(data, (Currency, uint256, address));
        poolManager.burn(address(this), currency.toId(), amount);
        poolManager.take(currency, recipient, amount);
        emit ProtocolFeesCollected(currency, recipient, amount);
        return "";
    }

    // ──── Governance ────

    /// @notice Set the fee recipient address.
    function setFeeRecipient(address _feeRecipient) external {
        if (msg.sender != owner) revert Unauthorized();
        feeRecipient = _feeRecipient;
    }

    /// @notice Transfer ownership.
    function transferOwnership(address newOwner) external {
        if (msg.sender != owner) revert Unauthorized();
        owner = newOwner;
    }
}
