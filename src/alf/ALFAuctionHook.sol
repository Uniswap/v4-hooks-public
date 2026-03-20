// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {toBeforeSwapDelta, BeforeSwapDelta} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {SwapParams, ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {BaseHook} from "../base/BaseHook.sol";
import {IALFHook, ALFHookData} from "./interfaces/IALFHook.sol";
import {AuctionHookData, TargetedQuoter} from "./types/AuctionTypes.sol";

/// @title ALFAuctionHook
/// @notice Stateless atomic auction hook on a virtual (zero-liquidity) pool.
///         Queries targeted quoters via IALFHook and executes a greedy split fill
///         across candidates sorted by entry price. Each quoter is filled until
///         its marginal price worsens to the next-best candidate's level, then
///         remaining flow moves to the next quoter. Delta forwarding ensures
///         the auction hook's net position is zero.
///
///         Callers MUST provide targets in hookData (AuctionHookData). The auction
///         queries only the specified quoters, each receiving its own curve update
///         alongside the shared attestation (if provided).
contract ALFAuctionHook is BaseHook, IUnlockCallback {
    using CurrencyLibrary for Currency;
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    uint256 internal constant MAX_PIPS = 1_000_000;

    uint24 public immutable protocolFeePips; // 1000 = 0.1%, 10_000 = 1%
    address public owner;
    address public feeRecipient;

    /// @dev Internal struct for tracking quoter candidates during split fill.
    struct FillCandidate {
        PoolKey poolKey;
        bytes hookData;
        uint160 sqrtPriceX96;
        uint256 indicative;
    }

    error NoValidQuotes();
    error LiquidityNotAllowed();
    error InsufficientLiquidity();
    error QuoteDeviation(uint256 indicative, uint256 executed);
    error Unauthorized();
    error TargetsRequired();

    event AuctionExecuted(address indexed primaryQuoter, bool zeroForOne, int256 amountSpecified, uint256 bestQuote);
    event FillExecuted(address indexed quoter, int128 amount0, int128 amount1);
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

        // 2. Run split fill across candidates sorted by entry price
        (BalanceDelta totalDelta, address primaryQuoter, uint256 bestQuote) =
            _auctionAndSwap(key, params.zeroForOne, swapAmount, hookData);

        // 3. Exact output: compute fee from realized input
        if (params.amountSpecified >= 0 && protocolFeePips > 0) {
            int128 realizedInput = params.zeroForOne ? totalDelta.amount0() : totalDelta.amount1();
            feeAmount = uint256(int256(-realizedInput)) * protocolFeePips / MAX_PIPS;
        }

        // 4. Mint ERC-6909 claims for protocol fee
        if (feeAmount > 0) {
            poolManager.mint(address(this), (params.zeroForOne ? key.currency0 : key.currency1).toId(), feeAmount);
        }

        // 5. Enforce strict mode: revert if aggregate execution is below best indicative
        if (hookData.length > 0) {
            uint24 tol = abi.decode(hookData, (AuctionHookData)).strictTolerancePips;
            if (tol > 0) {
                uint256 executed = _extractOutput(totalDelta, params);
                // Downside-only: split fill should match or exceed best individual indicative
                if (executed < bestQuote) {
                    uint256 dev = bestQuote - executed;
                    if (dev * MAX_PIPS > bestQuote * tol) revert QuoteDeviation(bestQuote, executed);
                }
            }
        }

        emit AuctionExecuted(primaryQuoter, params.zeroForOne, params.amountSpecified, bestQuote);

        // 6. Convert BalanceDelta -> BeforeSwapDelta (negate + fee adjustment)
        return (IHooks.beforeSwap.selector, _toBeforeSwapDelta(totalDelta, params, feeAmount), 0);
    }

    // ──── Internal: Auction Router ────

    /// @dev Build sorted candidates, then execute greedy split fill across them.
    ///      Each quoter is filled until the price limit (next candidate's entry price)
    ///      or input/output exhaustion. Returns the accumulated delta, primary quoter
    ///      (best entry price), and best individual indicative (for tolerance checking).
    function _auctionAndSwap(PoolKey calldata, bool zeroForOne, int256 swapAmount, bytes calldata hookData)
        internal
        returns (BalanceDelta totalDelta, address primaryQuoter, uint256 bestQuote)
    {
        (FillCandidate[] memory candidates, uint256 count, uint256 bestIndividual) =
            _prepareCandidates(zeroForOne, swapAmount, hookData);

        bestQuote = bestIndividual;
        primaryQuoter = address(candidates[0].poolKey.hooks);
        totalDelta = _executeFills(candidates, count, zeroForOne, swapAmount);
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

    // ──── Internal: Split Fill ────

    /// @dev Query all targeted quoters, read their pool prices, and return a sorted candidate
    ///      array (best entry price first). Also returns the best individual indicative quote.
    function _prepareCandidates(bool zeroForOne, int256 swapAmount, bytes calldata hookData)
        internal
        view
        returns (FillCandidate[] memory candidates, uint256 count, uint256 bestIndividual)
    {
        if (hookData.length == 0) revert TargetsRequired();
        AuctionHookData memory ahd = abi.decode(hookData, (AuctionHookData));
        if (ahd.targets.length == 0) revert TargetsRequired();

        bool isExactInput = swapAmount < 0;
        candidates = new FillCandidate[](ahd.targets.length);

        for (uint256 i = 0; i < ahd.targets.length; i++) {
            (uint256 q, bytes memory quoterHookData) =
                _queryTarget(ahd.targets[i], ahd.attestationData, zeroForOne, swapAmount);
            if (q == 0) continue;

            (uint160 sqrtPriceX96,,,) = poolManager.getSlot0(ahd.targets[i].poolKey.toId());

            candidates[count] = FillCandidate({
                poolKey: ahd.targets[i].poolKey,
                hookData: quoterHookData,
                sqrtPriceX96: sqrtPriceX96,
                indicative: q
            });

            // Track the best individual indicative for tolerance checking
            if (count == 0 || (isExactInput ? q > bestIndividual : q < bestIndividual)) {
                bestIndividual = q;
            }
            count++;
        }

        if (count == 0) revert NoValidQuotes();

        // Insertion sort by indicative quality — fine for small candidate sets (3-5 quoters).
        // The indicative captures fee, liquidity depth, and price impact in a single number.
        // exact input: highest output first; exact output: lowest required input first.
        // sqrtPriceX96 is still used for price limits during execution.
        for (uint256 i = 1; i < count; i++) {
            FillCandidate memory key = candidates[i];
            uint256 j = i;
            while (j > 0 && _worseQuote(candidates[j - 1].indicative, key.indicative, isExactInput)) {
                candidates[j] = candidates[j - 1];
                j--;
            }
            candidates[j] = key;
        }
    }

    /// @dev Execute sequential fills across sorted candidates. Each quoter receives the
    ///      full remaining amount with a sqrtPriceLimitX96 set to the next candidate's
    ///      current price. The swap naturally terminates when the price worsens to the
    ///      next candidate's level, and remaining flow passes to the next quoter.
    ///
    ///      For exact output, reverts with InsufficientLiquidity if the aggregate fill
    ///      doesn't satisfy the full requested amount.
    function _executeFills(FillCandidate[] memory candidates, uint256 count, bool zeroForOne, int256 swapAmount)
        internal
        returns (BalanceDelta totalDelta)
    {
        int256 remaining = swapAmount;
        bool exactInput = swapAmount < 0;

        for (uint256 i = 0; i < count && remaining != 0; i++) {
            // Price limit = next candidate's entry price if it would actually constrain the swap.
            // v4 requires: zeroForOne → limit < currentPrice, oneForZero → limit > currentPrice.
            // When candidates share the same sqrtPrice (common: same initial tick), the next
            // candidate's price isn't a valid limit — fall through to the extreme.
            uint160 limit;
            if (i + 1 < count) {
                uint160 nextPrice = candidates[i + 1].sqrtPriceX96;
                bool validLimit = zeroForOne
                    ? nextPrice < candidates[i].sqrtPriceX96
                    : nextPrice > candidates[i].sqrtPriceX96;
                limit = validLimit
                    ? nextPrice
                    : (zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1);
            } else {
                limit = zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1;
            }

            BalanceDelta delta = poolManager.swap(
                candidates[i].poolKey,
                SwapParams({zeroForOne: zeroForOne, amountSpecified: remaining, sqrtPriceLimitX96: limit}),
                candidates[i].hookData
            );

            // Update remaining: extract the "filled" component from the delta
            //   exact input  → filled = input consumed (negative), remaining moves toward 0
            //   exact output → filled = output received (positive), remaining moves toward 0
            int128 filled = exactInput
                ? (zeroForOne ? delta.amount0() : delta.amount1())
                : (zeroForOne ? delta.amount1() : delta.amount0());
            remaining -= int256(filled);
            totalDelta = totalDelta + delta;

            emit FillExecuted(address(candidates[i].poolKey.hooks), delta.amount0(), delta.amount1());
        }

        // Exact output: revert if aggregate fill doesn't cover the requested amount
        if (!exactInput && remaining > 0) revert InsufficientLiquidity();
    }

    /// @dev Returns true if indicative `a` is worse than `b` for the given swap type.
    ///      Used by insertion sort to place best quotes first.
    function _worseQuote(uint256 a, uint256 b, bool isExactInput) internal pure returns (bool) {
        // exact input: higher output = better; exact output: lower required input = better
        return isExactInput ? a < b : a > b;
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
