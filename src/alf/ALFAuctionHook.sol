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
import {IALFHook, ALFHookData} from "./interfaces/IALFHook.sol";
import {AuctionHookData, TargetedQuoter} from "./types/AuctionTypes.sol";

/// @title ALFAuctionHook
/// @notice Stateless atomic auction hook on a virtual (zero-liquidity) pool.
///         Queries targeted quoters via IALFHook, picks the best indicative quote, then
///         executes a nested swap on the winner's pool. Delta forwarding ensures
///         the auction hook's net position is zero -- the outer caller receives
///         the winner's execution as their swap result.
///
///         Callers MUST provide targets in hookData (AuctionHookData). The auction
///         queries only the specified quoters, each receiving its own curve update
///         alongside the shared attestation.
contract ALFAuctionHook is BaseHook, IUnlockCallback {
    using CurrencyLibrary for Currency;

    uint256 internal constant MAX_PIPS = 1_000_000;

    uint24 public immutable protocolFeePips; // 1000 = 0.1%, 10_000 = 1%
    address public owner;
    address public feeRecipient;

    error NoValidQuotes();
    error LiquidityNotAllowed();
    error QuoteDeviation(uint256 indicative, uint256 executed);
    error Unauthorized();
    error TargetsRequired();

    event AuctionExecuted(address indexed winner, bool zeroForOne, int256 amountSpecified, uint256 bestQuote);
    event ProtocolFeesCollected(Currency indexed currency, address indexed recipient, uint256 amount);

    constructor(IPoolManager _poolManager, uint24 _protocolFeePips, address _owner)
        BaseHook(_poolManager)
    {
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
        Currency,
        Currency,
        bool zeroForOne,
        int256 amountSpecified,
        bytes calldata hookData
    )
        external
        view
        returns (PoolKey memory winnerPoolKey, address winner, uint256 bestQuote, bytes memory winnerHookData)
    {
        return _auction(zeroForOne, amountSpecified, hookData);
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

        // 6. Convert BalanceDelta -> BeforeSwapDelta (negate + fee adjustment)
        return (IHooks.beforeSwap.selector, _toBeforeSwapDelta(nestedDelta, params, feeAmount), 0);
    }

    // ──── Internal: Auction Router ────

    /// @dev Run auction, then execute nested swap on winner's pool. Returns the
    ///      nested swap delta, winner address, and best indicative quote.
    function _auctionAndSwap(PoolKey calldata, bool zeroForOne, int256 swapAmount, bytes calldata hookData)
        internal
        returns (BalanceDelta nestedDelta, address winner, uint256 bestQuote)
    {
        PoolKey memory winnerPoolKey;
        bytes memory winnerHookData;
        (winnerPoolKey, winner, bestQuote, winnerHookData) =
            _auction(zeroForOne, swapAmount, hookData);

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

    /// @dev Decode AuctionHookData and run the targeted auction. Requires targets in hookData.
    function _auction(
        bool zeroForOne,
        int256 amountSpecified,
        bytes calldata hookData
    )
        internal
        view
        returns (PoolKey memory winnerPoolKey, address winner, uint256 bestQuote, bytes memory winnerHookData)
    {
        if (hookData.length == 0) revert TargetsRequired();

        AuctionHookData memory ahd = abi.decode(hookData, (AuctionHookData));
        if (ahd.targets.length == 0) revert TargetsRequired();

        // Targeted: query specified quoters with per-quoter curve data
        (winnerPoolKey, winner, bestQuote, winnerHookData) =
            _runTargeted(zeroForOne, amountSpecified, ahd.attestationData, ahd.targets);
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

    /// @dev Query a single targeted quoter. Returns 0 if the quoter is not live
    ///      or fails to produce a valid quote.
    function _queryTarget(
        TargetedQuoter memory target,
        bytes memory attestationData,
        bool zeroForOne,
        int256 amountSpecified
    ) internal view returns (uint256 q, bytes memory quoterHookData) {
        address hook = address(target.poolKey.hooks);

        try IALFHook(hook).isLive() returns (bool live) {
            if (!live) return (0, "");
        } catch {
            return (0, "");
        }

        uint32 gasLimit;
        try IALFHook(hook).maxGas() returns (uint32 mg) {
            gasLimit = mg;
        } catch {
            return (0, "");
        }

        quoterHookData =
            abi.encode(ALFHookData({attestationData: attestationData, curveUpdateData: target.curveUpdateData}));

        try IALFHook(hook).getIndicativeQuote{gas: gasLimit}(
            target.poolKey, zeroForOne, amountSpecified, quoterHookData
        ) returns (
            uint256 indicative
        ) {
            q = indicative;
        } catch {}
    }

    // ──── Internal: Helpers ────

    /// @dev Extract the output amount from the nested swap delta to compare against the indicative quote.
    function _extractOutput(BalanceDelta nestedDelta, SwapParams calldata params) internal pure returns (uint256) {
        bool isExactInput = params.amountSpecified < 0;
        if (isExactInput) {
            // Output is the positive (received) token
            int128 out = params.zeroForOne ? nestedDelta.amount1() : nestedDelta.amount0();
            return uint256(int256(out));
        } else {
            // "Output" per IALFHook is the required input (abs of negative delta)
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
