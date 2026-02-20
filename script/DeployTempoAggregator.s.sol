// SPDX-License-Identifier: MIT
pragma solidity 0.8.29;

import "forge-std/Script.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {HookMiner} from "@uniswap/v4-periphery/src/utils/HookMiner.sol";
import {
    TempoExchangeAggregator
} from "../src/aggregator-hooks/implementations/TempoExchange/TempoExchangeAggregator.sol";
import {ITempoExchange} from "../src/aggregator-hooks/implementations/TempoExchange/interfaces/ITempoExchange.sol";
import {SafePoolSwapTest} from "../test/aggregator-hooks/shared/SafePoolSwapTest.sol";

/// @title DeployTempoAggregator
/// @notice Deploys the TempoExchangeAggregator hook and a SafePoolSwapTest router
/// @dev Uses the deterministic CREATE2 factory directly to ensure correct hook addresses
///      on both standard EVM and Tempo (type 0x76) chains.
/// @dev On Tempo testnet, fund wallet first via RPC:
///      curl -X POST https://rpc.moderato.tempo.xyz -H "Content-Type: application/json" \
///        -d '{"jsonrpc":"2.0","method":"tempo_fundAddress","params":["ADDRESS"],"id":1}'
contract DeployTempoAggregator is Script {
    // Default testnet addresses (Tempo Moderato, chain 42431)
    address constant DEFAULT_POOL_MANAGER = 0x72B37Ad2798c6C2B51C7873Ed2E291a88bB909a2;
    address constant DEFAULT_TEMPO_EXCHANGE = 0xDEc0000000000000000000000000000000000000;

    /// @notice Mine salt (view-only). Run as: forge script ... --sig "mineSalt()"
    function mineSalt() external view {
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerKey);
        address poolManager = vm.envOr("POOL_MANAGER", DEFAULT_POOL_MANAGER);
        address tempoExchange = vm.envOr("TEMPO_EXCHANGE", DEFAULT_TEMPO_EXCHANGE);

        uint160 flags =
            uint160(Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG | Hooks.BEFORE_INITIALIZE_FLAG);
        bytes memory constructorArgs = abi.encode(poolManager, tempoExchange);

        // Mine against the deterministic CREATE2 factory
        (address expectedHook, bytes32 salt) =
            HookMiner.find(CREATE2_FACTORY, flags, type(TempoExchangeAggregator).creationCode, constructorArgs);

        console.log("Deployer:", deployer);
        console.log("CREATE2 Factory:", CREATE2_FACTORY);
        console.log("Expected hook address:", expectedHook);
        console.log("Salt:");
        console.logBytes32(salt);
        console.log("");
        console.log("Set HOOK_SALT and run deploy:");
        console.log(string.concat("  HOOK_SALT=", vm.toString(salt)));
    }

    /// @notice Deploy using pre-mined salt. Run with --broadcast --skip-simulation
    function run() external {
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        bytes32 salt = vm.envBytes32("HOOK_SALT");

        address poolManager = vm.envOr("POOL_MANAGER", DEFAULT_POOL_MANAGER);
        address tempoExchange = vm.envOr("TEMPO_EXCHANGE", DEFAULT_TEMPO_EXCHANGE);

        bytes memory constructorArgs = abi.encode(poolManager, tempoExchange);
        bytes memory initCode = abi.encodePacked(type(TempoExchangeAggregator).creationCode, constructorArgs);

        // Compute expected address from the deterministic CREATE2 factory
        address expectedHook = address(
            uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), CREATE2_FACTORY, salt, keccak256(initCode)))))
        );

        console.log("PoolManager:", poolManager);
        console.log("TempoExchange:", tempoExchange);
        console.log("Expected hook address:", expectedHook);

        vm.startBroadcast(deployerKey);

        // Call deterministic CREATE2 factory directly: first 32 bytes = salt, rest = init code
        bytes memory payload = abi.encodePacked(salt, initCode);
        (bool success,) = CREATE2_FACTORY.call(payload);
        require(success, "CREATE2 deployment failed");

        // Verify the hook was deployed with correct address
        require(expectedHook.code.length > 0, "Hook not deployed");
        console.log(string.concat("HOOK_ADDRESS=", vm.toString(expectedHook)));

        // Deploy swap router (standard CREATE is fine)
        SafePoolSwapTest router = new SafePoolSwapTest(IPoolManager(poolManager));
        console.log(string.concat("ROUTER_ADDRESS=", vm.toString(address(router))));

        vm.stopBroadcast();
    }
}
