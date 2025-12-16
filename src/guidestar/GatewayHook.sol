// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";

import {BaseGuidestarHook} from "./BaseGuidestarHook.sol";
import {Ownable} from "solady/auth/Ownable.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {ModifyLiquidityParams, SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {BaseHook} from "../base/BaseHook.sol";

/// @title GatewayHook
contract GatewayHook is Ownable, BaseHook {
    using CurrencyLibrary for Currency;
    using PoolIdLibrary for PoolKey;

    /// @notice Thrown when the PoolKey's fee is not set to DYNAMIC_FEE_FLAG
    error MustUseDynamicFee();

    /// @notice The implementation address to forward calls to
    IHooks public implementation;

    constructor(IPoolManager _poolManager, address _initialOwner) BaseHook(_poolManager) {
        _initializeOwner(_initialOwner);
    }

    /// @notice Sets the implementation to forward calls to
    /// @param _newImplementation The new implementation address
    function setImplementation(IHooks _newImplementation) external onlyOwner {
        implementation = _newImplementation;
    }

    /// @inheritdoc BaseHook
    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: true,
            afterInitialize: false,
            beforeAddLiquidity: false,
            beforeRemoveLiquidity: false,
            afterAddLiquidity: false,
            afterRemoveLiquidity: false,
            beforeSwap: true,
            afterSwap: false,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: false,
            afterSwapReturnDelta: false,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    /// @inheritdoc BaseHook
    function _beforeInitialize(address sender, PoolKey calldata key, uint160 sqrtAmmPrice)
        internal
        override
        returns (bytes4)
    {
        // Pool must be a dynamic fee pool
        if (!LPFeeLibrary.isDynamicFee(key.fee)) {
            revert MustUseDynamicFee();
        }

        return implementation.beforeInitialize(sender, key, sqrtAmmPrice);
    }

    /// @inheritdoc BaseHook
    function _beforeSwap(address sender, PoolKey calldata key, SwapParams calldata params, bytes calldata hookData)
        internal
        override
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        return implementation.beforeSwap(sender, key, params, hookData);
    }
}
