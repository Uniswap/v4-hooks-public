// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import {IStableStableHook} from "./interfaces/IStableStableHook.sol";
import {FeeConfiguration} from "./base/FeeConfiguration.sol";
import {BaseHook} from "../base/BaseHook.sol";
import {FeeConfig, HistoricalFeeData} from "./interfaces/IFeeConfiguration.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Multicall} from "@openzeppelin/contracts/utils/Multicall.sol";

/// @title StableStableHook
/// @notice Dynamic fee hook for stable/stable pools
contract StableStableHook is FeeConfiguration, BaseHook, Ownable, Multicall, IStableStableHook {
    using LPFeeLibrary for uint24;

    constructor(IPoolManager _manager, address _owner, address _configManager)
        FeeConfiguration(_configManager)
        Ownable(_owner)
        BaseHook(_manager)
    {}

    /// @inheritdoc IStableStableHook
    function initializePool(PoolKey calldata poolKey, uint160 sqrtPriceX96, FeeConfig calldata feeConfiguration)
        external
        onlyOwner
        returns (int24 tick)
    {
        if (!poolKey.fee.isDynamicFee()) {
            revert MustUseDynamicFee(poolKey.fee);
        }
        if (poolKey.hooks != IHooks(address(this))) {
            revert InvalidHookAddress(address(poolKey.hooks));
        }
        _validateFeeConfig(poolKey.toId(), feeConfiguration);
        tick = poolManager.initialize(poolKey, sqrtPriceX96);
        feeConfig[poolKey.toId()] = feeConfiguration;
        emit PoolInitialized(poolKey, sqrtPriceX96, feeConfiguration);
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

    function _beforeInitialize(address sender, PoolKey calldata, uint160) internal pure override returns (bytes4) {
        // Since hooks cannot call themselves, this function is only called when another address tries to initialize a pool with this contract as the hook
        // Therefore this function always reverts to ensure only this contract can initialize new pools
        revert InvalidInitializer(sender);
    }

    function _beforeSwap(address, PoolKey calldata, SwapParams calldata, bytes calldata)
        internal
        pure
        override
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        return (IHooks.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
    }
}
