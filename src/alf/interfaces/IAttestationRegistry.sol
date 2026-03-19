// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/// @notice Flow attestation data bound to a specific swap
struct Attestation {
    address attester; // The attesting interface (e.g., Uniswap frontend, TAPI)
    address swapper; // The user initiating the swap
    uint256 deadline; // Attestation expiry timestamp
    bytes32 swapHash; // keccak256(abi.encode(currency0, currency1, zeroForOne, amountSpecified))
}

/// @title IAttestationRegistry
/// @notice Shared registry of attestation keys. Verifies flow attestations for ALF hooks.
/// @dev Governance-managed attester whitelist. Hooks call verify() to check attestation validity.
///      The registry verifies signature and expiry but does NOT verify swapHash — that is the
///      calling hook's responsibility.
interface IAttestationRegistry {
    // ──── Events ────

    event AttesterAdded(address indexed attester);
    event AttesterRemoved(address indexed attester);

    // ──── Errors ────

    error AttesterAlreadyAuthorized();
    error AttesterNotAuthorized();

    // ──── Mutations (Governance controlled) ────

    /// @notice Add an authorized attester.
    /// @dev MUST be restricted to governance.
    /// @dev MUST emit AttesterAdded.
    /// @dev MUST revert if attester is already authorized.
    function addAttester(address attester) external;

    /// @notice Remove an authorized attester.
    /// @dev MUST be restricted to governance.
    /// @dev MUST emit AttesterRemoved.
    /// @dev MUST revert if attester is not authorized.
    function removeAttester(address attester) external;

    // ──── Views ────

    /// @notice Verify an attestation signature.
    /// @dev MUST NOT revert on invalid attestation. Returns isValid = false instead.
    /// @dev MUST return isValid = false if:
    ///      - The signature is invalid
    ///      - The recovered attester is not authorized
    ///      - block.timestamp > attestation.deadline
    /// @dev MUST NOT check swapHash (this is the caller's responsibility).
    /// @param attestationData ABI-encoded (Attestation, bytes signature).
    /// @return attestation The parsed attestation struct.
    /// @return isValid Whether the attestation is valid.
    function verify(bytes calldata attestationData) external view returns (Attestation memory attestation, bool isValid);

    /// @notice Check if an address is an authorized attester.
    function isAuthorizedAttester(address attester) external view returns (bool);
}
