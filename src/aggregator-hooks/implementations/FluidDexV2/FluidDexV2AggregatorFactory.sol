// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {FluidDexV2Aggregator} from "./FluidDexV2Aggregator.sol";
import {IFluidDexV2} from "./interfaces/IFluidDexV2.sol";
import {IFluidDexV2Resolver} from "./interfaces/IFluidDexV2Resolver.sol";

/// @title FluidDexV2AggregatorFactory
/// @notice Factory for creating FluidDexV2Aggregator hooks via CREATE2 and initializing Uniswap V4 pools
/// @dev Deploys deterministic hook addresses that meet Uniswap V4's hook address requirements
contract FluidDexV2AggregatorFactory {
    /// @notice The Uniswap V4 PoolManager contract
    IPoolManager public immutable POOL_MANAGER;
    /// @notice The Fluid DEX V2 contract
    IFluidDexV2 public immutable FLUID_DEX_V2;
    /// @notice The Fluid DEX V2 resolver for pool state queries
    IFluidDexV2Resolver public immutable FLUID_DEX_V2_RESOLVER;

    event HookDeployed(address indexed hook, address indexed controller, PoolKey poolKey);

    constructor(IPoolManager _poolManager, IFluidDexV2 _fluidDexV2, IFluidDexV2Resolver _fluidDexV2Resolver) {
        POOL_MANAGER = _poolManager;
        FLUID_DEX_V2 = _fluidDexV2;
        FLUID_DEX_V2_RESOLVER = _fluidDexV2Resolver;
    }

    /// @notice Creates a new FluidDexV2Aggregator hook and initializes the pool
    /// @param salt The CREATE2 salt (pre-mined to produce valid hook address)
    /// @param controller The controller address for the Fluid DEX V2 pool
    /// @param currency0 The first currency of the pool (must be < currency1)
    /// @param currency1 The second currency of the pool
    /// @param fee The pool fee
    /// @param tickSpacing The pool tick spacing
    /// @param sqrtPriceX96 The initial sqrt price for the pool
    /// @return hook The deployed hook address
    function createPool(
        bytes32 salt,
        address controller,
        uint256 dexType,
        Currency currency0,
        Currency currency1,
        uint24 fee,
        int24 tickSpacing,
        uint160 sqrtPriceX96
    ) external returns (address hook) {
        hook = address(
            new FluidDexV2Aggregator{salt: salt}(POOL_MANAGER, FLUID_DEX_V2, FLUID_DEX_V2_RESOLVER, controller, dexType)
        );

        PoolKey memory poolKey = PoolKey({
            currency0: currency0, currency1: currency1, fee: fee, tickSpacing: tickSpacing, hooks: IHooks(hook)
        });

        POOL_MANAGER.initialize(poolKey, sqrtPriceX96);

        emit HookDeployed(hook, controller, poolKey);
    }

    /// @notice Computes the CREATE2 address for a hook without deploying
    /// @param salt The CREATE2 salt
    /// @param controller The controller address for the Fluid DEX V2 pool
    /// @return computedAddress The predicted hook address
    function computeAddress(bytes32 salt, address controller, uint256 dexType)
        external
        view
        returns (address computedAddress)
    {
        bytes32 bytecodeHash = keccak256(
            abi.encodePacked(
                type(FluidDexV2Aggregator).creationCode,
                abi.encode(POOL_MANAGER, FLUID_DEX_V2, FLUID_DEX_V2_RESOLVER, controller, dexType)
            )
        );
        computedAddress =
            address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), address(this), salt, bytecodeHash)))));
    }
}
