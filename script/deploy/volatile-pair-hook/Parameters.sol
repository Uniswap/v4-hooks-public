// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {VolatileFeeConfig} from "../../../src/volatile/interfaces/IVolatileFeeConfiguration.sol";

struct DeployParameters {
    IPoolManager poolManager;
    bytes32 volatilePairHookProxySalt;
    bytes32 volatilePairHookImplementationSalt;
    address owner;
    address poolInitializer;
    address configManager;
    uint256 maxTempFeeBlockGap; // implementation constructor arg; measured in blocks, so it is set per chain
}

/// @notice Per-chain parameters for InitVolatilePairHook: the pool to initialize
struct PoolParameters {
    address currency0; // must sort below currency1; address(0) is native ETH
    address currency1;
    int24 tickSpacing;
    uint160 sqrtPriceX96; // initial pool price; 0 means the pool is not set up yet
    VolatileFeeConfig feeConfig;
}

/// @title Parameters
/// @notice Per-chain deployment parameters for the VolatilePairHook deploy script
contract Parameters {
    address public constant CREATE2_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;

    uint256 public constant ETHEREUM_CHAIN_ID = 1;
    uint256 public constant SEPOLIA_CHAIN_ID = 11155111;

    string public constant POOL_ETH_USDC = "ETH/USDC";

    /// @notice Thrown when parameters are not set for a given chainId
    error ParametersNotSetForChainId(uint256 chainId);
    /// @notice Thrown when pool parameters are not set for a given chainId and pool name
    error PoolParametersNotSetForChainId(uint256 chainId, string poolName);
    /// @notice Thrown when a pool's fee config is still the unfilled placeholder
    error PoolFeeConfigNotSet(uint256 chainId, string poolName);

    mapping(uint256 chainId => DeployParameters) public parameters;
    mapping(uint256 chainId => mapping(string poolName => PoolParameters)) internal poolParameters;

    constructor() {
        // PoolManager addresses: https://docs.uniswap.org/contracts/v4/deployments
        parameters[ETHEREUM_CHAIN_ID] = DeployParameters({
            poolManager: IPoolManager(0x000000000004444c5dc75cB358380D2e3dE08A90),
            // mined for 0x000022Ec4eBD6b12294396E852E4C3876b253Cc0 (prefix 0x000022, flags 0x3CC0)
            volatilePairHookProxySalt: 0x0000000000000000000000000000000000000000c7441c3a21254802cd8406f8,
            volatilePairHookImplementationSalt: bytes32(uint256(0x43b9)),
            // Uniswap Governance Timelock (admin: GovernorBravo 0x408ED6354d4973f66138C91495F2f2FCbd8724C3)
            owner: 0x1a9C8182C09F50C8318d769245beA52c32BE35BC,
            poolInitializer: 0xFc43582532E90Fa8726FE9cdb5FAd48f4e487d27,
            configManager: 0x1a9C8182C09F50C8318d769245beA52c32BE35BC,
            // temp fee only on the block right after the previous block open (12s)
            maxTempFeeBlockGap: 1
        });
        parameters[SEPOLIA_CHAIN_ID] = DeployParameters({
            poolManager: IPoolManager(0xE03A1074c86CFeDd5C142C4F04F1a1536e203543),
            volatilePairHookProxySalt: bytes32(uint256(0x1938)),
            volatilePairHookImplementationSalt: bytes32(uint256(0x290d)),
            owner: 0xE49ACc3B16c097ec88Dc9352CE4Cd57aB7e35B95,
            poolInitializer: 0xE49ACc3B16c097ec88Dc9352CE4Cd57aB7e35B95,
            configManager: 0xE49ACc3B16c097ec88Dc9352CE4Cd57aB7e35B95,
            // 12s blocks, same as Ethereum
            maxTempFeeBlockGap: 1
        });

        poolParameters[ETHEREUM_CHAIN_ID][POOL_ETH_USDC] = PoolParameters({
            currency0: address(0), // native ETH
            currency1: 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48, // USDC
            tickSpacing: 4,
            sqrtPriceX96: 3_960_446_919_404_551_911_348_444,
            feeConfig: VolatileFeeConfig({
                restingSpreadE6: 800, // 8bp
                backrunCaptureFractionE6: 500_000, // 0.5
                midFadeRateE6: 4_000_000, // 4x the in-block move
                maxMidFadeE6: 200, // 2bp
                skewRateE6: 1_000_000, // 1x the block price impact: a 1bp move steps the skew 1bp
                maxSkewStepE6: 300, // 3bp
                maxSkewE6: 800, // 8bp, equal to the resting spread
                backrunThresholdE6: 500, // 5bp
                restoreFractionE6: 1_000_000, // full restore
                restoreThresholdE6: 500 // 5bp, same gate as backrun capture
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
    /// @dev Unset is detected by sqrtPriceX96 == 0, not currency0, since native ETH pools use currency0 = address(0)
    /// @param chainId The chain the pool lives on
    /// @param poolName One of the POOL_* constants
    function getPoolParameters(uint256 chainId, string memory poolName)
        public
        view
        returns (PoolParameters memory params)
    {
        params = poolParameters[chainId][poolName];
        if (params.sqrtPriceX96 == 0) revert PoolParametersNotSetForChainId(chainId, poolName);
        if (params.feeConfig.restingSpreadE6 == 0) revert PoolFeeConfigNotSet(chainId, poolName);
    }
}
