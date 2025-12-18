// SPDX-License-Identifier: UNLICENSED

pragma solidity ^0.8.26;

import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";

library Constants {
    address constant ADDRESS_ZERO = address(0);
    bytes constant ZERO_BYTES = new bytes(0);

    // sqrt of 10 in Q64.96 - this is going to be the initial price, i.e. sqrt(10*2^192)
    uint160 constant SQRT_RATIO_10_1 = 250_541_448_375_047_931_186_413_801_569;
    uint160 constant SQRT_RATIO_1_1 = 2 ** 96;

    bytes32 constant LIQUIDITY_POSITION_SALT = 0x1234567890abcdef1234567890abcdef1234567890abcdef1234567890abcdef;

    uint160 constant HOOK_PERMISSIONS_FLAGS = uint160(
        Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_SWAP_FLAG
            | Hooks.AFTER_REMOVE_LIQUIDITY_FLAG | Hooks.AFTER_REMOVE_LIQUIDITY_RETURNS_DELTA_FLAG
    );
    // @dev To see more check
    // https://book.getfoundry.sh/tutorials/create2-tutorial?highlight=Create2%20deployer#deterministic-deployment-using-create2
    address constant CREATE2_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;
}
