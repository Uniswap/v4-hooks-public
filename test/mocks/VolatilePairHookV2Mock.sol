// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {VolatilePairHook} from "../../src/volatile/VolatilePairHook.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";

/// A next version shaped the way a real V2 must be: inherited storage untouched, new state in its own appended
/// ERC-7201 namespace. See docs/technical/UpgradeRunbook.md.
contract VolatilePairHookV2Mock is VolatilePairHook {
    /// @custom:storage-location erc7201:uniswap.storage.VolatilePairHookV2Mock
    struct VolatilePairHookV2MockStorage {
        uint256 newValue;
    }

    /// keccak256(abi.encode(uint256(keccak256("uniswap.storage.VolatilePairHookV2Mock")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant V2_MOCK_STORAGE_LOCATION =
        0xe90d654d9eef4dc3b11d9e617b4016f4cccbc882e48d96738aa44c0d8bd8df00;

    constructor(IPoolManager _manager, uint256 _maxTempFeeBlockGap) VolatilePairHook(_manager, _maxTempFeeBlockGap) {}

    function _getV2MockStorage() private pure returns (VolatilePairHookV2MockStorage storage $) {
        assembly ("memory-safe") {
            $.slot := V2_MOCK_STORAGE_LOCATION
        }
    }

    /// Initializes only the state this version adds; V1's initializers already ran in the proxy.
    function initializeV2(uint256 _newValue) external reinitializer(2) {
        _getV2MockStorage().newValue = _newValue;
    }

    function newValue() external view returns (uint256) {
        return _getV2MockStorage().newValue;
    }

    function version() external pure returns (uint256) {
        return 2;
    }
}
