// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

/// @notice The fee configuration for each pool
struct FeeConfig {
    uint256 decayFactor;
    uint256 optimalFeeSpread;
    uint160 referenceSqrtPrice;
}
