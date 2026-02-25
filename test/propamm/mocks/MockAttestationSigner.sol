// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Vm} from "forge-std/Vm.sol";
import {Attestation} from "../../../src/propamm/interfaces/IAttestationRegistry.sol";

/// @title MockAttestationSigner
/// @notice Test helper for generating EIP-712 signed attestation payloads
library MockAttestationSigner {
    bytes32 constant ATTESTATION_TYPEHASH =
        keccak256("Attestation(address attester,address swapper,uint256 deadline,bytes32 swapHash)");

    /// @notice Build the EIP-712 digest for an attestation
    function buildDigest(Attestation memory att, address registry) internal view returns (bytes32) {
        bytes32 domainSeparator = _domainSeparator(registry);
        bytes32 structHash = keccak256(
            abi.encode(ATTESTATION_TYPEHASH, att.attester, att.swapper, att.deadline, att.swapHash)
        );
        return keccak256(abi.encodePacked("\x19\x01", domainSeparator, structHash));
    }

    /// @notice Sign an attestation and return the ABI-encoded attestationData
    function sign(Vm vm, uint256 privateKey, Attestation memory att, address registry)
        internal
        view
        returns (bytes memory attestationData)
    {
        bytes32 digest = buildDigest(att, registry);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(privateKey, digest);
        bytes memory signature = abi.encodePacked(r, s, v);
        attestationData = abi.encode(att, signature);
    }

    function _domainSeparator(address registry) private view returns (bytes32) {
        bytes32 typeHash = keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");
        return keccak256(
            abi.encode(typeHash, keccak256("Attestation"), keccak256("1"), block.chainid, registry)
        );
    }
}
