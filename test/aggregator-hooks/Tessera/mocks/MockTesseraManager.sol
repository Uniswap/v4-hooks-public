// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ITesseraManager} from "../../../../src/aggregator-hooks/implementations/Tessera/interfaces/ITesseraManager.sol";

/// @title MockTesseraManager
/// @notice Mock pool registry for tests
contract MockTesseraManager is ITesseraManager {
    mapping(address => mapping(address => address)) private _pools;
    uint256 private _count;
    address private _baseRoutingAsset;
    bool private _isActive = true;

    function setBaseRoutingAsset(address asset) external {
        _baseRoutingAsset = asset;
    }

    function setIsActive(bool active) external {
        _isActive = active;
    }

    function registerPool(address tokenA, address tokenB, address pool) external {
        _pools[tokenA][tokenB] = pool;
        _pools[tokenB][tokenA] = pool;
        _count += 1;
    }

    function getTesseraPool(address tokenA, address tokenB)
        external
        view
        override
        returns (bool exists, address pool)
    {
        pool = _pools[tokenA][tokenB];
        exists = pool != address(0);
    }

    function baseRoutingAsset() external view override returns (address) {
        return _baseRoutingAsset;
    }

    function isActive() external view override returns (bool) {
        return _isActive;
    }

    function tesseraPoolsCount() external view override returns (uint256) {
        return _count;
    }
}
