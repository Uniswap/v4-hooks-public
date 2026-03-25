// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {BaseHook} from "../../base/BaseHook.sol";
import {DeltaResolver} from "@uniswap/v4-periphery/src/base/DeltaResolver.sol";
import {IALFHook, ALFHookData} from "../interfaces/IALFHook.sol";

/// @title BaseALFHook
/// @notice Abstract base contract for ALF hooks. Provides hookData resolution, settlement
///         helpers, curve update bookkeeping, and the IALFHook interface. Quoters extend
///         this and implement _price() with their proprietary pricing logic.
/// @dev Follows the same BaseHook + DeltaResolver dual-inheritance pattern as BaseTokenWrapperHook.
abstract contract BaseALFHook is BaseHook, DeltaResolver, IALFHook {
    uint32 private immutable _maxGas;

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
    function _resolveAttestation(bytes memory)
        internal
        view
        virtual
        returns (bool isAttested, address attester)
    {
        return (false, address(0));
    }

    // ──── Internal: Settlement ────

    /// @dev Settle an amount to the PoolManager, preferring ERC-6909 claim burns over ERC-20.
    function _settleWithClaimPriority(Currency currency, uint256 amount) internal {
        uint256 claimBal = poolManager.balanceOf(address(this), currency.toId());
        if (claimBal >= amount) {
            poolManager.burn(address(this), currency.toId(), amount);
        } else if (claimBal > 0) {
            poolManager.burn(address(this), currency.toId(), claimBal);
            _settle(currency, address(this), amount - claimBal);
        } else {
            _settle(currency, address(this), amount);
        }
    }

    // ──── Internal: Signed Curve Updates ────

    mapping(PoolId => mapping(uint256 => bytes32)) internal _curveUpdateHash;
    address public priceSigner;

    error ExpiredUpdate();
    error PoolMismatch();
    error ConflictingCurveUpdate();
    error InvalidPriceSigner();

    event PriceSignerUpdated(address indexed newSigner);

    function _validateCurveUpdateMeta(PoolId poolId, PoolId updatePoolId, uint256 deadline) internal view {
        if (PoolId.unwrap(updatePoolId) != PoolId.unwrap(poolId)) revert PoolMismatch();
        if (block.timestamp > deadline) revert ExpiredUpdate();
    }

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
