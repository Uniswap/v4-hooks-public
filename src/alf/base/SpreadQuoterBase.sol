// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {SwapParams, ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {Ownable2Step, Ownable} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import {BaseALFHook} from "./BaseALFHook.sol";
import {SwapSimulator} from "../libraries/SwapSimulator.sol";

/// @title SpreadQuoterBase
/// @author Uniswap Labs
/// @notice Abstract base for spread quoters using native v4 LP with a single symmetric fee.
///         Provides pricing via SwapSimulator, EIP-712 signed curve updates with
///         one-update-per-block enforcement, and single-tick LP concentration.
///         Concrete hooks define LP access control and hook permissions.
/// @custom:security-contact security@uniswap.org
abstract contract SpreadQuoterBase is BaseALFHook, EIP712, Ownable2Step {
    using PoolIdLibrary for PoolKey;

    /// @notice Pricing state per pool. Single symmetric LP fee applied in both swap directions.
    /// @param feePips Fee override (pips, max `LPFeeLibrary.MAX_LP_FEE`) applied to all swaps.
    /// @param live    Whether the pool currently quotes and executes swaps.
    struct PricingState {
        uint24 feePips;
        bool live;
    }

    /// @dev EIP-712 type hash for `PricingUpdate` curve-update messages. The `sequence` field
    ///      makes each signed update strictly orderable per pool — replays of older payloads
    ///      (cross-block) are rejected even when their `deadline` is still in the future.
    bytes32 private constant PRICING_UPDATE_TYPEHASH = keccak256(
        "PricingUpdate(uint24 feePips,bool live,bytes32 poolId,uint256 deadline,uint64 sequence)"
    );

    /// @notice Pricing state for each pool managed by this hook.
    mapping(PoolId => PricingState) public pricingState;

    /// @notice Lower tick of the single permitted LP range per pool. LP add liquidity calls
    ///         must use exactly `[activeLowerTick, activeLowerTick + tickSpacing]`.
    mapping(PoolId => int24) public activeLowerTick;

    /// @notice Latest committed signed-update sequence per pool. New updates must have
    ///         `sequence > lastCommittedSequence[poolId]`. The signer is responsible for
    ///         choosing monotonic sequence numbers (e.g., a wall-clock-derived counter).
    /// @dev    Owner-driven `updatePricingState` does NOT update this counter — it bypasses the
    ///         signed channel entirely. Only `_applyCurveUpdate` advances the sequence.
    mapping(PoolId => uint64) public lastCommittedSequence;

    /// @notice Emitted whenever a pool's pricing state is committed via `_commitPricingState`.
    /// @param poolId The pool whose pricing was updated.
    /// @param state  The full new pricing state (post-validation).
    event PricingStateUpdated(PoolId indexed poolId, PricingState state);

    /// @notice Emitted when a pool's liveness flag is toggled via `setPoolLive`.
    /// @param poolId The pool whose liveness changed.
    /// @param isLive The new liveness state.
    event PoolLivenessUpdated(PoolId indexed poolId, bool isLive);

    /// @notice Emitted when the active lower tick is changed via `setActiveTick` or
    ///         `_afterInitialize`.
    /// @param poolId           The pool whose active range changed.
    /// @param activeLowerTick  The new lower tick (always aligned to `tickSpacing`).
    event ActiveTickUpdated(PoolId indexed poolId, int24 activeLowerTick);

    /// @dev LP add-liquidity range is malformed (lower >= upper, not aligned to `tickSpacing`,
    ///      or the range width does not equal one tickSpacing).
    error InvalidTickRange();
    /// @dev LP add-liquidity range is correctly shaped but not at the configured `activeLowerTick`.
    error WrongActiveTick();

    /// @dev `feePips` exceeds `LPFeeLibrary.MAX_LP_FEE` (1_000_000 = 100%).
    ///      Without this guard, fees > 100% break v4's swap math (denominator underflow) and
    ///      enable an owner / compromised priceSigner to brick or extract from the pool.
    error FeeOutOfBounds();

    /// @dev A signed curve update's `sequence` is not strictly greater than the last committed
    ///      sequence for this pool. Prevents cross-block replay of older signed payloads whose
    ///      deadline has not yet expired.
    error StaleSequence();

    /// @param _poolManager The Uniswap v4 PoolManager.
    /// @param maxGas_      Gas budget declared for `getIndicativeQuote` staticcalls.
    /// @param owner_       Initial owner (Ownable2Step). Owner can rotate `priceSigner` and
    ///                     update pricing/active-tick state.
    /// @param eip712Name   Domain name for EIP-712 typed-data signing of curve updates.
    constructor(IPoolManager _poolManager, uint32 maxGas_, address owner_, string memory eip712Name)
        BaseALFHook(_poolManager, maxGas_)
        EIP712(eip712Name, "1")
        Ownable(owner_)
    {}

    // ──── IALFHook ────

    /// @notice Always reports live; per-pool liveness is gated by `pricingState[poolId].live`.
    /// @dev    See {IALFHook.isLive}. Routers SHOULD also consult per-pool pricing state to
    ///         determine effective liveness for swaps.
    function isLive() external pure override returns (bool) {
        return true;
    }

    /// @notice Indicative quote with hookData-aware pricing.
    /// @dev If hookData carries a curve update, it is fully authenticated -- decoded, metadata-
    ///      validated, sequence-checked against `lastCommittedSequence`, and EIP-712-verified
    ///      against `priceSigner` -- before its pricing is used for the simulation. This
    ///      mirrors the swap-time validation, so an aggregator router cannot be misled by
    ///      forged or replayed quote payloads. Reverts on any auth failure (consistent with
    ///      the swap path); routers that don't have a fresh signed update SHOULD send empty
    ///      hookData to fall back to the stored `pricingState`.
    function getIndicativeQuote(PoolKey calldata key, bool zeroForOne, int256 amountSpecified, bytes calldata hookData)
        external
        view
        virtual
        override
        returns (uint256 outputAmount)
    {
        (bytes memory curveUpdateData, bool isAttested, address attester) = _resolveHookData(hookData);

        PricingState memory state = curveUpdateData.length > 0
            ? _decodeAndVerifyCurveUpdate(key, curveUpdateData)
            : pricingState[key.toId()];

        return _priceWithState(key, zeroForOne, amountSpecified, isAttested, attester, state);
    }

    /// @notice Simulate a swap up to a target price, returning both amounts.
    /// @dev Resolves hookData (curve updates, attestation) the same way as `getIndicativeQuote`,
    ///      then delegates to `SwapSimulator.simulateSwapToPrice` with the effective fee.
    ///      Curve updates carried in hookData are fully authenticated -- see
    ///      `getIndicativeQuote` for details.
    function swapToPrice(
        PoolKey calldata key,
        bool zeroForOne,
        int256 amountSpecified,
        uint160 sqrtPriceLimitX96,
        bytes calldata hookData
    ) external view virtual override returns (uint256 amountIn, uint256 amountOut) {
        uint24 feePips;
        {
            (bytes memory curveUpdateData,,) = _resolveHookData(hookData);

            PricingState memory state = curveUpdateData.length > 0
                ? _decodeAndVerifyCurveUpdate(key, curveUpdateData)
                : pricingState[key.toId()];

            if (!state.live) return (0, 0);
            feePips = state.feePips;
        }

        return SwapSimulator.simulateSwapToPrice(
            poolManager, key.toId(), zeroForOne, amountSpecified, feePips, key.tickSpacing, sqrtPriceLimitX96
        );
    }

    // ──── Hook Lifecycle ────

    /// @dev Auto-derive the active lower tick from the initial pool tick at initialization.
    ///      Floor-aligns to `tickSpacing` and clamps to the v4 usable tick range so the
    ///      resulting LP range `[activeLowerTick, activeLowerTick + tickSpacing]` is always
    ///      a valid v4 LP position — even at the extremes near MIN/MAX_TICK.
    ///      Emits no event — `setActiveTick` is the canonical source for `ActiveTickUpdated`
    ///      events post-init.
    function _afterInitialize(address, PoolKey calldata key, uint160, int24 tick) internal override returns (bytes4) {
        // Auto-set active tick aligned to tickSpacing (floor division)
        int24 compressed = tick / key.tickSpacing;
        if (tick < 0 && tick % key.tickSpacing != 0) compressed--;
        int24 candidate = compressed * key.tickSpacing;

        // Clamp into [minUsableTick, maxUsableTick - tickSpacing] so the LP range fits.
        int24 minUsable = TickMath.minUsableTick(key.tickSpacing);
        int24 maxLower = TickMath.maxUsableTick(key.tickSpacing) - key.tickSpacing;
        if (candidate < minUsable) candidate = minUsable;
        else if (candidate > maxLower) candidate = maxLower;

        activeLowerTick[key.toId()] = candidate;

        return IHooks.afterInitialize.selector;
    }

    /// @dev Apply any signed curve update from `hookData`, then return the LP fee override
    ///      for the swap. Returns a zero override (no fee) if the pool is not live.
    function _beforeSwap(address, PoolKey calldata key, SwapParams calldata, bytes calldata hookData)
        internal
        virtual
        override
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        (bytes memory curveUpdateData,,) = _resolveHookData(hookData);

        if (curveUpdateData.length > 0) {
            _applyCurveUpdate(key, curveUpdateData);
        }

        PricingState memory state = pricingState[key.toId()];
        if (!state.live) {
            return (IHooks.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
        }

        uint24 feePips = state.feePips;
        uint24 feeOverride = feePips | LPFeeLibrary.OVERRIDE_FEE_FLAG;

        return (IHooks.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, feeOverride);
    }

    // ──── Pricing ────

    function _price(PoolKey calldata key, bool zeroForOne, int256 amountSpecified, bool isAttested, address attester)
        internal
        view
        virtual
        override
        returns (uint256 outputAmount)
    {
        return _priceWithState(key, zeroForOne, amountSpecified, isAttested, attester, pricingState[key.toId()]);
    }

    function _priceWithState(
        PoolKey calldata key,
        bool zeroForOne,
        int256 amountSpecified,
        bool,
        address,
        PricingState memory state
    ) internal view returns (uint256 outputAmount) {
        if (!state.live) return 0;

        uint24 feePips = state.feePips;
        outputAmount =
            SwapSimulator.simulateSwap(poolManager, key.toId(), zeroForOne, amountSpecified, feePips, key.tickSpacing);
    }

    /// @dev Validate that the fee is within v4's `[0, MAX_LP_FEE]` range. Used by
    ///      `_commitPricingState` for every write to `pricingState`.
    function _validateFeeBounds(PricingState memory state) internal pure {
        if (state.feePips > LPFeeLibrary.MAX_LP_FEE) revert FeeOutOfBounds();
    }

    /// @dev Single chokepoint for committing a `PricingState`. Validates fee bounds, writes
    ///      storage, syncs the PM's stored dynamic LP fee, and emits the event.
    ///
    ///      The PM's stored LP fee is set to `feePips` when the pool is live, or `0` when not
    ///      live. Per-swap pricing is still controlled by the override returned from
    ///      `_beforeSwap`. The stored value is informational -- useful for off-chain
    ///      consumers that read `getSlot0` to estimate slippage.
    ///
    ///      `poolManager.updateDynamicLPFee` requires the pool to be initialized; subclass
    ///      init flows MUST call this AFTER `poolManager.initialize(key, ...)`.
    ///
    ///      Safe to call inside a v4 unlock callback -- `updateDynamicLPFee` does not require
    ///      unlock and the per-swap override (set in `_beforeSwap`) takes precedence over the
    ///      stored fee for the in-flight swap.
    /// @param key   The pool to update.
    /// @param state The new pricing state (validated for fee bounds).
    function _commitPricingState(PoolKey calldata key, PricingState memory state) internal {
        _validateFeeBounds(state);
        PoolId poolId = key.toId();
        pricingState[poolId] = state;

        poolManager.updateDynamicLPFee(key, state.live ? state.feePips : 0);

        emit PricingStateUpdated(poolId, state);
    }

    // ──── Curve Update Logic ────

    /// @dev View-side decode + full authentication of a curve-update payload. Validates
    ///      metadata, requires `sequence > lastCommittedSequence`, and verifies the EIP-712
    ///      signature against `priceSigner`. Returns the verified `PricingState` for use in
    ///      indicative simulations. Reverts on any auth failure -- callers are responsible
    ///      for catching when they want soft-fail semantics.
    ///
    ///      Mirrors the auth half of `_applyCurveUpdate` but skips the
    ///      `_checkAndMarkCurveUpdate` per-block dedup write (impossible in a view) and the
    ///      `_commitPricingState` write (the view function never mutates state). The result
    ///      is "what would the quote be if this signed update were committed right now",
    ///      with the same authorization guarantees as the swap path.
    /// @param key             The pool the update targets.
    /// @param curveUpdateData ABI-encoded
    ///                        `(PricingState, PoolId, uint256 deadline, uint64 sequence, bytes sig)`.
    /// @return state The authenticated pricing state from the payload.
    function _decodeAndVerifyCurveUpdate(PoolKey calldata key, bytes memory curveUpdateData)
        internal
        view
        returns (PricingState memory state)
    {
        PoolId updatePoolId;
        uint256 deadline;
        uint64 sequence;
        bytes memory sig;
        (state, updatePoolId, deadline, sequence, sig) =
            abi.decode(curveUpdateData, (PricingState, PoolId, uint256, uint64, bytes));

        PoolId poolId = key.toId();
        _validateCurveUpdateMeta(poolId, updatePoolId, deadline);
        if (sequence <= lastCommittedSequence[poolId]) revert StaleSequence();
        _verifySignature(state, poolId, deadline, sequence, sig);
    }

    /// @dev Decode the curve update payload, validate metadata + sequence, and (if novel for
    ///      this block) verify its signature and commit the new pricing state.
    ///      Replays of an already-applied update for the same `(poolId, block.number)`
    ///      short-circuit as no-ops; conflicting payloads in the same block revert from
    ///      `_checkAndMarkCurveUpdate`. Cross-block replay of an old payload (whose `deadline`
    ///      has not yet expired) is rejected via the strictly-monotonic `sequence` check.
    /// @param key             The pool the update targets.
    /// @param curveUpdateData ABI-encoded
    ///                        `(PricingState, PoolId, uint256 deadline, uint64 sequence, bytes sig)`.
    function _applyCurveUpdate(PoolKey calldata key, bytes memory curveUpdateData) internal {
        (PricingState memory newState, PoolId updatePoolId, uint256 deadline, uint64 sequence, bytes memory sig) =
            abi.decode(curveUpdateData, (PricingState, PoolId, uint256, uint64, bytes));

        PoolId poolId = key.toId();
        _validateCurveUpdateMeta(poolId, updatePoolId, deadline);

        if (_checkAndMarkCurveUpdate(poolId, curveUpdateData)) {
            // Reject stale signed payloads. Strict `>` enforces uniqueness — two updates with the
            // same sequence cannot both commit even if the second arrives in a different block.
            if (sequence <= lastCommittedSequence[poolId]) revert StaleSequence();
            _verifySignature(newState, poolId, deadline, sequence, sig);
            lastCommittedSequence[poolId] = sequence;
            _commitPricingState(key, newState);
        }
    }

    /// @dev Recover the EIP-712 signer over the `PricingUpdate` typed data and require it to
    ///      match the configured `priceSigner`. Reverts with {InvalidPriceSigner} on mismatch.
    function _verifySignature(
        PricingState memory state,
        PoolId poolId,
        uint256 deadline,
        uint64 sequence,
        bytes memory sig
    ) internal virtual view {
        bytes32 structHash = keccak256(
            abi.encode(
                PRICING_UPDATE_TYPEHASH,
                state.feePips,
                state.live,
                PoolId.unwrap(poolId),
                deadline,
                sequence
            )
        );
        bytes32 digest = _hashTypedDataV4(structHash);
        address signer = ECDSA.recover(digest, sig);
        if (signer != priceSigner) revert InvalidPriceSigner();
    }

    // ──── LP Tick Enforcement ────

    /// @dev Enforce single-tick-spacing LP at the active tick.
    function _enforceActiveTick(PoolKey calldata key, ModifyLiquidityParams calldata params) internal view {
        if (params.tickUpper - params.tickLower != key.tickSpacing) revert InvalidTickRange();
        if (params.tickLower != activeLowerTick[key.toId()]) revert WrongActiveTick();
    }

    // ──── Owner Functions ────

    /// @notice Update the pricing state for a pool.
    /// @dev Routes through `_commitPricingState` -- validates fee bounds, writes storage, and
    ///      syncs the PM's stored dynamic LP fee. Reverts if `feePips` exceeds
    ///      `LPFeeLibrary.MAX_LP_FEE`. The pool MUST already be initialized.
    function updatePricingState(PoolKey calldata key, PricingState calldata state) external virtual onlyOwner {
        _commitPricingState(key, state);
    }

    /// @notice Toggle liveness for a pool.
    /// @dev Reads the existing `pricingState`, mutates `live`, and routes through
    ///      `_commitPricingState`. When toggling to `false`, the PM's stored dynamic LP fee
    ///      is set to 0 to reflect that no swap fee will be charged on this pool.
    function setPoolLive(PoolKey calldata key, bool live) external virtual onlyOwner {
        PricingState memory state = pricingState[key.toId()];
        state.live = live;
        _commitPricingState(key, state);
        emit PoolLivenessUpdated(key.toId(), live);
    }

    /// @notice Set the authorized price signer for hookData curve updates.
    /// @dev Setting to `address(0)` is permitted (intentional disable of signed updates).
    ///      ECDSA.recover from a malformed sig reverts; from a well-formed sig it returns
    ///      a non-zero address that won't match `address(0)`. Either way, signed updates
    ///      become non-applicable.
    function setPriceSigner(address _priceSigner) external virtual onlyOwner {
        priceSigner = _priceSigner;
        emit PriceSignerUpdated(_priceSigner);
    }

    /// @notice Set the active lower tick for LP concentration.
    function setActiveTick(PoolKey calldata key, int24 newActiveLowerTick) external virtual onlyOwner {
        if (newActiveLowerTick % key.tickSpacing != 0) revert InvalidTickRange();
        activeLowerTick[key.toId()] = newActiveLowerTick;
        emit ActiveTickUpdated(key.toId(), newActiveLowerTick);
    }
}
