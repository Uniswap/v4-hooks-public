// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IAttestationRegistry, Attestation} from "./interfaces/IAttestationRegistry.sol";
import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {Ownable2Step, Ownable} from "@openzeppelin/contracts/access/Ownable2Step.sol";

/// @title AttestationRegistry
/// @notice Shared registry of attestation keys. Verifies flow attestations for ALF hooks.
/// @dev Governance-managed attester whitelist with EIP-712 signature verification.
///      verify() is guaranteed non-reverting — malformed input returns isValid = false.
contract AttestationRegistry is IAttestationRegistry, EIP712, Ownable2Step {
    bytes32 public constant ATTESTATION_TYPEHASH =
        keccak256("Attestation(address attester,address swapper,uint256 deadline,bytes32 swapHash)");

    mapping(address => bool) internal _authorizedAttesters;

    constructor(address owner_) EIP712("Attestation", "1") Ownable(owner_) {}

    // ──── Governance Mutations ────

    /// @inheritdoc IAttestationRegistry
    function addAttester(address attester) external onlyOwner {
        if (_authorizedAttesters[attester]) revert AttesterAlreadyAuthorized();
        _authorizedAttesters[attester] = true;
        emit AttesterAdded(attester);
    }

    /// @inheritdoc IAttestationRegistry
    function removeAttester(address attester) external onlyOwner {
        if (!_authorizedAttesters[attester]) revert AttesterNotAuthorized();
        _authorizedAttesters[attester] = false;
        emit AttesterRemoved(attester);
    }

    // ──── Views ────

    /// @inheritdoc IAttestationRegistry
    /// @dev Wraps _verifyUnchecked in try/catch to guarantee non-reverting behavior.
    function verify(bytes calldata attestationData)
        external
        view
        returns (Attestation memory attestation, bool isValid)
    {
        try this.verifyUnchecked(attestationData) returns (Attestation memory att, bool valid) {
            return (att, valid);
        } catch {
            return (attestation, false);
        }
    }

    /// @notice Internal verification that may revert on malformed input.
    /// @dev Public so it can be called via try/catch on `this`. Callers should use verify() instead.
    function verifyUnchecked(bytes calldata attestationData)
        external
        view
        returns (Attestation memory attestation, bool isValid)
    {
        bytes memory signature;
        (attestation, signature) = abi.decode(attestationData, (Attestation, bytes));

        // Check deadline
        if (block.timestamp > attestation.deadline) return (attestation, false);

        // Check attester authorization
        if (!_authorizedAttesters[attestation.attester]) return (attestation, false);

        // Recover signer from EIP-712 typed data hash
        bytes32 structHash = keccak256(
            abi.encode(
                ATTESTATION_TYPEHASH,
                attestation.attester,
                attestation.swapper,
                attestation.deadline,
                attestation.swapHash
            )
        );
        bytes32 digest = _hashTypedDataV4(structHash);

        (address recovered, ECDSA.RecoverError err,) = ECDSA.tryRecover(digest, signature);
        isValid = (err == ECDSA.RecoverError.NoError && recovered == attestation.attester);
    }

    /// @inheritdoc IAttestationRegistry
    function isAuthorizedAttester(address attester) external view returns (bool) {
        return _authorizedAttesters[attester];
    }
}
