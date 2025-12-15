// SPDX-License-Identifier: UNLICENSED

pragma solidity ^0.8.26;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";

import {GatewayHook} from "./../src/guidestar/GatewayHook.sol";
import {HookMiner} from "./../test/utils/HookMiner.sol";
import {HelperConfig} from "./HelperConfig.sol";

contract DeployGatewayHook is HelperConfig, Script {
    error HookAddressMismatch();

    function run(address poolManager, uint160 flags, address _initialOwner) public returns (GatewayHook gatewayHook) {
        // Mine a salt that will produce a hook addres with the correct flags
        (address hookAddress, bytes32 salt) = HookMiner.find(
            CREATE2_DEPLOYER, flags, type(GatewayHook).creationCode, abi.encode(poolManager, _initialOwner)
        );
        // Deploy the hook using CREATE2
        // broadcasting actual transaction
        vm.broadcast();
        gatewayHook = new GatewayHook{salt: salt}(IPoolManager(poolManager), _initialOwner);
        console.log("Deployed GatewayHook at", address(gatewayHook));
        if (address(gatewayHook) != hookAddress) {
            revert HookAddressMismatch();
        }
    }
}
