// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolManager} from "@uniswap/v4-core/src/PoolManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {TempoExchangeAggregator} from
    "../src/aggregator-hooks/implementations/TempoExchange/TempoExchangeAggregator.sol";
import {TempoExchangeAggregatorFactory} from
    "../src/aggregator-hooks/implementations/TempoExchange/TempoExchangeAggregatorFactory.sol";
import {ITempoExchange} from "../src/aggregator-hooks/implementations/TempoExchange/interfaces/ITempoExchange.sol";
import {MockTempoExchange} from "../test/aggregator-hooks/TempoExchange/mocks/MockTempoExchange.sol";
import {HookMiner} from "@uniswap/v4-periphery/src/utils/HookMiner.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

/// @notice Complete deployment script for Tempo testnet with test environment
contract DeployTempoTestEnvironment is Script {
    using PoolIdLibrary for PoolKey;

    IPoolManager public poolManager;
    MockTempoExchange public tempoExchange;
    TempoExchangeAggregatorFactory public factory;
    TempoExchangeAggregator public hook;

    MockERC20 public token0;
    MockERC20 public token1;

    PoolKey public poolKey;
    PoolId public poolId;

    uint8 constant DECIMALS = 6; // Tempo uses 6 decimals
    uint256 constant INITIAL_LIQUIDITY = 1_000_000 * 10 ** DECIMALS;

    function run() public {
        uint256 deployerPrivateKey = vm.envUint("TEMPO_TESTNET_PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);

        console.log("=== DEPLOYING TEMPO TEST ENVIRONMENT ===");
        console.log("Deployer:", deployer);
        console.log("Balance:", deployer.balance);
        console.log("Chain ID:", block.chainid);

        vm.startBroadcast(deployerPrivateKey);

        // Step 1: Deploy PoolManager
        console.log("\n[1/6] Deploying PoolManager...");
        poolManager = new PoolManager(address(0));
        console.log("PoolManager deployed at:", address(poolManager));

        // Step 2: Deploy Mock TempoExchange (simulating the precompile)
        console.log("\n[2/6] Deploying Mock TempoExchange...");
        tempoExchange = new MockTempoExchange();
        console.log("MockTempoExchange deployed at:", address(tempoExchange));

        // Step 3: Deploy test tokens
        console.log("\n[3/6] Deploying test tokens...");
        token0 = new MockERC20("AlphaUSD", "aUSD", DECIMALS);
        token1 = new MockERC20("BetaUSD", "bUSD", DECIMALS);

        // Ensure correct ordering
        if (address(token0) > address(token1)) {
            (token0, token1) = (token1, token0);
        }

        console.log("Token0:", address(token0));
        console.log("  Symbol:", token0.symbol());
        console.log("Token1:", address(token1));
        console.log("  Symbol:", token1.symbol());

        // Fund TempoExchange with liquidity
        token0.mint(address(tempoExchange), INITIAL_LIQUIDITY * 100);
        token1.mint(address(tempoExchange), INITIAL_LIQUIDITY * 100);
        console.log("TempoExchange funded with liquidity");

        // Step 4: Deploy Factory
        console.log("\n[4/6] Deploying TempoExchangeAggregatorFactory...");
        factory = new TempoExchangeAggregatorFactory(poolManager, ITempoExchange(address(tempoExchange)));
        console.log("Factory deployed at:", address(factory));

        // Step 5: Mine and deploy hook
        console.log("\n[5/6] Mining valid hook address...");
        uint160 flags =
            uint160(Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG | Hooks.BEFORE_INITIALIZE_FLAG);

        bytes memory constructorArgs = abi.encode(address(poolManager), address(tempoExchange));

        (address hookAddress, bytes32 salt) =
            HookMiner.find(address(factory), flags, type(TempoExchangeAggregator).creationCode, constructorArgs);

        console.log("Mined hook address:", hookAddress);
        console.log("Salt:", vm.toString(salt));

        // Step 6: Create pool using factory
        console.log("\n[6/6] Creating pool...");
        uint24 fee = 500; // 0.05%
        int24 tickSpacing = 10;
        uint160 sqrtPriceX96 = 79228162514264337593543950336; // 1:1 price

        address deployedHook = factory.createPool(
            salt, Currency.wrap(address(token0)), Currency.wrap(address(token1)), fee, tickSpacing, sqrtPriceX96
        );

        hook = TempoExchangeAggregator(payable(deployedHook));
        console.log("Hook deployed at:", deployedHook);
        require(deployedHook == hookAddress, "Hook address mismatch!");

        // Store pool key for testing
        poolKey = PoolKey({
            currency0: Currency.wrap(address(token0)),
            currency1: Currency.wrap(address(token1)),
            fee: fee,
            tickSpacing: tickSpacing,
            hooks: IHooks(deployedHook)
        });
        poolId = poolKey.toId();

        // Mint test tokens to deployer
        token0.mint(deployer, INITIAL_LIQUIDITY);
        token1.mint(deployer, INITIAL_LIQUIDITY);
        console.log("Minted test tokens to deployer");

        vm.stopBroadcast();

        // Print summary
        console.log("\n=== DEPLOYMENT SUMMARY ===");
        console.log("Chain ID:", block.chainid);
        console.log("Deployer:", deployer);
        console.log("");
        console.log("Core Contracts:");
        console.log("  PoolManager:", address(poolManager));
        console.log("  TempoExchange (Mock):", address(tempoExchange));
        console.log("  Factory:", address(factory));
        console.log("  Hook:", address(hook));
        console.log("");
        console.log("Test Tokens:");
        console.log("  Token0:", address(token0));
        console.log("    Symbol:", token0.symbol());
        console.log("  Token1:", address(token1));
        console.log("    Symbol:", token1.symbol());
        console.log("");
        console.log("Pool Configuration:");
        console.log("  Pool ID:", vm.toString(PoolId.unwrap(poolId)));
        console.log("  Fee: 0.05%");
        console.log("  Initial Price: 1:1");
        console.log("");
        console.log("Next steps:");
        console.log("1. Test quote function");
        console.log("2. Test pseudoTotalValueLocked");
    }
}
