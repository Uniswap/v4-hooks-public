// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";

/// @notice Primary update mode for a PropAMM quoter
enum QuoterType {
    STORAGE, // Pricing from persistent onchain storage
    HOOKDATA, // Pricing from signed parameters submitted via hookData
    EXTERNAL // Wrapper around an external PropAMM contract
}

/// @notice Metadata for a registered PropAMM quoter
struct QuoterEntry {
    address hook; // The v4 hook contract address
    PoolKey poolKey; // The pool this quoter operates
    QuoterType quoterType; // Primary update mode
    uint32 maxGas; // Declared gas upper bound for getIndicativeQuote
    bool isLive; // Self-reported liveness flag
    bytes metadata; // Arbitrary quoter-specific metadata
}

/// @title IPropAMMIndex
/// @notice Permissionless onchain registry for PropAMM quoter discoverability.
/// @dev Read by the router and auction hook to enumerate quoters for a given pair.
///      Does not participate in swap execution.
interface IPropAMMIndex {
    // ──── Events ────

    event QuoterRegistered(
        address indexed hook,
        Currency indexed currency0,
        Currency indexed currency1,
        PoolKey poolKey,
        QuoterType quoterType,
        uint32 maxGas
    );

    event QuoterUpdated(address indexed hook, PoolKey poolKey, bool isLive);

    event QuoterDeregistered(address indexed hook, PoolKey poolKey);

    // ──── Errors ────

    error UnauthorizedCaller();
    error AlreadyRegistered();
    error NotRegistered();

    // ──── Mutations ────

    /// @notice Register a quoter hook for a pair.
    /// @dev MUST revert if msg.sender != address(poolKey.hooks) (self-gating).
    /// @dev MUST revert if a registration already exists for this (hook, poolKey).
    /// @dev MUST emit QuoterRegistered.
    function register(PoolKey calldata poolKey, QuoterType quoterType, uint32 maxGas, bytes calldata metadata) external;

    /// @notice Update liveness and/or metadata for an existing registration.
    /// @dev MUST revert if msg.sender != address(poolKey.hooks).
    /// @dev MUST revert if no registration exists for this (hook, poolKey).
    /// @dev MUST emit QuoterUpdated.
    function update(PoolKey calldata poolKey, bool isLive, bytes calldata metadata) external;

    /// @notice Remove a registration.
    /// @dev MUST revert if msg.sender != address(poolKey.hooks).
    /// @dev MUST emit QuoterDeregistered.
    function deregister(PoolKey calldata poolKey) external;

    // ──── Views ────

    /// @notice Return all registered quoters for a currency pair.
    /// @dev The pair is unordered: getQuoters(A, B) == getQuoters(B, A).
    /// @dev Returns an empty array if no quoters are registered.
    function getQuoters(Currency currency0, Currency currency1) external view returns (QuoterEntry[] memory);

    /// @notice Return registered quoters of a specific type for a pair.
    function getQuotersByType(Currency currency0, Currency currency1, QuoterType quoterType)
        external
        view
        returns (QuoterEntry[] memory);

    /// @notice Return a single quoter entry.
    /// @dev MUST revert if no registration exists.
    function getQuoter(address hook, PoolKey calldata poolKey) external view returns (QuoterEntry memory);

    /// @notice Check if a registration exists.
    function isRegistered(address hook, PoolKey calldata poolKey) external view returns (bool);
}
