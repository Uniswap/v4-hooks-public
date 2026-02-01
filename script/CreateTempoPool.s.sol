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
import {TempoExchangeAggregatorFactory} from
    "../src/aggregator-hooks/implementations/TempoExchange/TempoExchangeAggregatorFactory.sol";
import {ITempoExchange} from "../src/aggregator-hooks/implementations/TempoExchange/interfaces/ITempoExchange.sol";
import {HookMiner} from "@uniswap/v4-periphery/src/utils/HookMiner.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

/// @notice Creates a pool with TempoExchange aggregator hook
contract CreateTempoPool is Script {
    using PoolIdLibrary for PoolKey;

    address constant FACTORY = 0x9D101e3c30ccF04ddE513f1687CB446E797ab735;
    address constant POOL_MANAGER = 0x72B37Ad2798c6C2B51C7873Ed2E291a88bB909a2;
    address constant TEMPO_EXCHANGE = 0xDEc0000000000000000000000000000000000000;

    uint8 constant DECIMALS = 6;
    uint256 constant INITIAL_MINT = 1_000_000 * 10 ** DECIMALS;

    function run() public {
        uint256 deployerPrivateKey = vm.envUint("TEMPO_TESTNET_PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);

        console.log("=== CREATING TEMPO POOL ===");
        console.log("Deployer:", deployer);
        console.log("Factory:", FACTORY);

        vm.startBroadcast(deployerPrivateKey);

        // Check if tokens are provided via env, otherwise deploy new ones
        address token0Addr = vm.envOr("TEMPO_TOKEN0", address(0));
        address token1Addr = vm.envOr("TEMPO_TOKEN1", address(0));

        MockERC20 token0;
        MockERC20 token1;

        if (token0Addr == address(0) || token1Addr == address(0)) {
            console.log("\nDeploying test tokens...");
            token0 = new MockERC20("TestUSD-A", "tUSD-A", DECIMALS);
            token1 = new MockERC20("TestUSD-B", "tUSD-B", DECIMALS);

            // Ensure correct ordering
            if (address(token0) > address(token1)) {
                (token0, token1) = (token1, token0);
            }

            console.log("Token0 deployed:", address(token0));
            console.log("  Symbol:", token0.symbol());
            console.log("Token1 deployed:", address(token1));
            console.log("  Symbol:", token1.symbol());

            // Mint tokens to deployer
            token0.mint(deployer, INITIAL_MINT);
            token1.mint(deployer, INITIAL_MINT);
            console.log("Minted tokens to deployer");
        } else {
            token0 = MockERC20(token0Addr);
            token1 = MockERC20(token1Addr);
            console.log("\nUsing existing tokens:");
            console.log("Token0:", address(token0));
            console.log("Token1:", address(token1));
        }

        // Mine valid hook address
        console.log("\nMining hook address...");
        uint160 flags =
            uint160(Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG | Hooks.BEFORE_INITIALIZE_FLAG);

        bytes memory constructorArgs = abi.encode(POOL_MANAGER, TEMPO_EXCHANGE);

        (address hookAddress, bytes32 salt) =
            HookMiner.find(FACTORY, flags, type(TempoExchangeAggregator).creationCode, constructorArgs);

        console.log("Mined hook address:", hookAddress);
        console.log("Salt:", vm.toString(salt));

        // Create pool via factory
        console.log("\nCreating pool...");
        uint24 fee = 500; // 0.05%
        int24 tickSpacing = 10;
        uint160 sqrtPriceX96 = 79228162514264337593543950336; // 1:1

        address deployedHook = TempoExchangeAggregatorFactory(FACTORY).createPool(
            salt, Currency.wrap(address(token0)), Currency.wrap(address(token1)), fee, tickSpacing, sqrtPriceX96
        );

        console.log("Pool created!");
        console.log("Hook:", deployedHook);

        // Verify hook address
        require(deployedHook == hookAddress, "Hook address mismatch!");

        PoolKey memory poolKey = PoolKey({
            currency0: Currency.wrap(address(token0)),
            currency1: Currency.wrap(address(token1)),
            fee: fee,
            tickSpacing: tickSpacing,
            hooks: IHooks(deployedHook)
        });
        PoolId poolId = poolKey.toId();

        vm.stopBroadcast();

        // Print summary
        console.log("\n=== POOL CREATED SUCCESSFULLY ===");
        console.log("Hook Address:", deployedHook);
        console.log("Pool ID:", vm.toString(PoolId.unwrap(poolId)));
        console.log("Token0:", address(token0));
        console.log("Token1:", address(token1));
        console.log("");
        console.log("Test the hook:");
        console.log("export HOOK=", deployedHook);
        console.log("export POOL_ID=", vm.toString(PoolId.unwrap(poolId)));
    }
}
