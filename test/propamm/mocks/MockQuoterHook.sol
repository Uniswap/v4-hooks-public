// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {BasePropAMMHook} from "../../../src/propamm/base/BasePropAMMHook.sol";
import {IPropAMMIndex, QuoterType} from "../../../src/propamm/interfaces/IPropAMMIndex.sol";
import {IAttestationRegistry} from "../../../src/propamm/interfaces/IAttestationRegistry.sol";

/// @title MockQuoterHook
/// @notice Minimal concrete implementation of BasePropAMMHook for testing the base class.
contract MockQuoterHook is BasePropAMMHook {
    uint256 public priceReturn;
    uint256 public attestedPriceReturn;
    bool public live;

    // Track calls for assertions
    bool public lastCallAttested;
    address public lastCallAttester;

    constructor(
        IPoolManager _poolManager,
        IPropAMMIndex _index,
        IAttestationRegistry _attestationRegistry,
        uint32 maxGas_
    ) BasePropAMMHook(_poolManager, _index, _attestationRegistry, maxGas_) {
        live = true;
    }

    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: false,
            afterInitialize: true,
            beforeAddLiquidity: false,
            beforeRemoveLiquidity: false,
            afterAddLiquidity: false,
            afterRemoveLiquidity: false,
            beforeSwap: true,
            afterSwap: false,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: true,
            afterSwapReturnDelta: false,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    function isLive() external view override returns (bool) {
        return live;
    }

    function setPrice(uint256 price_, uint256 attestedPrice_) external {
        priceReturn = price_;
        attestedPriceReturn = attestedPrice_;
    }

    function setLive(bool _live) external {
        live = _live;
    }

    function _price(PoolKey calldata, bool, int256, bool isAttested, address)
        internal
        view
        override
        returns (uint256)
    {
        return isAttested ? attestedPriceReturn : priceReturn;
    }

    function _beforeSwap(address, PoolKey calldata, SwapParams calldata, bytes calldata)
        internal
        pure
        override
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        return (IHooks.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
    }

    // Expose internal helpers for testing
    function registerInIndex(PoolKey calldata poolKey, QuoterType quoterType, bytes memory metadata) external {
        _registerInIndex(poolKey, quoterType, metadata);
    }

    function setLiveInIndex(PoolKey calldata poolKey, bool _live) external {
        _setLive(poolKey, _live);
    }

    function deregisterFromIndex(PoolKey calldata poolKey) external {
        _deregisterFromIndex(poolKey);
    }
}
