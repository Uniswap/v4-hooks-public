// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {MockQuoterHook} from "./mocks/MockQuoterHook.sol";

contract BaseALFHookTest is Test, Deployers {
    MockQuoterHook public hook;

    address owner = makeAddr("owner");

    Currency tokenA;
    Currency tokenB;
    PoolKey testPoolKey;

    function setUp() public {
        deployFreshManagerAndRouters();

        // Deploy MockQuoterHook at a flag-mined address
        uint160 flags =
            uint160(Hooks.AFTER_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG);
        hook = MockQuoterHook(address(uint160(uint256(type(uint160).max) & clearAllHookPermissionsMask | flags)));
        deployCodeTo("MockQuoterHook", abi.encode(manager, uint32(50_000)), address(hook));

        tokenA = Currency.wrap(address(0xA));
        tokenB = Currency.wrap(address(0xB));
        testPoolKey =
            PoolKey({currency0: tokenA, currency1: tokenB, fee: 3000, tickSpacing: 60, hooks: IHooks(address(hook))});

        // Set default prices
        hook.setPrice(1000e18, 1001e18);
    }

    // ──── maxGas ────

    function test_maxGas_returnsConstructorValue() public view {
        assertEq(hook.maxGas(), 50_000);
    }

    // ──── getIndicativeQuote ────

    function test_getIndicativeQuote_unattested() public view {
        uint256 output = hook.getIndicativeQuote(testPoolKey, true, -1e18, "");
        assertEq(output, 1000e18);
    }

    // ──── isLive ────

    function test_isLive() public view {
        assertTrue(hook.isLive());
    }

    function test_isLive_afterSetFalse() public {
        hook.setLive(false);
        assertFalse(hook.isLive());
    }
}
