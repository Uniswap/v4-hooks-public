// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {StableStableHook} from "../src/StableStableHook.sol";
import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";

contract StableStableHookTest is Test, Deployers {
    StableStableHook stableStableHook = StableStableHook(
        address(
            uint160(
                uint256(type(uint160).max) & clearAllHookPermissionsMask | Hooks.BEFORE_INITIALIZE_FLAG
                    | Hooks.BEFORE_SWAP_FLAG
            )
        )
    );

    function setUp() public {
        deployFreshManagerAndRouters();
        StableStableHook impl = new StableStableHook(manager);
        vm.etch(address(stableStableHook), address(impl).code);
    }
}
