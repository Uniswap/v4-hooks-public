// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {FluidDexT1Aggregator} from "./FluidDexT1Aggregator.sol";
import {IFluidDexT1} from "./interfaces/IFluidDexT1.sol";
import {IFluidDexReservesResolver} from "./interfaces/IFluidDexReservesResolver.sol";

/// @title FluidDexT1AggregatorFactory
/// @notice Factory for creating FluidDexT1Aggregator hooks via CREATE2 and initializing Uniswap V4 pools
/// @dev Deploys deterministic hook addresses that meet Uniswap V4's hook address requirements
contract FluidDexT1AggregatorFactory {
    /// @notice The Uniswap V4 PoolManager contract
    IPoolManager public immutable POOL_MANAGER;
    /// @notice The Fluid DEX reserves resolver for pool state queries
    IFluidDexReservesResolver public immutable FLUID_DEX_RESERVES_RESOLVER;
    /// @notice The Fluid Liquidity Layer contract address
    address public immutable FLUID_LIQUIDITY;

    event HookDeployed(address indexed hook, address indexed fluidPool, PoolKey poolKey);

    error HookAddressMismatch(address expected, address actual);

    constructor(
        IPoolManager _poolManager,
        IFluidDexReservesResolver _fluidDexReservesResolver,
        address _fluidLiquidity
    ) {
        POOL_MANAGER = _poolManager;
        FLUID_DEX_RESERVES_RESOLVER = _fluidDexReservesResolver;
        FLUID_LIQUIDITY = _fluidLiquidity;
    }

    /// @notice Creates a new FluidDexT1Aggregator hook and initializes the pool
    /// @param salt The CREATE2 salt (pre-mined to produce valid hook address)
    /// @param fluidPool The Fluid DEX T1 pool to aggregate
    /// @param currency0 The first currency of the pool (must be < currency1)
    /// @param currency1 The second currency of the pool
    /// @param fee The pool fee
    /// @param tickSpacing The pool tick spacing
    /// @param sqrtPriceX96 The initial sqrt price for the pool
    /// @return hook The deployed hook address
    function createPool(
        bytes32 salt,
        IFluidDexT1 fluidPool,
        Currency currency0,
        Currency currency1,
        uint24 fee,
        int24 tickSpacing,
        uint160 sqrtPriceX96
    ) external returns (address hook) {
        hook = address(
            new FluidDexT1Aggregator{salt: salt}(POOL_MANAGER, fluidPool, FLUID_DEX_RESERVES_RESOLVER, FLUID_LIQUIDITY)
        );

        PoolKey memory poolKey = PoolKey({
            currency0: currency0, currency1: currency1, fee: fee, tickSpacing: tickSpacing, hooks: IHooks(hook)
        });

        POOL_MANAGER.initialize(poolKey, sqrtPriceX96);

        emit HookDeployed(hook, address(fluidPool), poolKey);
    }

    /// @notice Computes the CREATE2 address for a hook without deploying
    /// @param salt The CREATE2 salt
    /// @param fluidPool The Fluid DEX T1 pool
    /// @return The predicted hook address
    function computeAddress(bytes32 salt, IFluidDexT1 fluidPool) external view returns (address computedAddress) {
        bytes32 bytecodeHash = keccak256(
            abi.encodePacked(
                type(FluidDexT1Aggregator).creationCode,
                abi.encode(POOL_MANAGER, fluidPool, FLUID_DEX_RESERVES_RESOLVER, FLUID_LIQUIDITY)
            )
        );
        computedAddress = address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), address(this), salt, bytecodeHash)))));
    }
}
