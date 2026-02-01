// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {TempoExchangeAggregator} from
    "../src/aggregator-hooks/implementations/TempoExchange/TempoExchangeAggregator.sol";
import {ITempoExchange} from "../src/aggregator-hooks/implementations/TempoExchange/interfaces/ITempoExchange.sol";
import {HookMiner} from "@uniswap/v4-periphery/src/utils/HookMiner.sol";

/// @notice Directly deploys hook and initializes pool (for precompile compatibility)
contract CreateTempoPoolDirect is Script {
    using PoolIdLibrary for PoolKey;

    address constant POOL_MANAGER = 0x72B37Ad2798c6C2B51C7873Ed2E291a88bB909a2;
    address constant TEMPO_EXCHANGE = 0xDEc0000000000000000000000000000000000000;

    function run() public {
        uint256 deployerPrivateKey = vm.envUint("TEMPO_TESTNET_PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);

        // Get tokens from environment
        address token0 = vm.envAddress("TEMPO_TOKEN0");
        address token1 = vm.envAddress("TEMPO_TOKEN1");

        console.log("=== CREATING TEMPO POOL (DIRECT) ===");
        console.log("Deployer:", deployer);
        console.log("Token0:", token0);
        console.log("Token1:", token1);

        // Mine valid hook address
        console.log("\nMining hook address...");
        uint160 flags =
            uint160(Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG | Hooks.BEFORE_INITIALIZE_FLAG);

        bytes memory constructorArgs = abi.encode(POOL_MANAGER, TEMPO_EXCHANGE);

        (address hookAddress, bytes32 salt) = HookMiner.find(
            deployer,
            flags,
            type(TempoExchangeAggregator).creationCode,
            constructorArgs
        );

        console.log("Target hook address:", hookAddress);
        console.log("Salt:", vm.toString(salt));

        vm.startBroadcast(deployerPrivateKey);

        // Deploy hook directly
        console.log("\nDeploying hook...");
        TempoExchangeAggregator hook = new TempoExchangeAggregator{salt: salt}(
            IPoolManager(POOL_MANAGER), ITempoExchange(TEMPO_EXCHANGE)
        );

        require(address(hook) == hookAddress, "Hook address mismatch!");
        console.log("Hook deployed at:", address(hook));

        // Initialize pool
        console.log("\nInitializing pool...");
        uint24 fee = 500; // 0.05%
        int24 tickSpacing = 10;
        uint160 sqrtPriceX96 = 79228162514264337593543950336; // 1:1

        PoolKey memory poolKey = PoolKey({
            currency0: Currency.wrap(token0),
            currency1: Currency.wrap(token1),
            fee: fee,
            tickSpacing: tickSpacing,
            hooks: IHooks(address(hook))
        });

        IPoolManager(POOL_MANAGER).initialize(poolKey, sqrtPriceX96);

        PoolId poolId = poolKey.toId();

        vm.stopBroadcast();

        // Print summary
        console.log("\n=== POOL CREATED SUCCESSFULLY ===");
        console.log("Hook:", address(hook));
        console.log("Pool ID:", vm.toString(PoolId.unwrap(poolId)));
        console.log("Token0:", token0);
        console.log("Token1:", token1);
        console.log("");
        console.log("export HOOK=", address(hook));
        console.log("export POOL_ID=", vm.toString(PoolId.unwrap(poolId)));
    }
}
