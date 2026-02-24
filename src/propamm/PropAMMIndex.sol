// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {IPropAMMIndex, QuoterEntry, QuoterType} from "./interfaces/IPropAMMIndex.sol";
import {PairLib} from "./libraries/PairLib.sol";

/// @title PropAMMIndex
/// @notice Permissionless onchain registry for PropAMM quoter discoverability.
/// @dev One per chain. Read by the router and auction hook. Does not participate in swap execution.
contract PropAMMIndex is IPropAMMIndex {
    using PoolIdLibrary for PoolKey;
    using PairLib for Currency;

    /// @dev Canonical pair (min, max) → array of quoter entries
    mapping(Currency => mapping(Currency => QuoterEntry[])) internal _quotersByPair;

    /// @dev (hook, PoolId) → 1-indexed position in the pair array. 0 = not registered.
    mapping(address => mapping(PoolId => uint256)) internal _quoterIndex;

    // ──── Modifiers ────

    modifier onlyHook(PoolKey calldata poolKey) {
        if (msg.sender != address(poolKey.hooks)) revert UnauthorizedCaller();
        _;
    }

    // ──── Mutations ────

    /// @inheritdoc IPropAMMIndex
    function register(PoolKey calldata poolKey, QuoterType quoterType, uint32 maxGas, bytes calldata metadata)
        external
        onlyHook(poolKey)
    {
        PoolId pid = poolKey.toId();
        if (_quoterIndex[msg.sender][pid] != 0) revert AlreadyRegistered();

        (Currency c0, Currency c1) = PairLib.canonical(poolKey.currency0, poolKey.currency1);

        _quotersByPair[c0][c1].push(
            QuoterEntry({
                hook: msg.sender,
                poolKey: poolKey,
                quoterType: quoterType,
                maxGas: maxGas,
                isLive: true,
                metadata: metadata
            })
        );

        // Store 1-indexed position
        _quoterIndex[msg.sender][pid] = _quotersByPair[c0][c1].length;

        emit QuoterRegistered(msg.sender, c0, c1, poolKey, quoterType, maxGas);
    }

    /// @inheritdoc IPropAMMIndex
    function update(PoolKey calldata poolKey, bool isLive, bytes calldata metadata) external onlyHook(poolKey) {
        PoolId pid = poolKey.toId();
        uint256 idx = _quoterIndex[msg.sender][pid];
        if (idx == 0) revert NotRegistered();

        (Currency c0, Currency c1) = PairLib.canonical(poolKey.currency0, poolKey.currency1);
        QuoterEntry storage entry = _quotersByPair[c0][c1][idx - 1];
        entry.isLive = isLive;
        if (metadata.length > 0) {
            entry.metadata = metadata;
        }

        emit QuoterUpdated(msg.sender, poolKey, isLive);
    }

    /// @inheritdoc IPropAMMIndex
    function deregister(PoolKey calldata poolKey) external onlyHook(poolKey) {
        PoolId pid = poolKey.toId();
        uint256 idx = _quoterIndex[msg.sender][pid];
        if (idx == 0) revert NotRegistered();

        (Currency c0, Currency c1) = PairLib.canonical(poolKey.currency0, poolKey.currency1);
        QuoterEntry[] storage entries = _quotersByPair[c0][c1];
        uint256 lastIdx = entries.length - 1;

        if (idx - 1 != lastIdx) {
            // Swap with last element
            QuoterEntry storage lastEntry = entries[lastIdx];
            entries[idx - 1] = lastEntry;
            // Update the swapped element's index
            _quoterIndex[lastEntry.hook][lastEntry.poolKey.toId()] = idx;
        }

        entries.pop();
        delete _quoterIndex[msg.sender][pid];

        emit QuoterDeregistered(msg.sender, poolKey);
    }

    // ──── Views ────

    /// @inheritdoc IPropAMMIndex
    function getQuoters(Currency currency0, Currency currency1) external view returns (QuoterEntry[] memory) {
        (Currency c0, Currency c1) = PairLib.canonical(currency0, currency1);
        return _quotersByPair[c0][c1];
    }

    /// @inheritdoc IPropAMMIndex
    function getQuotersByType(Currency currency0, Currency currency1, QuoterType quoterType)
        external
        view
        returns (QuoterEntry[] memory)
    {
        (Currency c0, Currency c1) = PairLib.canonical(currency0, currency1);
        QuoterEntry[] storage all = _quotersByPair[c0][c1];

        // First pass: count matching entries
        uint256 count;
        for (uint256 i; i < all.length; i++) {
            if (all[i].quoterType == quoterType) count++;
        }

        // Second pass: populate result
        QuoterEntry[] memory result = new QuoterEntry[](count);
        uint256 j;
        for (uint256 i; i < all.length; i++) {
            if (all[i].quoterType == quoterType) {
                result[j++] = all[i];
            }
        }

        return result;
    }

    /// @inheritdoc IPropAMMIndex
    function getQuoter(address hook, PoolKey calldata poolKey) external view returns (QuoterEntry memory) {
        PoolId pid = poolKey.toId();
        uint256 idx = _quoterIndex[hook][pid];
        if (idx == 0) revert NotRegistered();

        (Currency c0, Currency c1) = PairLib.canonical(poolKey.currency0, poolKey.currency1);
        return _quotersByPair[c0][c1][idx - 1];
    }

    /// @inheritdoc IPropAMMIndex
    function isRegistered(address hook, PoolKey calldata poolKey) external view returns (bool) {
        return _quoterIndex[hook][poolKey.toId()] != 0;
    }
}
