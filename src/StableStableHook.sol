// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import {BaseHook} from "./base/BaseHook.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/// @title StableStableHook
/// @notice Dynamic fee hook for stable/stable pools
contract StableStableHook is BaseHook, Ownable {
    using LPFeeLibrary for uint24;

    /// @notice Error thrown when the pool trying to be initialized is not using a dynamic fee
    /// @param fee The fee that was used to try to initialize the pool
    error MustUseDynamicFee(uint24 fee);
    /// @notice Error thrown when the caller of `initializePool` is not address(this)
    /// @param caller The invalid address attempting to initialize the pool
    /// @param expected address(this)
    error InvalidInitializer(address caller, address expected);

    constructor(IPoolManager _manager, address _owner) BaseHook(_manager) Ownable(_owner) {}

    /// @notice Initialize a Uniswap v4 pool
    /// @param poolKey The PoolKey of the pool to initialize
    /// @param sqrtPriceX96 The initial starting price of the pool, expressed as a sqrtPriceX96
    /// @param fee The LP fee of the pool
    /// @return tick The current tick of the pool
    function initializePool(PoolKey calldata poolKey, uint160 sqrtPriceX96, uint24 fee)
        external
        onlyOwner
        returns (int24 tick)
    {
        if (!fee.isDynamicFee()) {
            revert MustUseDynamicFee(fee);
        }
        tick = poolManager.initialize(poolKey, sqrtPriceX96);
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
    function _beforeInitialize(address sender, PoolKey calldata, uint160) internal view override returns (bytes4) {
        // This check is only hit when another address tries to initialize the pool, since hooks cannot call themselves.
        // Therefore this will always revert, ensuring only this contract can initialize pools
        if (sender != address(this)) revert InvalidInitializer(sender, address(this));

        return IHooks.beforeInitialize.selector;
    }

    /// @inheritdoc BaseHook
    function _beforeSwap(address, PoolKey calldata, SwapParams calldata, bytes calldata)
        internal
        pure
        override
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        return (IHooks.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
    }
}
