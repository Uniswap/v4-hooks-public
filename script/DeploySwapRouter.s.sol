// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {SafePoolSwapTest} from "../test/aggregator-hooks/shared/SafePoolSwapTest.sol";

/// @notice Deploy SafePoolSwapTest router for testing
contract DeploySwapRouter is Script {
    function run() public {
        uint256 deployerPrivateKey = vm.envUint("TEMPO_TESTNET_PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);
        address poolManager = vm.envAddress("POOL_MANAGER");

        console.log("=== DEPLOYING SWAP ROUTER ===");
        console.log("Deployer:", deployer);
        console.log("PoolManager:", poolManager);

        vm.startBroadcast(deployerPrivateKey);

        SafePoolSwapTest router = new SafePoolSwapTest(IPoolManager(poolManager));

        console.log("SafePoolSwapTest deployed at:", address(router));

        vm.stopBroadcast();

        console.log("");
        console.log("export ROUTER=", address(router));
    }
}
