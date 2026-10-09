// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @notice Stands in for the ArbSys precompile (0x64) in forge's local EVM, which runs a Nitro fork's placeholder
///         code there as INVALID. Local execution only: scripts etch its code at 0x64 and never broadcast it.
contract ArbSysMock {
    function arbBlockNumber() external view returns (uint256) {
        return block.number;
    }
}
