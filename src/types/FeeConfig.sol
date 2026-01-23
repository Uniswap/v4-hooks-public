// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

/// @notice The fee configuration for each pool
struct FeeConfig {
    uint256 decayFactor;
    uint24 optimalFeeRate;
    uint160 referenceSqrtPriceX96;
}
