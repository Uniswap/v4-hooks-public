// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

/// @notice hookData encoding for the ALF auction hook.
/// @dev Callers encode hookData as `abi.encode(AuctionHookData(...))`.
///
///      The auction queries the specified target quoters via IALFHook, constructing
///      per-quoter hookData that pairs the shared attestation with each quoter's
///      curve update. The winner's nested swap receives its specific curve update
///      for on-chain application. Targets MUST be non-empty.
struct AuctionHookData {
    bytes attestationData; // Shared attestation payload (optional)
    TargetedQuoter[] targets; // Must be non-empty (targeted mode only)
    uint24 strictTolerancePips; // 0 = no check; >0 = max relative deviation (ppm) before revert
}

/// @notice A specific quoter to query in targeted auction mode.
/// @dev The `curveUpdateData` is quoter-specific (e.g., PricingState for SimpleSpread,
///      FlatPricingState for FlatLevel). The auction hook does not interpret it — it
///      passes it through to the target quoter via ALFHookData.curveUpdateData.
struct TargetedQuoter {
    PoolKey poolKey; // The quoter's pool key (hook address embedded in poolKey.hooks)
    bytes curveUpdateData; // Quoter-specific signed curve update, or empty
}
