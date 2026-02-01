// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolManager} from "@uniswap/v4-core/src/PoolManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {TempoExchangeAggregator} from
    "../src/aggregator-hooks/implementations/TempoExchange/TempoExchangeAggregator.sol";
import {TempoExchangeAggregatorFactory} from
    "../src/aggregator-hooks/implementations/TempoExchange/TempoExchangeAggregatorFactory.sol";
import {ITempoExchange} from "../src/aggregator-hooks/implementations/TempoExchange/interfaces/ITempoExchange.sol";
import {HookMiner} from "@uniswap/v4-periphery/src/utils/HookMiner.sol";

/// @notice Deploys TempoExchangeAggregator contracts on Tempo testnet
contract DeployTempoAggregator is Script {
    address constant CREATE2_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;

    // Default addresses for Tempo testnet (can be overridden via env vars)
    // TODO: Update these with actual Tempo testnet addresses
    address public poolManagerAddress;
    address public tempoExchangeAddress;

    function setUp() public {
        // Read addresses from environment variables or use defaults
        poolManagerAddress = vm.envOr("TEMPO_POOL_MANAGER", address(0));
        tempoExchangeAddress = vm.envOr("TEMPO_EXCHANGE", address(0));

        require(poolManagerAddress != address(0), "TEMPO_POOL_MANAGER not set");
        require(tempoExchangeAddress != address(0), "TEMPO_EXCHANGE not set");
    }

    function run() public {
        uint256 deployerPrivateKey = vm.envUint("TEMPO_TESTNET_PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);

        console.log("Deployer:", deployer);
        console.log("Deployer balance:", deployer.balance);

        vm.startBroadcast(deployerPrivateKey);

        // Deploy the factory
        TempoExchangeAggregatorFactory factory = new TempoExchangeAggregatorFactory(
            IPoolManager(poolManagerAddress), ITempoExchange(tempoExchangeAddress)
        );

        console.log("TempoExchangeAggregatorFactory deployed at:", address(factory));
        console.log("PoolManager:", poolManagerAddress);
        console.log("TempoExchange:", tempoExchangeAddress);

        vm.stopBroadcast();

        // Compute a sample hook address
        bytes32 sampleSalt = bytes32(uint256(0));
        address computedHook = factory.computeAddress(sampleSalt);
        console.log("Sample hook address with salt 0:", computedHook);
    }
}
