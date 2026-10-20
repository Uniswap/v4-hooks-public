// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {StableFeeConfig} from "../../../src/stable/interfaces/IStableFeeConfiguration.sol";

struct DeployParameters {
    IPoolManager poolManager;
    // deployed StablePairHook implementation (address(0) until deployImplementation() has run)
    address stablePairHookImplementation;
    bytes32 stablePairHookProxySalt; // cached CREATE2 salt for the ERC1967 proxy (0 = mine at runtime)
    // roles, baked into the proxy constructor args (and thus the mined hook address); all three
    // must be set before deploying a proxy
    address owner;
    address poolInitializer;
    address configManager;
}

/// @notice Per-chain parameters for InitStablePairHook: the pool to initialize
struct PoolParameters {
    address currency0; // must sort below currency1
    address currency1;
    int24 tickSpacing;
    uint160 sqrtPriceX96; // initial pool price
    StableFeeConfig feeConfig;
}

/// @title Parameters
/// @notice Per-chain deployment parameters for the StablePairHook deploy scripts
contract Parameters {
    address public constant CREATE2_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;

    uint256 public constant ETHEREUM_CHAIN_ID = 1;
    uint256 public constant XLAYER_CHAIN_ID = 196;
    uint256 public constant ROBINHOOD_CHAIN_ID = 4663;
    uint256 public constant ARBITRUM_CHAIN_ID = 42161;
    uint256 public constant SEPOLIA_CHAIN_ID = 11155111;

    string public constant POOL_USDC_USDT = "USDC/USDT";
    string public constant POOL_USDC_USDG = "USDC/USDG";

    /// @notice Thrown when parameters are not set for a given chainId
    error ParametersNotSetForChainId(uint256 chainId);
    /// @notice Thrown when pool parameters are not set for a given chainId and pool name
    error PoolParametersNotSetForChainId(uint256 chainId, string poolName);

    mapping(uint256 chainId => DeployParameters) public parameters;
    mapping(uint256 chainId => mapping(string poolName => PoolParameters)) internal poolParameters;

    constructor() {
        // PoolManager addresses: https://docs.uniswap.org/contracts/v4/deployments
        parameters[ETHEREUM_CHAIN_ID] = DeployParameters({
            poolManager: IPoolManager(0x000000000004444c5dc75cB358380D2e3dE08A90),
            stablePairHookImplementation: 0x5f216d21b1C81346938EDDc1Df7e0111A0F64000,
            // mined for 0x0000113dCf4ADd69999Fad8F20F2b63F979bfcC0 (prefix 0x000011, flags 0x3CC0)
            stablePairHookProxySalt: 0x000000000000000000000000000000000000000023fd42c02e1b74f1f9ac0080,
            // Uniswap Governance Timelock (admin: GovernorBravo 0x408ED6354d4973f66138C91495F2f2FCbd8724C3)
            owner: 0x1a9C8182C09F50C8318d769245beA52c32BE35BC,
            poolInitializer: 0xFc43582532E90Fa8726FE9cdb5FAd48f4e487d27,
            configManager: 0x1a9C8182C09F50C8318d769245beA52c32BE35BC
        });
        parameters[XLAYER_CHAIN_ID] = DeployParameters({
            poolManager: IPoolManager(0x360E68faCcca8cA495c1B759Fd9EEe466db9FB32),
            stablePairHookImplementation: 0x424e2f8D89eeaB51AF10669D149Fbd4BEB090000,
            stablePairHookProxySalt: 0x0000000000000000000000000000000000000000000000000000000000005f95,
            owner: 0x2BAD8182C09F50c8318d769245beA52C32Be46CD,
            poolInitializer: 0x3Dd872203E8FC405622ddc02A69de3BD9D52C4F8,
            configManager: 0x2BAD8182C09F50c8318d769245beA52C32Be46CD
        });
        parameters[ROBINHOOD_CHAIN_ID] = DeployParameters({
            poolManager: IPoolManager(0x8366a39CC670B4001A1121B8F6A443A643e40951),
            stablePairHookImplementation: address(0),
            stablePairHookProxySalt: bytes32(0),
            owner: address(0),
            poolInitializer: address(0),
            configManager: address(0)
        });
        parameters[ARBITRUM_CHAIN_ID] = DeployParameters({
            poolManager: IPoolManager(0x360E68faCcca8cA495c1B759Fd9EEe466db9FB32),
            stablePairHookImplementation: 0x424e2f8D89eeaB51AF10669D149Fbd4BEB090000,
            // mined for 0x630e9CaC0ffF557Bd3A01DAa111ed253c771Bcc0
            stablePairHookProxySalt: 0x0000000000000000000000000000000000000000000000000000000000005f95,
            owner: 0x2BAD8182C09F50c8318d769245beA52C32Be46CD,
            poolInitializer: 0x3Dd872203E8FC405622ddc02A69de3BD9D52C4F8,
            configManager: 0x2BAD8182C09F50c8318d769245beA52C32Be46CD
        });
        parameters[SEPOLIA_CHAIN_ID] = DeployParameters({
            poolManager: IPoolManager(0xE03A1074c86CFeDd5C142C4F04F1a1536e203543),
            stablePairHookImplementation: 0xDBc81fFadaB5ee9c9fB1c2D43Bef547EB9c64000,
            // deployed 0x2F45A94782d3e187BaB5F72448bb85d6d1d67CC0 at 7abd34b; this salt no longer
            // reproduces that address and a rerun would revert with FlagsMismatch
            stablePairHookProxySalt: bytes32(uint256(0x30ad)),
            owner: 0xE49ACc3B16c097ec88Dc9352CE4Cd57aB7e35B95,
            poolInitializer: 0xE49ACc3B16c097ec88Dc9352CE4Cd57aB7e35B95,
            configManager: 0xE49ACc3B16c097ec88Dc9352CE4Cd57aB7e35B95
        });

        poolParameters[ETHEREUM_CHAIN_ID][POOL_USDC_USDT] = PoolParameters({
            currency0: 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48, // USDC
            currency1: 0xdAC17F958D2ee523a2206206994597C13D831ec7, // USDT
            tickSpacing: 1,
            sqrtPriceX96: 79228162514264337593543950336, // 1:1
            feeConfig: StableFeeConfig({
                k: 11_744_051, // 0.7 in Q24 (0.7 * 2**24)
                optimalFeeE6: 7, // = .07bps = .0007%
                targetMultiplier: 100,
                referenceSqrtPriceX96: 79228162514264337593543950336 // 1:1
            })
        });
        poolParameters[ETHEREUM_CHAIN_ID][POOL_USDC_USDG] = PoolParameters({
            currency0: 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48, // USDC
            currency1: 0xe343167631d89B6Ffc58B88d6b7fB0228795491D, // USDG
            tickSpacing: 1,
            sqrtPriceX96: 79228162514264337593543950336, // 1:1
            feeConfig: StableFeeConfig({
                k: 11_744_051, // 0.7 in Q24 (0.7 * 2**24)
                optimalFeeE6: 50, // = .5bps = .005%
                targetMultiplier: 100,
                referenceSqrtPriceX96: 79228162514264337593543950336 // 1:1
            })
        });
        poolParameters[ARBITRUM_CHAIN_ID][POOL_USDC_USDG] = PoolParameters({
            currency0: 0x004B506865409877C9fA29bfb1ebA929984B9bbC, // USDG
            currency1: 0xaf88d065e77c8cC2239327C5EDb3A432268e5831, // USDC
            tickSpacing: 1,
            sqrtPriceX96: 79228162514264337593543950336, // 1:1
            feeConfig: StableFeeConfig({
                k: 16_653_011, // .9925968 in Q24 (0.9925968 * 2**24)
                optimalFeeE6: 50, // = .5bps = .005%
                targetMultiplier: 100,
                referenceSqrtPriceX96: 79228162514264337593543950336 // 1:1
            })
        });
        poolParameters[SEPOLIA_CHAIN_ID][POOL_USDC_USDT] = PoolParameters({
            currency0: 0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238, // USDC (Circle)
            currency1: 0xaA8E23Fb1079EA71e0a56F48a2aA51851D8433D0, // USDT (Aave testnet)
            tickSpacing: 1,
            sqrtPriceX96: 79228162514264337593543950336, // 1:1
            feeConfig: StableFeeConfig({
                k: 167772, // .01
                optimalFeeE6: 7, // = .07bps = .0007%
                targetMultiplier: 100,
                referenceSqrtPriceX96: 79228162514264337593543950336 // 1:1
            })
        });
    }

    function getParameters(uint256 chainId) public view returns (DeployParameters memory params) {
        params = parameters[chainId];
        if (address(params.poolManager) == address(0)) {
            revert ParametersNotSetForChainId(chainId);
        }
    }

    /// @notice Pool parameters for a named pool on a chain
    /// @param chainId The chain the pool lives on
    /// @param poolName One of the POOL_* constants
    function getPoolParameters(uint256 chainId, string memory poolName)
        public
        view
        returns (PoolParameters memory params)
    {
        params = poolParameters[chainId][poolName];
        if (params.currency0 == address(0)) {
            revert PoolParametersNotSetForChainId(chainId, poolName);
        }
    }
}
