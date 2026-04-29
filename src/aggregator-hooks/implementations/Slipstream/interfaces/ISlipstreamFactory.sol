// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/// @title ISlipstreamFactory
/// @notice Slipstream-style concentrated liquidity pools keyed by tickSpacing (e.g. Aerodrome Slipstream)
interface ISlipstreamFactory {
    function getPool(address tokenA, address tokenB, int24 tickSpacing) external view returns (address pool);
}
