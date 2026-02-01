// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {TempoExchangeAggregator} from "./TempoExchangeAggregator.sol";
import {ITempoExchange} from "./interfaces/ITempoExchange.sol";

/// @title TempoExchangeAggregatorFactory
/// @notice Factory for creating TempoExchangeAggregator hooks via CREATE2 and initializing Uniswap V4 pools
/// @dev Deploys deterministic hook addresses that meet Uniswap V4's hook address requirements
contract TempoExchangeAggregatorFactory {
    /// @notice The Uniswap V4 PoolManager contract
    IPoolManager public immutable POOL_MANAGER;
    /// @notice The Tempo stablecoin exchange address
    ITempoExchange public immutable TEMPO_EXCHANGE;

    event HookDeployed(address indexed hook, PoolKey poolKey);

    constructor(IPoolManager _poolManager, ITempoExchange _tempoExchange) {
        POOL_MANAGER = _poolManager;
        TEMPO_EXCHANGE = _tempoExchange;
    }

    /// @notice Creates a new TempoExchangeAggregator hook and initializes the pool
    /// @param salt The CREATE2 salt (pre-mined to produce valid hook address)
    /// @param currency0 The first currency of the pool (must be < currency1)
    /// @param currency1 The second currency of the pool
    /// @param fee The pool fee
    /// @param tickSpacing The pool tick spacing
    /// @param sqrtPriceX96 The initial sqrt price for the pool
    /// @return hook The deployed hook address
    function createPool(
        bytes32 salt,
        Currency currency0,
        Currency currency1,
        uint24 fee,
        int24 tickSpacing,
        uint160 sqrtPriceX96
    ) external returns (address hook) {
        hook = address(new TempoExchangeAggregator{salt: salt}(POOL_MANAGER, TEMPO_EXCHANGE));

        PoolKey memory poolKey = PoolKey({
            currency0: currency0, currency1: currency1, fee: fee, tickSpacing: tickSpacing, hooks: IHooks(hook)
        });

        POOL_MANAGER.initialize(poolKey, sqrtPriceX96);

        emit HookDeployed(hook, poolKey);
    }

    /// @notice Computes the CREATE2 address for a hook without deploying
    /// @param salt The CREATE2 salt
    /// @return computedAddress The predicted hook address
    function computeAddress(bytes32 salt) external view returns (address computedAddress) {
        bytes32 bytecodeHash = keccak256(
            abi.encodePacked(type(TempoExchangeAggregator).creationCode, abi.encode(POOL_MANAGER, TEMPO_EXCHANGE))
        );
        computedAddress =
            address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), address(this), salt, bytecodeHash)))));
    }
}
