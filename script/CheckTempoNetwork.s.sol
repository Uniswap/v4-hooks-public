// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import {ITempoExchange} from "../src/aggregator-hooks/implementations/TempoExchange/interfaces/ITempoExchange.sol";
interface IERC20Metadata {
    function symbol() external view returns (string memory);
    function decimals() external view returns (uint8);
    function balanceOf(address) external view returns (uint256);
}

/// @notice Script to check Tempo network and find required addresses
contract CheckTempoNetwork is Script {
    function run() public view {
        console.log("=== TEMPO TESTNET CHECK ===");
        console.log("Chain ID:", block.chainid);
        console.log("Block number:", block.number);
        console.log("Block timestamp:", block.timestamp);

        // Check deployer
        address deployer = vm.envOr("TEMPO_TESTNET_DEPLOYER", address(0));
        if (deployer == address(0)) {
            uint256 pk = vm.envOr("TEMPO_TESTNET_PRIVATE_KEY", uint256(0));
            if (pk != 0) {
                deployer = vm.addr(pk);
            }
        }

        if (deployer != address(0)) {
            console.log("\nDeployer:", deployer);
            console.log("Balance:", deployer.balance / 1e18, "ETH");
        }

        // Check if TempoExchange address is set
        address tempoExchangeAddr = vm.envOr("TEMPO_EXCHANGE", address(0));
        if (tempoExchangeAddr != address(0)) {
            console.log("\nTempoExchange:", tempoExchangeAddr);
            console.log("Code size:", tempoExchangeAddr.code.length, "bytes");

            // Try to call it if it's a contract
            if (tempoExchangeAddr.code.length > 0) {
                console.log("TempoExchange appears to be deployed");
            }
        } else {
            console.log("\nWARNING: TEMPO_EXCHANGE not set in environment");
            console.log("Common precompile addresses to try:");
            console.log("  0x0000000000000000000000000000000000000001");
            console.log("  0x0000000000000000000000000000000000000100");
            console.log("  0x0000000000000000000000000000000000001000");
        }

        // Check if PoolManager is set
        address poolManagerAddr = vm.envOr("TEMPO_POOL_MANAGER", address(0));
        if (poolManagerAddr != address(0)) {
            console.log("\nPoolManager:", poolManagerAddr);
            console.log("Code size:", poolManagerAddr.code.length, "bytes");
        } else {
            console.log("\nPoolManager not set - will deploy new one");
        }

        // Check for test tokens
        address token0 = vm.envOr("TEMPO_TOKEN0", address(0));
        address token1 = vm.envOr("TEMPO_TOKEN1", address(0));

        if (token0 != address(0)) {
            console.log("\nToken0:", token0);
            if (token0.code.length > 0) {
                try IERC20Metadata(token0).symbol() returns (string memory symbol) {
                    console.log("  Symbol:", symbol);
                    try IERC20Metadata(token0).decimals() returns (uint8 decimals) {
                        console.log("  Decimals:", decimals);
                    } catch {}
                } catch {}
            }
        }

        if (token1 != address(0)) {
            console.log("\nToken1:", token1);
            if (token1.code.length > 0) {
                try IERC20Metadata(token1).symbol() returns (string memory symbol) {
                    console.log("  Symbol:", symbol);
                    try IERC20Metadata(token1).decimals() returns (uint8 decimals) {
                        console.log("  Decimals:", decimals);
                    } catch {}
                } catch {}
            }
        }

        console.log("\n=== ENVIRONMENT VARIABLES ===");
        console.log("Set these before deployment:");
        console.log("  export TEMPO_TESTNET_PRIVATE_KEY=<your_private_key>");
        console.log("  export TEMPO_EXCHANGE=<tempo_exchange_address>");
        console.log("  export TEMPO_POOL_MANAGER=<pool_manager_address> (optional)");
        console.log("  export TEMPO_TOKEN0=<token0_address> (optional, for testing)");
        console.log("  export TEMPO_TOKEN1=<token1_address> (optional, for testing)");
    }
}
