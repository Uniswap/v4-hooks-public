// SPDX-License-Identifier: MIT
pragma solidity 0.8.29;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IReactor} from "@uniswapx/interfaces/IReactor.sol";
import {UniswapXAggregator} from "./UniswapXAggregator.sol";

/// @title UniswapXAggregatorFactory
/// @notice Factory for creating UniswapXAggregator hooks via CREATE2 and initializing a Uniswap V4 pool
/// @dev Deploys deterministic hook addresses (salt pre-mined to encode hook permission flags) and initializes
///      the V4 pool whose currencies are the order's input/output token pair.
contract UniswapXAggregatorFactory {
    /// @notice The Uniswap V4 PoolManager contract
    IPoolManager public immutable poolManager;

    /// @notice The UniswapX reactor the deployed hooks fill orders against
    IReactor public immutable reactor;

    /// @notice The canonical wrapped-native token
    address public immutable weth;

    event HookDeployed(address indexed hook, address indexed reactor, PoolKey poolKey);

    constructor(IPoolManager _poolManager, IReactor _reactor, address _weth) {
        poolManager = _poolManager;
        reactor = _reactor;
        weth = _weth;
    }

    /// @notice Creates a new UniswapXAggregator hook and initializes a V4 pool for the given currency pair
    /// @param salt The CREATE2 salt (pre-mined to produce a valid hook address)
    /// @param currency0 The lower-sorted pool currency
    /// @param currency1 The higher-sorted pool currency
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
        hook = address(new UniswapXAggregator{salt: salt}(poolManager, reactor, weth));

        PoolKey memory poolKey = PoolKey({
            currency0: currency0, currency1: currency1, fee: fee, tickSpacing: tickSpacing, hooks: IHooks(hook)
        });

        poolManager.initialize(poolKey, sqrtPriceX96);

        emit HookDeployed(hook, address(reactor), poolKey);
    }

    /// @notice Computes the CREATE2 address for a hook without deploying
    /// @param salt The CREATE2 salt
    /// @return computedAddress The predicted hook address
    function computeAddress(bytes32 salt) external view returns (address computedAddress) {
        bytes32 bytecodeHash =
            keccak256(abi.encodePacked(type(UniswapXAggregator).creationCode, abi.encode(poolManager, reactor, weth)));
        computedAddress =
            address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), address(this), salt, bytecodeHash)))));
    }
}
