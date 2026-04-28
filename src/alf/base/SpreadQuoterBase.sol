// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {SwapParams, ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {Ownable2Step, Ownable} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import {BaseALFHook} from "./BaseALFHook.sol";
import {SwapSimulator} from "../libraries/SwapSimulator.sol";

/// @title SpreadQuoterBase
/// @notice Abstract base for bid/ask spread quoters using native v4 LP with fee overrides.
///         Provides pricing via SwapSimulator, EIP-712 signed curve updates with
///         one-update-per-block enforcement, and single-tick LP concentration.
///         Concrete hooks define LP access control and hook permissions.
abstract contract SpreadQuoterBase is BaseALFHook, EIP712, Ownable2Step {
    using PoolIdLibrary for PoolKey;

    struct PricingState {
        uint24 bidFeePips; // Fee override for zeroForOne swaps (pips, max 1_000_000 = 100%)
        uint24 askFeePips; // Fee override for oneForZero swaps (pips, max 1_000_000 = 100%)
        bool live;
    }

    bytes32 private constant PRICING_UPDATE_TYPEHASH = keccak256(
        "PricingUpdate(uint24 bidFeePips,uint24 askFeePips,bool live,bytes32 poolId,uint256 deadline)"
    );

    mapping(PoolId => PricingState) public pricingState;
    mapping(PoolId => int24) public activeLowerTick;

    event PricingStateUpdated(PoolId indexed poolId, PricingState state);
    event PoolLivenessUpdated(PoolId indexed poolId, bool isLive);
    event ActiveTickUpdated(PoolId indexed poolId, int24 activeLowerTick);

    error InvalidTickRange();
    error WrongActiveTick();

    /// @dev `bidFeePips` or `askFeePips` exceeds `LPFeeLibrary.MAX_LP_FEE` (1_000_000 = 100%).
    ///      Without this guard, fees > 100% break v4's swap math (denominator underflow) and
    ///      enable an owner / compromised priceSigner to brick or extract from the pool (H-04).
    error FeeOutOfBounds();

    constructor(IPoolManager _poolManager, uint32 maxGas_, address owner_, string memory eip712Name)
        BaseALFHook(_poolManager, maxGas_)
        EIP712(eip712Name, "1")
        Ownable(owner_)
    {}

    // ──── IALFHook ────

    function isLive() external pure override returns (bool) {
        return true;
    }

    /// @notice Indicative quote with hookData-aware pricing.
    /// @dev If hookData contains a curve update, the new pricing is used for the simulation
    ///      without modifying storage (view function).
    /// @dev WARNING: This base implementation applies the hookData-supplied pricing without
    ///      verifying the signature. Quotes are non-binding by design; the actual swap path
    ///      verifies signatures separately. Subclasses serving production traffic SHOULD
    ///      override this to verify signatures (or ignore hookData entirely) so that aggregator
    ///      routers cannot be misled by unsigned quote payloads.
    function getIndicativeQuote(PoolKey calldata key, bool zeroForOne, int256 amountSpecified, bytes calldata hookData)
        external
        view
        virtual
        override
        returns (uint256 outputAmount)
    {
        (bytes memory curveUpdateData, bool isAttested, address attester) = _resolveHookData(hookData);

        PricingState memory state = pricingState[key.toId()];
        if (curveUpdateData.length > 0) {
            (PricingState memory newState,,,) = abi.decode(curveUpdateData, (PricingState, PoolId, uint256, bytes));
            state = newState;
        }

        return _priceWithState(key, zeroForOne, amountSpecified, isAttested, attester, state);
    }

    /// @notice Simulate a swap up to a target price, returning both amounts.
    /// @dev Resolves hookData (curve updates, attestation) the same way as getIndicativeQuote,
    ///      then delegates to SwapSimulator.simulateSwapToPrice with the effective fee.
    /// @dev Same caveat as `getIndicativeQuote` regarding unsigned hookData pricing.
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

            PricingState memory state = pricingState[key.toId()];
            if (curveUpdateData.length > 0) {
                (PricingState memory newState,,,) = abi.decode(curveUpdateData, (PricingState, PoolId, uint256, bytes));
                state = newState;
            }

            if (!state.live) return (0, 0);
            feePips = _effectiveFee(state, zeroForOne);
        }

        return SwapSimulator.simulateSwapToPrice(
            poolManager, key.toId(), zeroForOne, amountSpecified, feePips, key.tickSpacing, sqrtPriceLimitX96
        );
    }

    // ──── Hook Lifecycle ────

    function _afterInitialize(address, PoolKey calldata key, uint160, int24 tick) internal override returns (bytes4) {
        // Auto-set active tick aligned to tickSpacing (floor division)
        int24 compressed = tick / key.tickSpacing;
        if (tick < 0 && tick % key.tickSpacing != 0) compressed--;
        activeLowerTick[key.toId()] = compressed * key.tickSpacing;

        return IHooks.afterInitialize.selector;
    }

    function _beforeSwap(address, PoolKey calldata key, SwapParams calldata params, bytes calldata hookData)
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

        uint24 feePips = _effectiveFee(state, params.zeroForOne);
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

        uint24 feePips = _effectiveFee(state, zeroForOne);
        outputAmount =
            SwapSimulator.simulateSwap(poolManager, key.toId(), zeroForOne, amountSpecified, feePips, key.tickSpacing);
    }

    /// @dev Compute the effective fee for a swap direction.
    ///      Used by both _beforeSwap (execution) and _priceWithState (indicative) to ensure fidelity.
    function _effectiveFee(PricingState memory state, bool zeroForOne)
        internal
        pure
        returns (uint24 feePips)
    {
        feePips = zeroForOne ? state.bidFeePips : state.askFeePips;
    }

    /// @dev Validate that bid/ask fees are within v4's `[0, MAX_LP_FEE]` range. Used by
    ///      `_commitPricingState` for every write to `pricingState`.
    function _validateFeeBounds(PricingState memory state) internal pure {
        if (state.bidFeePips > LPFeeLibrary.MAX_LP_FEE) revert FeeOutOfBounds();
        if (state.askFeePips > LPFeeLibrary.MAX_LP_FEE) revert FeeOutOfBounds();
    }

    /// @dev Single chokepoint for committing a `PricingState`. Validates fee bounds, writes
    ///      storage, syncs the PM's stored dynamic LP fee, and emits the event.
    ///
    ///      The PM's stored LP fee is set to `max(bidFeePips, askFeePips)` when the pool is
    ///      live, or `0` when not live. Per-swap pricing is still controlled by the override
    ///      returned from `_beforeSwap`, which is direction-aware (bid vs ask). The stored
    ///      value is informational — useful for off-chain consumers that read `getSlot0` to
    ///      estimate slippage and want a conservative upper bound on the current LP fee.
    ///      Callers that need the directional fee should read `pricingState[poolId]` directly.
    ///
    ///      `poolManager.updateDynamicLPFee` requires the pool to be initialized; subclass
    ///      init flows MUST call this AFTER `poolManager.initialize(key, …)`.
    ///
    ///      Safe to call inside a v4 unlock callback — `updateDynamicLPFee` does not require
    ///      unlock and the per-swap override (set in `_beforeSwap`) takes precedence over the
    ///      stored fee for the in-flight swap.
    /// @param key   The pool to update.
    /// @param state The new pricing state (validated for fee bounds).
    function _commitPricingState(PoolKey calldata key, PricingState memory state) internal {
        _validateFeeBounds(state);
        PoolId poolId = key.toId();
        pricingState[poolId] = state;

        uint24 representativeFee = state.live
            ? (state.bidFeePips > state.askFeePips ? state.bidFeePips : state.askFeePips)
            : 0;
        poolManager.updateDynamicLPFee(key, representativeFee);

        emit PricingStateUpdated(poolId, state);
    }

    // ──── Curve Update Logic ────

    function _applyCurveUpdate(PoolKey calldata key, bytes memory curveUpdateData) internal {
        (PricingState memory newState, PoolId updatePoolId, uint256 deadline, bytes memory sig) =
            abi.decode(curveUpdateData, (PricingState, PoolId, uint256, bytes));

        PoolId poolId = key.toId();
        _validateCurveUpdateMeta(poolId, updatePoolId, deadline);

        if (_checkAndMarkCurveUpdate(poolId, curveUpdateData)) {
            _verifySignature(newState, poolId, deadline, sig);
            _commitPricingState(key, newState);
        }
    }

    function _verifySignature(PricingState memory state, PoolId poolId, uint256 deadline, bytes memory sig)
        internal
        virtual
        view
    {
        bytes32 structHash = keccak256(
            abi.encode(
                PRICING_UPDATE_TYPEHASH,
                state.bidFeePips,
                state.askFeePips,
                state.live,
                PoolId.unwrap(poolId),
                deadline
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
    /// @dev Routes through `_commitPricingState` — validates fee bounds, writes storage, and
    ///      syncs the PM's stored dynamic LP fee. Reverts if `bidFeePips` or `askFeePips`
    ///      exceeds `LPFeeLibrary.MAX_LP_FEE` (H-04). The pool MUST already be initialized.
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
