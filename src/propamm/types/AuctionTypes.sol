// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

/// @notice hookData encoding for the PropAMM auction hook.
/// @dev Callers encode hookData as `abi.encode(AuctionHookData(...))`.
///
///      Two call paths depending on `targets`:
///
///      1. **Discovery** (`targets` empty): The auction discovers all registered quoters
///         from the PropAMMIndex and queries them with attestation-only hookData.
///         No per-quoter curve updates are possible in this mode.
///
///      2. **Targeted** (`targets` non-empty): The auction queries only the specified
///         quoters, constructing per-quoter hookData that pairs the shared attestation
///         with each quoter's curve update. The winner's nested swap receives its
///         specific curve update for on-chain application.
struct AuctionHookData {
    bytes attestationData; // Shared attestation payload (optional)
    TargetedQuoter[] targets; // Empty = discovery mode; non-empty = targeted mode
    bool strict; // If true, revert when executed output deviates from indicative quote
}

/// @notice A specific quoter to query in targeted auction mode.
/// @dev The `curveUpdateData` is quoter-specific (e.g., PricingState for SimpleSpread,
///      FlatPricingState for FlatLevel). The auction hook does not interpret it — it
///      passes it through to the target quoter via QuoterHookData.curveUpdateData.
struct TargetedQuoter {
    PoolKey poolKey; // The quoter's pool key (hook address embedded in poolKey.hooks)
    bytes curveUpdateData; // Quoter-specific signed curve update, or empty
}
