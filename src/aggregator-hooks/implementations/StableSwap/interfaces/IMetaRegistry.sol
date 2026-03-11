// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

/// @title IMetaRegistry
/// @notice Minimal interface for Curve's MetaRegistry to check meta pool status
/// @dev See https://docs.curve.finance/developer/integration/meta-registry#is_meta
interface IMetaRegistry {
    /// @notice Check if a pool is a metapool
    /// @param _pool Address of the pool
    /// @param _handler_id ID of the RegistryHandler
    /// @return True if the pool is a metapool
    function is_meta(address _pool, uint256 _handler_id) external view returns (bool);
}
