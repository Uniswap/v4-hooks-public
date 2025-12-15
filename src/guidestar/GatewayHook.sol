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

/**
 * @title GatewayHook hook for Uniswap v4, unichain version (guidestar.fi)
 * @author Guidestar Team
 */
contract GatewayHook is Ownable, BaseHook {
    using CurrencyLibrary for Currency;
    using PoolIdLibrary for PoolKey;

    // /// @notice PoolKey.fee must be set to DYNAMIC_FEE_FLAG
    error MustUseDynamicFee();

    IHooks public implementation;

    constructor(IPoolManager _poolManager, address _initialOwner) BaseHook(_poolManager) {
        _initializeOwner(_initialOwner);
    }

    function setImplementation(IHooks _newImplementation) external onlyOwner {
        implementation = _newImplementation;
    }

    /// @inheritdoc BaseHook
    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: true,
            afterInitialize: false,
            beforeAddLiquidity: true,
            beforeRemoveLiquidity: false,
            afterAddLiquidity: false,
            afterRemoveLiquidity: true,
            beforeSwap: true,
            afterSwap: false,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: false,
            afterSwapReturnDelta: false,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: true
        });
    }

    /// @inheritdoc BaseHook
    function _beforeInitialize(address sender, PoolKey calldata key, uint160 sqrtAmmPrice)
        internal
        override
        returns (bytes4)
    {
        if (!LPFeeLibrary.isDynamicFee(key.fee)) {
            revert MustUseDynamicFee();
        }

        return implementation.beforeInitialize(sender, key, sqrtAmmPrice);
    }

    /// @inheritdoc BaseHook
    function _beforeAddLiquidity(
        address sender,
        PoolKey calldata poolKey,
        ModifyLiquidityParams calldata params,
        bytes calldata hookData
    ) internal override returns (bytes4) {
        return implementation.beforeAddLiquidity(sender, poolKey, params, hookData);
    }

    /// @inheritdoc BaseHook
    function _afterRemoveLiquidity(
        address sender,
        PoolKey calldata poolKey,
        ModifyLiquidityParams calldata params,
        BalanceDelta delta,
        BalanceDelta,
        bytes calldata hookData
    ) internal override returns (bytes4, BalanceDelta) {
        uint256 priorityFee = tx.gasprice - block.basefee;

        if (priorityFee == 0) {
            return (IHooks.afterRemoveLiquidity.selector, BalanceDeltaLibrary.ZERO_DELTA);
        }

        return
            implementation.afterRemoveLiquidity(
                sender, poolKey, params, delta, BalanceDeltaLibrary.ZERO_DELTA, hookData
            );
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
