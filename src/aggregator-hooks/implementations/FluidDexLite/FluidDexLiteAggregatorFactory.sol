// SPDX-License-Identifier: MIT
pragma solidity 0.8.29;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IV4FeeAdapter} from "@protocol-fees/interfaces/IV4FeeAdapter.sol";
import {FluidDexLiteAggregator} from "./FluidDexLiteAggregator.sol";
import {IFluidDexLite} from "./interfaces/IFluidDexLite.sol";
import {IFluidDexLiteResolver} from "./interfaces/IFluidDexLiteResolver.sol";

/// @title FluidDexLiteAggregatorFactory
/// @notice Factory for creating FluidDexLiteAggregator hooks via CREATE2 and initializing Uniswap V4 pools
/// @dev Deploys deterministic hook addresses that meet Uniswap V4's hook address requirements
contract FluidDexLiteAggregatorFactory {
    /// @notice The Uniswap V4 PoolManager contract
    IPoolManager public immutable poolManager;
    /// @notice The Fluid DEX Lite contract
    IFluidDexLite public immutable fluidDexLite;
    /// @notice The Fluid DEX Lite resolver for pool state queries
    IFluidDexLiteResolver public immutable fluidDexLiteResolver;
    /// @notice The V4 protocol fee adapter for fee resolution
    IV4FeeAdapter public immutable protocolFeeAdapter;

    event HookDeployed(address indexed hook, bytes32 indexed dexSalt, PoolKey poolKey);

    constructor(
        IPoolManager _poolManager,
        IFluidDexLite _fluidDexLite,
        IFluidDexLiteResolver _fluidDexLiteResolver,
        IV4FeeAdapter _protocolFeeAdapter
    ) {
        poolManager = _poolManager;
        fluidDexLite = _fluidDexLite;
        fluidDexLiteResolver = _fluidDexLiteResolver;
        protocolFeeAdapter = _protocolFeeAdapter;
    }

    /// @notice Creates a new FluidDexLiteAggregator hook and initializes the pool
    /// @param salt The CREATE2 salt (pre-mined to produce valid hook address)
    /// @param dexSalt The salt for the Fluid DEX Lite pool's DexKey
    /// @param currency0 The first currency of the pool (must be < currency1)
    /// @param currency1 The second currency of the pool
    /// @param fee The pool fee
    /// @param tickSpacing The pool tick spacing
    /// @param sqrtPriceX96 The initial sqrt price for the pool
    /// @return hook The deployed hook address
    function createPool(
        bytes32 salt,
        bytes32 dexSalt,
        Currency currency0,
        Currency currency1,
        uint24 fee,
        int24 tickSpacing,
        uint160 sqrtPriceX96
    ) external returns (address hook) {
        hook = address(
            new FluidDexLiteAggregator{salt: salt}(
                poolManager, fluidDexLite, fluidDexLiteResolver, dexSalt, protocolFeeAdapter
            )
        );

        PoolKey memory poolKey = PoolKey({
            currency0: currency0, currency1: currency1, fee: fee, tickSpacing: tickSpacing, hooks: IHooks(hook)
        });

        poolManager.initialize(poolKey, sqrtPriceX96);

        emit HookDeployed(hook, dexSalt, poolKey);
    }

    /// @notice Computes the CREATE2 address for a hook without deploying
    /// @param salt The CREATE2 salt
    /// @param dexSalt The salt for the Fluid DEX Lite pool's DexKey
    /// @return computedAddress The predicted hook address
    function computeAddress(bytes32 salt, bytes32 dexSalt) external view returns (address computedAddress) {
        bytes32 bytecodeHash = keccak256(
            abi.encodePacked(
                type(FluidDexLiteAggregator).creationCode,
                abi.encode(poolManager, fluidDexLite, fluidDexLiteResolver, dexSalt, protocolFeeAdapter)
            )
        );
        computedAddress =
            address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), address(this), salt, bytecodeHash)))));
    }
}
