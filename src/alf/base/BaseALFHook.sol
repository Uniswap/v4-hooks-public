// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {BaseHook} from "../../base/BaseHook.sol";
import {DeltaResolver} from "@uniswap/v4-periphery/src/base/DeltaResolver.sol";
import {IALFHook, ALFHookData} from "../interfaces/IALFHook.sol";

/// @title BaseALFHook
/// @author Uniswap Labs
/// @notice Abstract base contract for ALF hooks. Provides hookData resolution, settlement
///         helpers, curve update bookkeeping, and the IALFHook interface. Quoters extend
///         this and implement _price() with their proprietary pricing logic.
/// @dev Follows the same BaseHook + DeltaResolver dual-inheritance pattern as BaseTokenWrapperHook.
/// @custom:security-contact security@uniswap.org
abstract contract BaseALFHook is BaseHook, DeltaResolver, IALFHook {
    /// @dev Gas budget declared for `getIndicativeQuote` staticcalls. Returned by `maxGas()`.
    uint32 private immutable _maxGas;

    /// @param _poolManager The Uniswap v4 PoolManager.
    /// @param maxGas_      Gas budget declared for `getIndicativeQuote` staticcalls.
    constructor(IPoolManager _poolManager, uint32 maxGas_) BaseHook(_poolManager) {
        _maxGas = maxGas_;
    }

    // ──── IALFHook ────

    /// @inheritdoc IALFHook
    function maxGas() external view override returns (uint32) {
        return _maxGas;
    }

    /// @inheritdoc IALFHook
    function getIndicativeQuote(PoolKey calldata key, bool zeroForOne, int256 amountSpecified, bytes calldata hookData)
        external
        view
        virtual
        override
        returns (uint256 outputAmount)
    {
        (, bool isAttested, address attester) = _resolveHookData(hookData);
        return _price(key, zeroForOne, amountSpecified, isAttested, attester);
    }

    /// @inheritdoc IALFHook
    function isLive() external view virtual override returns (bool);

    // ──── Reserves (default: no off-pool reserves) ────

    /// @inheritdoc IALFHook
    function getReserves(PoolKey calldata) external view virtual override returns (uint256, uint256) {
        return (0, 0);
    }

    /// @inheritdoc IALFHook
    function getEffectiveLiquidity(PoolKey calldata) external view virtual override returns (uint256, uint256) {
        return (0, 0);
    }

    // ──── Price-bounded simulation (default: unsupported) ────

    /// @inheritdoc IALFHook
    function swapToPrice(PoolKey calldata, bool, int256, uint160, bytes calldata)
        external
        view
        virtual
        override
        returns (uint256, uint256)
    {
        return (0, 0);
    }

    // ──── Internal: HookData Resolution ────

    /// @dev Decode ALFHookData and resolve attestation. Returns curve update payload and
    ///      attestation result. The base implementation does not verify attestations —
    ///      subclasses that want attestation support override _resolveAttestation with
    ///      their own EIP-712 verification against priceSigner.
    function _resolveHookData(bytes calldata hookData)
        internal
        view
        returns (bytes memory curveUpdateData, bool isAttested, address attester)
    {
        if (hookData.length == 0) return ("", false, address(0));
        ALFHookData memory hd = abi.decode(hookData, (ALFHookData));
        curveUpdateData = hd.curveUpdateData;
        (isAttested, attester) = _resolveAttestation(hd.attestationData);
    }

    /// @dev Resolve attestation from raw bytes. Default returns (false, address(0)).
    ///      Subclasses can override to verify attestationData against their own signer
    ///      using the hook's EIP-712 infrastructure and priceSigner.
    function _resolveAttestation(bytes memory) internal view virtual returns (bool isAttested, address attester) {
        return (false, address(0));
    }

    // ──── Internal: Signed Curve Updates ────

    /// @dev Per-block, per-pool curve update fingerprint. Used by `_checkAndMarkCurveUpdate`
    ///      to enforce one-update-per-block: the first call records the hash, subsequent calls
    ///      with the same hash are accepted as no-ops, and any conflict reverts.
    mapping(PoolId => mapping(uint256 => bytes32)) internal _curveUpdateHash;

    /// @notice Authorized signer for hookData curve updates.
    /// @dev    `address(0)` disables signed updates entirely (no recovered signer can match).
    address public priceSigner;

    /// @dev The curve update's `deadline` is in the past relative to `block.timestamp`.
    error ExpiredUpdate();
    /// @dev The curve update was signed for a different pool than the one it's being applied to.
    error PoolMismatch();
    /// @dev Two distinct curve updates were submitted for the same `(poolId, block.number)`.
    ///      Without this guard, conflicting updates would race within a block.
    error ConflictingCurveUpdate();
    /// @dev The recovered signer of a curve update does not match `priceSigner`.
    error InvalidPriceSigner();

    /// @notice Emitted when the authorized price signer is rotated.
    /// @param newSigner The new signer (`address(0)` disables signed updates).
    event PriceSignerUpdated(address indexed newSigner);

    /// @dev Validate the metadata fields of a curve update before signature recovery.
    ///      Reverts with {PoolMismatch} or {ExpiredUpdate} on failure.
    function _validateCurveUpdateMeta(PoolId poolId, PoolId updatePoolId, uint256 deadline) internal view {
        if (PoolId.unwrap(updatePoolId) != PoolId.unwrap(poolId)) revert PoolMismatch();
        if (block.timestamp > deadline) revert ExpiredUpdate();
    }

    /// @dev Record this block's curve update for the pool, enforcing one-update-per-block.
    ///      Returns true the first time a hash is seen (caller should verify and apply).
    ///      Returns false on a duplicate (same hash, no-op). Reverts with {ConflictingCurveUpdate}
    ///      if a different hash already occupies the slot.
    /// @param poolId         The pool the update targets.
    /// @param curveUpdateData The encoded update payload (hashed for the slot key).
    /// @return isNew True if this is the first update for `(poolId, block.number)`.
    function _checkAndMarkCurveUpdate(PoolId poolId, bytes memory curveUpdateData) internal returns (bool isNew) {
        bytes32 updateHash = keccak256(curveUpdateData);
        bytes32 existing = _curveUpdateHash[poolId][block.number];
        if (existing == bytes32(0)) {
            _curveUpdateHash[poolId][block.number] = updateHash;
            return true;
        }
        if (existing != updateHash) revert ConflictingCurveUpdate();
        return false;
    }

    // ──── Abstract: Pricing ────

    /// @dev Subclasses MUST implement pricing logic.
    function _price(PoolKey calldata key, bool zeroForOne, int256 amountSpecified, bool isAttested, address attester)
        internal
        view
        virtual
        returns (uint256 outputAmount);

    // ──── DeltaResolver: _pay ────

    function _pay(Currency token, address, uint256 amount) internal override {
        token.transfer(address(poolManager), amount);
    }
}
