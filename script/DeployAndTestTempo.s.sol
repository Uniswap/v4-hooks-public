// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolManager} from "@uniswap/v4-core/src/PoolManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {TempoExchangeAggregator} from
    "../src/aggregator-hooks/implementations/TempoExchange/TempoExchangeAggregator.sol";
import {TempoExchangeAggregatorFactory} from
    "../src/aggregator-hooks/implementations/TempoExchange/TempoExchangeAggregatorFactory.sol";
import {ITempoExchange} from "../src/aggregator-hooks/implementations/TempoExchange/interfaces/ITempoExchange.sol";
import {HookMiner} from "@uniswap/v4-periphery/src/utils/HookMiner.sol";

/// @notice Complete deployment and testing script for Tempo testnet
/// @dev Deploys PoolManager, Factory, and tests basic functionality
contract DeployAndTestTempo is Script {
    address constant CREATE2_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;

    // Addresses to be set from environment or deployed
    IPoolManager public poolManager;
    ITempoExchange public tempoExchange;
    TempoExchangeAggregatorFactory public factory;

    // Test tokens (should exist on Tempo)
    address public token0;
    address public token1;

    function setUp() public {
        // Read addresses from environment
        address poolManagerAddr = vm.envOr("TEMPO_POOL_MANAGER", address(0));
        address tempoExchangeAddr = vm.envOr("TEMPO_EXCHANGE", address(0));

        require(tempoExchangeAddr != address(0), "TEMPO_EXCHANGE not set");

        tempoExchange = ITempoExchange(tempoExchangeAddr);

        // Read test token addresses
        token0 = vm.envOr("TEMPO_TOKEN0", address(0));
        token1 = vm.envOr("TEMPO_TOKEN1", address(0));
    }

    function run() public {
        uint256 deployerPrivateKey = vm.envUint("TEMPO_TESTNET_PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);

        console.log("Deployer address:", deployer);
        console.log("Deployer balance:", deployer.balance);

        vm.startBroadcast(deployerPrivateKey);

        // Step 1: Deploy or use existing PoolManager
        address poolManagerAddr = vm.envOr("TEMPO_POOL_MANAGER", address(0));
        if (poolManagerAddr == address(0)) {
            console.log("Deploying new PoolManager...");
            poolManager = new PoolManager(address(0));
            console.log("PoolManager deployed at:", address(poolManager));
        } else {
            poolManager = IPoolManager(poolManagerAddr);
            console.log("Using existing PoolManager at:", poolManagerAddr);
        }

        // Step 2: Deploy Factory
        console.log("\nDeploying TempoExchangeAggregatorFactory...");
        factory = new TempoExchangeAggregatorFactory(poolManager, tempoExchange);
        console.log("Factory deployed at:", address(factory));

        // Step 3: Mine a valid hook address
        console.log("\nMining valid hook address...");
        uint160 flags =
            uint160(Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG | Hooks.BEFORE_INITIALIZE_FLAG);

        bytes memory constructorArgs = abi.encode(address(poolManager), address(tempoExchange));

        (address hookAddress, bytes32 salt) =
            HookMiner.find(address(factory), flags, type(TempoExchangeAggregator).creationCode, constructorArgs);

        console.log("Found valid hook address:", hookAddress);
        console.log("Salt:", vm.toString(salt));

        // Step 4: Test hook address computation
        address computedAddress = factory.computeAddress(salt);
        console.log("Factory computed address:", computedAddress);
        require(computedAddress == hookAddress, "Address mismatch!");

        vm.stopBroadcast();

        // Step 5: Print deployment summary
        console.log("\n=== DEPLOYMENT SUMMARY ===");
        console.log("Network: Tempo Testnet");
        console.log("Chain ID: 42431");
        console.log("Deployer:", deployer);
        console.log("PoolManager:", address(poolManager));
        console.log("TempoExchange:", address(tempoExchange));
        console.log("Factory:", address(factory));
        console.log("\nTo create a pool with this hook, use:");
        console.log("  Hook Address:", hookAddress);
        console.log("  Salt:", vm.toString(salt));

        // If tokens are provided, we could initialize a pool
        if (token0 != address(0) && token1 != address(0)) {
            console.log("\nTest tokens configured:");
            console.log("  Token0:", token0);
            console.log("  Token1:", token1);
            console.log("\nRun createTestPool() to initialize a pool with these tokens");
        }
    }

    /// @notice Separate function to create a test pool after deployment
    /// @dev Call this after main deployment if you want to initialize a pool
    function createTestPool() public {
        require(token0 != address(0) && token1 != address(0), "Tokens not configured");
        require(address(factory) != address(0), "Factory not deployed");

        uint256 deployerPrivateKey = vm.envUint("TEMPO_TESTNET_PRIVATE_KEY");

        // Mine hook address again
        uint160 flags =
            uint160(Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG | Hooks.BEFORE_INITIALIZE_FLAG);

        bytes memory constructorArgs = abi.encode(address(poolManager), address(tempoExchange));

        (, bytes32 salt) =
            HookMiner.find(address(factory), flags, type(TempoExchangeAggregator).creationCode, constructorArgs);

        vm.startBroadcast(deployerPrivateKey);

        // Create pool with 0.05% fee
        uint24 fee = 500;
        int24 tickSpacing = 10;
        uint160 sqrtPriceX96 = 79228162514264337593543950336; // 1:1 price

        // Ensure token0 < token1
        if (token0 > token1) {
            (token0, token1) = (token1, token0);
        }

        address hook = factory.createPool(
            salt, Currency.wrap(token0), Currency.wrap(token1), fee, tickSpacing, sqrtPriceX96
        );

        console.log("\n=== POOL CREATED ===");
        console.log("Hook:", hook);
        console.log("Token0:", token0);
        console.log("Token1:", token1);
        console.log("Fee:", fee);

        vm.stopBroadcast();
    }
}
