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

/**
 * @title GatewayHook hook for Uniswap v4, unichain version (guidestar.fi)
 * @author Guidestar Team
 */
contract GatewayHook is Ownable, IHooks {
    using CurrencyLibrary for Currency;
    using PoolIdLibrary for PoolKey;

    // /// @notice PoolKey.fee must be set to DYNAMIC_FEE_FLAG
    error MustUseDynamicFee();
    error NotPoolManager();
    error HookNotImplemented();

    constructor(IPoolManager _poolManager, address _initialOwner) {
        _initializeOwner(_initialOwner);
        poolManager = _poolManager;
    }

    IHooks public implementation;
    IPoolManager public immutable poolManager;

    modifier onlyByPoolManager() {
        if (msg.sender != address(poolManager)) {
            revert NotPoolManager();
        }
        _;
    }

    /// @inheritdoc IHooks
    function beforeSwap(
        address sender,
        PoolKey calldata key,
        SwapParams calldata params,
        bytes calldata hookData
    )
        external
        virtual
        onlyByPoolManager
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        return implementation.beforeSwap(sender, key, params, hookData);
    }

    /// @inheritdoc IHooks
    function beforeAddLiquidity(
        address sender,
        PoolKey calldata poolKey,
        ModifyLiquidityParams calldata params,
        bytes calldata hookData
    )
        external
        virtual
        onlyByPoolManager
        returns (bytes4)
    {
        return implementation.beforeAddLiquidity(sender, poolKey, params, hookData);
    }

    // currently we don`t take the permisition
    /// @inheritdoc IHooks
    function beforeRemoveLiquidity(
        address sender,
        PoolKey calldata poolKey,
        ModifyLiquidityParams calldata params,
        bytes calldata hookData
    )
        external
        virtual
        onlyByPoolManager
        returns (bytes4)
    {
        // uint256 priorityFee = tx.gasprice - block.basefee;

        // if (priorityFee == 0) {
        //     return IHooks.beforeRemoveLiquidity.selector;
        // }

        // return implementation.beforeRemoveLiquidity(sender, poolKey, params, hookData);
        revert HookNotImplemented();
    }

    /// @inheritdoc IHooks
    function afterRemoveLiquidity(
        address sender,
        PoolKey calldata poolKey,
        ModifyLiquidityParams calldata params,
        BalanceDelta delta,
        BalanceDelta,
        bytes calldata hookData
    )
        external
        virtual
        onlyByPoolManager
        returns (bytes4, BalanceDelta)
    {
        uint256 priorityFee = tx.gasprice - block.basefee;

        if (priorityFee == 0) {
            return (IHooks.afterRemoveLiquidity.selector, BalanceDeltaLibrary.ZERO_DELTA);
        }

        return implementation.afterRemoveLiquidity(
            sender, poolKey, params, delta, BalanceDeltaLibrary.ZERO_DELTA, hookData
        );
    }

    function getHookPermissions() public pure virtual returns (Hooks.Permissions memory) {
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

    /// @inheritdoc IHooks
    function beforeInitialize(
        address sender,
        PoolKey calldata key,
        uint160 sqrtAmmPrice
    )
        external
        virtual
        onlyByPoolManager
        returns (bytes4)
    {
        if (!LPFeeLibrary.isDynamicFee(key.fee)) {
            revert MustUseDynamicFee();
        }

        return implementation.beforeInitialize(sender, key, sqrtAmmPrice);
    }

    function setImplementation(IHooks _newImplementation) external onlyOwner {
        implementation = _newImplementation;
    }

    function afterAddLiquidity(
        address sender,
        PoolKey calldata poolKey,
        ModifyLiquidityParams calldata params,
        BalanceDelta delta,
        BalanceDelta delta2,
        bytes calldata hookData
    )
        external
        virtual
        onlyByPoolManager
        returns (bytes4, BalanceDelta)
    {
        revert HookNotImplemented();
    }

    /// @inheritdoc IHooks
    function afterInitialize(address, PoolKey calldata, uint160, int24) external virtual returns (bytes4) {
        revert HookNotImplemented();
    }

    /// @inheritdoc IHooks
    function afterSwap(
        address,
        PoolKey calldata,
        SwapParams calldata,
        BalanceDelta,
        bytes calldata
    )
        external
        virtual
        returns (bytes4, int128)
    {
        revert HookNotImplemented();
    }

    /// @inheritdoc IHooks
    function beforeDonate(
        address,
        PoolKey calldata,
        uint256,
        uint256,
        bytes calldata
    )
        external
        virtual
        returns (bytes4)
    {
        revert HookNotImplemented();
    }

    /// @inheritdoc IHooks
    function afterDonate(
        address,
        PoolKey calldata,
        uint256,
        uint256,
        bytes calldata
    )
        external
        virtual
        returns (bytes4)
    {
        revert HookNotImplemented();
    }
}
