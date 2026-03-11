// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title MockCurveStableSwapFactoryNG
/// @notice Mock Curve StableSwap NG Factory with settable is_meta return values for unit tests.
contract MockCurveStableSwapFactoryNG {
    mapping(address => bool) public isMetaMap;

    function setIsMeta(address pool, bool value) external {
        isMetaMap[pool] = value;
    }

    function is_meta(address _pool) external view returns (bool) {
        return isMetaMap[_pool];
    }
}
