// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {StableSwapAggregator} from "./StableSwapAggregator.sol";
import {ICurveStableSwap} from "./interfaces/IStableSwap.sol";

/// @title StableSwapAggregatorFactory
/// @notice Factory for creating StableSwapAggregator hooks via CREATE2 and initializing Uniswap V4 pools
/// @dev Deploys deterministic hook addresses and initializes pools for all token pairs in the Curve pool
contract StableSwapAggregatorFactory {
    /// @notice The Uniswap V4 PoolManager contract
    IPoolManager public immutable POOL_MANAGER;

    error InsufficientTokens();

    event HookDeployed(address indexed hook, address indexed curvePool, PoolKey poolKey);

    constructor(IPoolManager _poolManager) {
        POOL_MANAGER = _poolManager;
    }

    /// @notice Creates a new StableSwapAggregator hook and initializes pools for all token pairs
    /// @param salt The CREATE2 salt (pre-mined to produce valid hook address)
    /// @param curvePool The Curve StableSwap pool to aggregate
    /// @param tokens Array of currencies in the pool (must have at least 2 tokens)
    /// @param fee The pool fee
    /// @param tickSpacing The pool tick spacing
    /// @param sqrtPriceX96 The initial sqrt price for each pool
    /// @return hook The deployed hook address
    function createPool(
        bytes32 salt,
        ICurveStableSwap curvePool,
        Currency[] calldata tokens,
        uint24 fee,
        int24 tickSpacing,
        uint160 sqrtPriceX96
    ) external returns (address hook) {
        if (tokens.length < 2) revert InsufficientTokens();

        hook = address(new StableSwapAggregator{salt: salt}(POOL_MANAGER, curvePool));

        // Initialize one pool per token pair
        for (uint256 i = 0; i < tokens.length; i++) {
            for (uint256 j = i + 1; j < tokens.length; j++) {
                (Currency currency0, Currency currency1) = Currency.unwrap(tokens[i]) < Currency.unwrap(tokens[j])
                    ? (tokens[i], tokens[j])
                    : (tokens[j], tokens[i]);

                PoolKey memory poolKey = PoolKey({
                    currency0: currency0, currency1: currency1, fee: fee, tickSpacing: tickSpacing, hooks: IHooks(hook)
                });

                POOL_MANAGER.initialize(poolKey, sqrtPriceX96);

                emit HookDeployed(hook, address(curvePool), poolKey);
            }
        }
    }

    /// @notice Computes the CREATE2 address for a hook without deploying
    /// @param salt The CREATE2 salt
    /// @param curvePool The Curve StableSwap pool
    /// @return computedAddress The predicted hook address
    function computeAddress(bytes32 salt, ICurveStableSwap curvePool) external view returns (address computedAddress) {
        bytes32 bytecodeHash =
            keccak256(abi.encodePacked(type(StableSwapAggregator).creationCode, abi.encode(POOL_MANAGER, curvePool)));
        computedAddress =
            address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), address(this), salt, bytecodeHash)))));
    }
}
