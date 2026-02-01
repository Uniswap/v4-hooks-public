// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {TempoExchangeAggregator} from
    "../src/aggregator-hooks/implementations/TempoExchange/TempoExchangeAggregator.sol";
import {HookMiner} from "@uniswap/v4-periphery/src/utils/HookMiner.sol";

/// @notice Mine a valid salt for TempoExchangeAggregator hook
contract MineHookSalt is Script {
    function run() public view {
        address factory = vm.envAddress("FACTORY");
        address poolManager = vm.envAddress("POOL_MANAGER");
        address tempoExchange = vm.envAddress("TEMPO_EXCHANGE");

        console.log("Mining salt for:");
        console.log("Factory:", factory);
        console.log("PoolManager:", poolManager);
        console.log("TempoExchange:", tempoExchange);
        console.log("");

        uint160 flags =
            uint160(Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG | Hooks.BEFORE_INITIALIZE_FLAG);

        bytes memory constructorArgs = abi.encode(poolManager, tempoExchange);

        console.log("Mining... (this may take a while)");
        (address hookAddress, bytes32 salt) =
            HookMiner.find(factory, flags, type(TempoExchangeAggregator).creationCode, constructorArgs);

        console.log("");
        console.log("=== MINED SALT ===");
        console.log("Hook Address:", hookAddress);
        console.log("Salt:", vm.toString(salt));
        console.log("");
        console.log("Use this salt in createPool:");
        console.log("export SALT=", vm.toString(salt));
    }
}
