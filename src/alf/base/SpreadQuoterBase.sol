// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

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
        uint16 attestedDiscountBps; // Fee reduction for attested flow (bps, 1 bps = 100 pips fee reduction)
        bool live;
    }

    bytes32 private constant PRICING_UPDATE_TYPEHASH = keccak256(
        "PricingUpdate(uint24 bidFeePips,uint24 askFeePips,uint16 attestedDiscountBps,bool live,bytes32 poolId,uint256 deadline)"
    );

    mapping(PoolId => PricingState) public pricingState;
    mapping(PoolId => int24) public activeLowerTick;

    event PricingStateUpdated(PoolId indexed poolId, PricingState state);
    event PoolLivenessUpdated(PoolId indexed poolId, bool isLive);
    event ActiveTickUpdated(PoolId indexed poolId, int24 activeLowerTick);

    error InvalidTickRange();
    error WrongActiveTick();

    constructor(
        IPoolManager _poolManager,
        uint32 maxGas_,
        address owner_,
        string memory eip712Name
    ) BaseALFHook(_poolManager, maxGas_) EIP712(eip712Name, "1") Ownable(owner_) {}

    // ──── IALFHook ────

    function isLive() external pure override returns (bool) {
        return true;
    }

    /// @notice Indicative quote with hookData-aware pricing.
    /// @dev If hookData contains a curve update, the new pricing is used for the simulation
    ///      without modifying storage (view function).
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
            (PricingState memory newState,,,) =
                abi.decode(curveUpdateData, (PricingState, PoolId, uint256, bytes));
            state = newState;
        }

        return _priceWithState(key, zeroForOne, amountSpecified, isAttested, attester, state);
    }

    /// @notice Simulate a swap up to a target price, returning both amounts.
    /// @dev Resolves hookData (curve updates, attestation) the same way as getIndicativeQuote,
    ///      then delegates to SwapSimulator.simulateSwapToPrice with the effective fee.
    function swapToPrice(
        PoolKey calldata key,
        bool zeroForOne,
        int256 amountSpecified,
        uint160 sqrtPriceLimitX96,
        bytes calldata hookData
    ) external view virtual override returns (uint256 amountIn, uint256 amountOut) {
        uint24 feePips;
        {
            (bytes memory curveUpdateData, bool isAttested,) = _resolveHookData(hookData);

            PricingState memory state = pricingState[key.toId()];
            if (curveUpdateData.length > 0) {
                (PricingState memory newState,,,) =
                    abi.decode(curveUpdateData, (PricingState, PoolId, uint256, bytes));
                state = newState;
            }

            if (!state.live) return (0, 0);
            feePips = _effectiveFee(state, zeroForOne, isAttested);
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
        (bytes memory curveUpdateData, bool isAttested,) = _resolveHookData(hookData);

        if (curveUpdateData.length > 0) {
            _applyCurveUpdate(key.toId(), curveUpdateData);
        }

        PricingState memory state = pricingState[key.toId()];
        if (!state.live) {
            return (IHooks.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
        }

        uint24 feePips = _effectiveFee(state, params.zeroForOne, isAttested);
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
        bool isAttested,
        address,
        PricingState memory state
    ) internal view returns (uint256 outputAmount) {
        if (!state.live) return 0;

        uint24 feePips = _effectiveFee(state, zeroForOne, isAttested);
        outputAmount =
            SwapSimulator.simulateSwap(poolManager, key.toId(), zeroForOne, amountSpecified, feePips, key.tickSpacing);
    }

    /// @dev Compute the effective fee for a swap direction, reducing the spread for attested flow.
    ///      Used by both _beforeSwap (execution) and _priceWithState (indicative) to ensure fidelity.
    function _effectiveFee(PricingState memory state, bool zeroForOne, bool isAttested)
        internal
        pure
        returns (uint24 feePips)
    {
        feePips = zeroForOne ? state.bidFeePips : state.askFeePips;
        if (isAttested && state.attestedDiscountBps > 0) {
            uint24 discount = uint24(state.attestedDiscountBps) * 100; // bps → pips
            feePips = feePips > discount ? feePips - discount : 0;
        }
    }

    // ──── Curve Update Logic ────

    function _applyCurveUpdate(PoolId poolId, bytes memory curveUpdateData) internal {
        (PricingState memory newState, PoolId updatePoolId, uint256 deadline, bytes memory sig) =
            abi.decode(curveUpdateData, (PricingState, PoolId, uint256, bytes));

        _validateCurveUpdateMeta(poolId, updatePoolId, deadline);

        if (_checkAndMarkCurveUpdate(poolId, curveUpdateData)) {
            _verifySignature(newState, poolId, deadline, sig);
            pricingState[poolId] = newState;
            emit PricingStateUpdated(poolId, newState);
        }
    }

    function _verifySignature(PricingState memory state, PoolId poolId, uint256 deadline, bytes memory sig)
        internal
        view
    {
        bytes32 structHash = keccak256(
            abi.encode(
                PRICING_UPDATE_TYPEHASH,
                state.bidFeePips,
                state.askFeePips,
                state.attestedDiscountBps,
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
    function updatePricingState(PoolKey calldata key, PricingState calldata state) external onlyOwner {
        pricingState[key.toId()] = state;
        emit PricingStateUpdated(key.toId(), state);
    }

    /// @notice Toggle liveness for a pool.
    function setPoolLive(PoolKey calldata key, bool live) external onlyOwner {
        pricingState[key.toId()].live = live;
        emit PoolLivenessUpdated(key.toId(), live);
    }

    /// @notice Set the authorized price signer for hookData curve updates.
    function setPriceSigner(address _priceSigner) external onlyOwner {
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
