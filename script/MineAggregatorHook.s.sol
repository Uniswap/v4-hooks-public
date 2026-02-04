// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {AggregatorHookMiner} from "../src/aggregator-hooks/utils/AggregatorHookMiner.sol";

import {StableSwapNGAggregator} from "../src/aggregator-hooks/implementations/StableSwapNG/StableSwapNGAggregator.sol";
import {StableSwapAggregator} from "../src/aggregator-hooks/implementations/StableSwap/StableSwapAggregator.sol";
import {FluidDexT1Aggregator} from "../src/aggregator-hooks/implementations/FluidDexT1/FluidDexT1Aggregator.sol";
import {FluidDexLiteAggregator} from "../src/aggregator-hooks/implementations/FluidDexLite/FluidDexLiteAggregator.sol";

/// @notice Mines an address for an aggregator hook using AggregatorHookMiner
/// @dev This script finds a salt that produces a hook address with the correct flags and first byte identifier
contract MineAggregatorHookScript is Script {
    address constant CREATE2_DEPLOYER = address(0x4e59b44847b379578588920cA78FbF26c0B4956C);
    uint8 constant ID_STABLESWAP = 0xC1;
    uint8 constant ID_STABLESWAPNG = 0xC2;
    uint8 constant ID_FLUIDDEXT1 = 0xF1;
    uint8 constant ID_FLUIDDEXLITE = 0xF3;

    function run() public view {
        // Read salt offset from environment variable (default to 0)
        // Increment by 160_444 (MAX_LOOP) for each subsequent attempt
        uint256 saltOffset = vm.envOr("SALT_OFFSET", uint256(0));

        // Load constructor arguments from environment variable
        bytes memory constructorArgs = vm.envBytes("CONSTRUCTOR_ARGS");

        // First byte identifiers for aggregator hooks:
        // 0xC1 = StableSwap
        // 0xC2 = StableSwap-NG
        // 0xF1 = FluidDexT1
        // 0xF2 = FluidDexV2 (not yet implemented)
        // 0xF3 = FluidDexLite
        uint8 firstByte = uint8(vm.envUint("PROTOCOL_ID"));
        bytes memory creationCode;
        if (firstByte == ID_STABLESWAP) {
            creationCode = type(StableSwapAggregator).creationCode;
        } else if (firstByte == ID_STABLESWAPNG) {
            creationCode = type(StableSwapNGAggregator).creationCode;
        } else if (firstByte == ID_FLUIDDEXT1) {
            creationCode = type(FluidDexT1Aggregator).creationCode;
        } else if (firstByte == 0xF2) {
            revert("FluidDexV2 not yet implemented");
        } else if (firstByte == ID_FLUIDDEXLITE) {
            creationCode = type(FluidDexLiteAggregator).creationCode;
        } else {
            revert("Invalid protocol ID");
        }

        // Aggregator hooks require BEFORE_SWAP_FLAG, BEFORE_SWAP_RETURNS_DELTA_FLAG, and BEFORE_INITIALIZE_FLAG
        uint160 flags =
            uint160(Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG | Hooks.BEFORE_INITIALIZE_FLAG);

        console.log("Searching with salt offset:", saltOffset);

        // Mine a salt that will produce a hook address with the correct flags and first byte
        (address hookAddress, bytes32 salt) =
            AggregatorHookMiner.find(CREATE2_DEPLOYER, flags, firstByte, creationCode, constructorArgs, saltOffset);

        // Output the results
        console.log("=== Aggregator Hook Mining Results ===");
        console.log("Hook Address:", vm.toString(hookAddress));
        console.log("Salt (bytes32):", vm.toString(salt));
        console.log("Salt (uint256):", uint256(salt));
        console.log("First Byte:", firstByte);
        console.log("Flags:", flags);
        console.log("=====================================");
    }
}
