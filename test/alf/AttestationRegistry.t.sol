// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {AttestationRegistry} from "../../src/alf/AttestationRegistry.sol";
import {IAttestationRegistry, Attestation} from "../../src/alf/interfaces/IAttestationRegistry.sol";
import {MockAttestationSigner} from "./mocks/MockAttestationSigner.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

contract AttestationRegistryTest is Test {
    AttestationRegistry public registry;

    address owner = makeAddr("owner");
    address swapper = makeAddr("swapper");

    uint256 attesterPk;
    address attester;

    function setUp() public {
        registry = new AttestationRegistry(owner);
        (attester, attesterPk) = makeAddrAndKey("attester");

        vm.prank(owner);
        registry.addAttester(attester);
    }

    function _makeAttestation(uint256 deadline) internal view returns (Attestation memory) {
        return Attestation({
            attester: attester, swapper: swapper, deadline: deadline, swapHash: keccak256(abi.encode("test-swap"))
        });
    }

    function _signAttestation(Attestation memory att, uint256 pk) internal view returns (bytes memory) {
        return MockAttestationSigner.sign(vm, pk, att, address(registry));
    }

    // ──── Attester management ────

    function test_addAttester_succeeds() public {
        address newAttester = makeAddr("newAttester");

        vm.expectEmit(true, false, false, false);
        emit IAttestationRegistry.AttesterAdded(newAttester);

        vm.prank(owner);
        registry.addAttester(newAttester);

        assertTrue(registry.isAuthorizedAttester(newAttester));
    }

    function test_addAttester_revertsUnauthorized() public {
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, address(this)));
        registry.addAttester(makeAddr("x"));
    }

    function test_addAttester_revertsDuplicate() public {
        vm.expectRevert(IAttestationRegistry.AttesterAlreadyAuthorized.selector);
        vm.prank(owner);
        registry.addAttester(attester);
    }

    function test_removeAttester_succeeds() public {
        vm.expectEmit(true, false, false, false);
        emit IAttestationRegistry.AttesterRemoved(attester);

        vm.prank(owner);
        registry.removeAttester(attester);

        assertFalse(registry.isAuthorizedAttester(attester));
    }

    function test_removeAttester_revertsUnauthorized() public {
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, address(this)));
        registry.removeAttester(attester);
    }

    function test_removeAttester_revertsNotAuthorized() public {
        vm.expectRevert(IAttestationRegistry.AttesterNotAuthorized.selector);
        vm.prank(owner);
        registry.removeAttester(makeAddr("unknown"));
    }

    // ──── verify: valid attestation ────

    function test_verify_validAttestation() public view {
        Attestation memory att = _makeAttestation(block.timestamp + 1 hours);
        bytes memory attestationData = _signAttestation(att, attesterPk);

        (Attestation memory result, bool isValid) = registry.verify(attestationData);

        assertTrue(isValid);
        assertEq(result.attester, attester);
        assertEq(result.swapper, swapper);
        assertEq(result.deadline, att.deadline);
        assertEq(result.swapHash, att.swapHash);
    }

    // ──── verify: invalid cases (all return false, not revert) ────

    function test_verify_invalidSignature() public {
        Attestation memory att = _makeAttestation(block.timestamp + 1 hours);
        // Sign with a different key
        (, uint256 wrongPk) = makeAddrAndKey("wrongKey");
        bytes memory attestationData = _signAttestation(att, wrongPk);

        (, bool isValid) = registry.verify(attestationData);
        assertFalse(isValid);
    }

    function test_verify_expiredDeadline() public view {
        Attestation memory att = _makeAttestation(block.timestamp - 1);
        bytes memory attestationData = _signAttestation(att, attesterPk);

        (, bool isValid) = registry.verify(attestationData);
        assertFalse(isValid);
    }

    function test_verify_unauthorizedAttester() public {
        // Remove the attester first
        vm.prank(owner);
        registry.removeAttester(attester);

        Attestation memory att = _makeAttestation(block.timestamp + 1 hours);
        bytes memory attestationData = _signAttestation(att, attesterPk);

        (, bool isValid) = registry.verify(attestationData);
        assertFalse(isValid);
    }

    function test_verify_malformedData() public view {
        // Garbage bytes should return false, not revert
        bytes memory garbage = hex"deadbeef";
        (, bool isValid) = registry.verify(garbage);
        assertFalse(isValid);
    }

    function test_verify_emptyData() public view {
        (, bool isValid) = registry.verify("");
        assertFalse(isValid);
    }

    function test_verify_exactDeadline() public view {
        // deadline == block.timestamp should be valid (not expired)
        Attestation memory att = _makeAttestation(block.timestamp);
        bytes memory attestationData = _signAttestation(att, attesterPk);

        (, bool isValid) = registry.verify(attestationData);
        assertTrue(isValid);
    }

    // ──── isAuthorizedAttester ────

    function test_isAuthorizedAttester_returnsFalseForUnknown() public {
        assertFalse(registry.isAuthorizedAttester(makeAddr("nobody")));
    }
}
