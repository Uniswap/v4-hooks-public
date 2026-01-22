// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

/// @notice The historical fee data for each pool
struct HistoricalFeeData {
    uint24 previousFee;
    uint160 previousSqrtAmmPrice;
    uint256 blockNumber;
}
