// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {BaseHook} from "../../base/BaseHook.sol";
import {DeltaResolver} from "@uniswap/v4-periphery/src/base/DeltaResolver.sol";
import {IQuoterHook, QuoterHookData} from "../interfaces/IQuoterHook.sol";
import {IPropAMMIndex, QuoterType} from "../interfaces/IPropAMMIndex.sol";
import {IAttestationRegistry, Attestation} from "../interfaces/IAttestationRegistry.sol";

/// @title BasePropAMMHook
/// @notice Abstract base contract for PropAMM quoter hooks. Provides attestation resolution,
///         index management, and the IQuoterHook implementation. Quoters extend this and
///         implement _price() with their proprietary pricing logic.
/// @dev Follows the same BaseHook + DeltaResolver dual-inheritance pattern as BaseTokenWrapperHook.
abstract contract BasePropAMMHook is BaseHook, DeltaResolver, IQuoterHook {
    IPropAMMIndex public immutable index;
    IAttestationRegistry public immutable attestationRegistry;
    uint32 private immutable _maxGas;

    constructor(
        IPoolManager _poolManager,
        IPropAMMIndex _index,
        IAttestationRegistry _attestationRegistry,
        uint32 maxGas_
    ) BaseHook(_poolManager) {
        index = _index;
        attestationRegistry = _attestationRegistry;
        _maxGas = maxGas_;
    }

    // ──── IQuoterHook ────

    /// @inheritdoc IQuoterHook
    function maxGas() external view override returns (uint32) {
        return _maxGas;
    }

    /// @inheritdoc IQuoterHook
    function getIndicativeQuote(
        PoolKey calldata key,
        bool zeroForOne,
        int256 amountSpecified,
        bytes calldata hookData
    ) external view virtual override returns (uint256 outputAmount) {
        bytes memory attestationData;
        if (hookData.length > 0) {
            QuoterHookData memory hd = abi.decode(hookData, (QuoterHookData));
            attestationData = hd.attestationData;
        }
        (bool isAttested, address attester) = _resolveAttestation(attestationData);
        return _price(key, zeroForOne, amountSpecified, isAttested, attester);
    }

    /// @inheritdoc IQuoterHook
    function isLive() external view virtual override returns (bool);

    // ──── Internal: Attestation ────

    /// @dev Parse and verify attestation from raw bytes.
    /// @return isAttested Whether a valid attestation was provided.
    /// @return attester The attester address (zero if not attested).
    function _resolveAttestation(bytes memory attestationData)
        internal
        view
        returns (bool isAttested, address attester)
    {
        if (attestationData.length == 0) return (false, address(0));
        (Attestation memory att, bool valid) = attestationRegistry.verify(attestationData);
        return (valid, valid ? att.attester : address(0));
    }

    // ──── Internal: Index Management ────

    /// @dev Register this hook in the PropAMMIndex.
    function _registerInIndex(PoolKey calldata poolKey, QuoterType quoterType, bytes memory metadata) internal {
        index.register(poolKey, quoterType, _maxGas, metadata);
    }

    /// @dev Update liveness status in the PropAMMIndex.
    function _setLive(PoolKey calldata poolKey, bool live) internal {
        index.update(poolKey, live, "");
    }

    /// @dev Deregister from the PropAMMIndex.
    function _deregisterFromIndex(PoolKey calldata poolKey) internal {
        index.deregister(poolKey);
    }

    // ──── Abstract: Pricing ────

    /// @dev Subclasses MUST implement pricing logic.
    /// @param key The pool key.
    /// @param zeroForOne The swap direction.
    /// @param amountSpecified The swap amount. Negative = exact input.
    /// @param isAttested Whether the swap has a valid attestation.
    /// @param attester The attester address (zero if not attested).
    /// @return outputAmount The quoted output.
    function _price(
        PoolKey calldata key,
        bool zeroForOne,
        int256 amountSpecified,
        bool isAttested,
        address attester
    ) internal view virtual returns (uint256 outputAmount);

    // ──── DeltaResolver: _pay ────

    /// @dev Transfer tokens to the pool manager for delta settlement.
    function _pay(Currency token, address, uint256 amount) internal override {
        token.transfer(address(poolManager), amount);
    }
}
