// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PropAMMIndex} from "../../src/propamm/PropAMMIndex.sol";
import {IPropAMMIndex, QuoterEntry, QuoterType} from "../../src/propamm/interfaces/IPropAMMIndex.sol";

contract PropAMMIndexTest is Test {
    using PoolIdLibrary for PoolKey;

    PropAMMIndex public index;

    address hook1 = makeAddr("hook1");
    address hook2 = makeAddr("hook2");
    address hook3 = makeAddr("hook3");

    Currency tokenA = Currency.wrap(address(0xA));
    Currency tokenB = Currency.wrap(address(0xB));
    Currency tokenC = Currency.wrap(address(0xC));

    function setUp() public {
        index = new PropAMMIndex();
    }

    function _poolKey(address hook, Currency c0, Currency c1) internal pure returns (PoolKey memory) {
        return PoolKey({
            currency0: c0,
            currency1: c1,
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(hook)
        });
    }

    // ──── register ────

    function test_register_succeeds() public {
        PoolKey memory key = _poolKey(hook1, tokenA, tokenB);

        vm.prank(hook1);
        index.register(key, QuoterType.STORAGE, 50_000, "");

        assertTrue(index.isRegistered(hook1, key));

        QuoterEntry memory entry = index.getQuoter(hook1, key);
        assertEq(entry.hook, hook1);
        assertEq(entry.maxGas, 50_000);
        assertTrue(entry.isLive);
        assertEq(uint8(entry.quoterType), uint8(QuoterType.STORAGE));
    }

    function test_register_emitsEvent() public {
        PoolKey memory key = _poolKey(hook1, tokenA, tokenB);

        vm.expectEmit(true, true, true, true);
        emit IPropAMMIndex.QuoterRegistered(hook1, tokenA, tokenB, key, QuoterType.STORAGE, 50_000);

        vm.prank(hook1);
        index.register(key, QuoterType.STORAGE, 50_000, "");
    }

    function test_register_revertsUnauthorized() public {
        PoolKey memory key = _poolKey(hook1, tokenA, tokenB);

        vm.expectRevert(IPropAMMIndex.UnauthorizedCaller.selector);
        vm.prank(address(0xdead));
        index.register(key, QuoterType.STORAGE, 50_000, "");
    }

    function test_register_revertsDuplicate() public {
        PoolKey memory key = _poolKey(hook1, tokenA, tokenB);

        vm.prank(hook1);
        index.register(key, QuoterType.STORAGE, 50_000, "");

        vm.expectRevert(IPropAMMIndex.AlreadyRegistered.selector);
        vm.prank(hook1);
        index.register(key, QuoterType.STORAGE, 50_000, "");
    }

    function test_register_multipleQuotersSamePair() public {
        PoolKey memory key1 = _poolKey(hook1, tokenA, tokenB);
        PoolKey memory key2 = _poolKey(hook2, tokenA, tokenB);

        vm.prank(hook1);
        index.register(key1, QuoterType.STORAGE, 50_000, "");
        vm.prank(hook2);
        index.register(key2, QuoterType.HOOKDATA, 80_000, "");

        QuoterEntry[] memory quoters = index.getQuoters(tokenA, tokenB);
        assertEq(quoters.length, 2);
        assertEq(quoters[0].hook, hook1);
        assertEq(quoters[1].hook, hook2);
    }

    function test_register_withMetadata() public {
        PoolKey memory key = _poolKey(hook1, tokenA, tokenB);
        bytes memory meta = abi.encode("wss://quotes.maker.com/v1/stream");

        vm.prank(hook1);
        index.register(key, QuoterType.HOOKDATA, 30_000, meta);

        QuoterEntry memory entry = index.getQuoter(hook1, key);
        assertEq(entry.metadata, meta);
    }

    // ──── update ────

    function test_update_succeeds() public {
        PoolKey memory key = _poolKey(hook1, tokenA, tokenB);

        vm.prank(hook1);
        index.register(key, QuoterType.STORAGE, 50_000, "");

        vm.prank(hook1);
        index.update(key, false, "");

        QuoterEntry memory entry = index.getQuoter(hook1, key);
        assertFalse(entry.isLive);
    }

    function test_update_withMetadata() public {
        PoolKey memory key = _poolKey(hook1, tokenA, tokenB);

        vm.prank(hook1);
        index.register(key, QuoterType.STORAGE, 50_000, "initial");

        bytes memory newMeta = "updated";
        vm.prank(hook1);
        index.update(key, true, newMeta);

        QuoterEntry memory entry = index.getQuoter(hook1, key);
        assertEq(entry.metadata, newMeta);
    }

    function test_update_emptyMetadataPreservesExisting() public {
        PoolKey memory key = _poolKey(hook1, tokenA, tokenB);
        bytes memory meta = "initial";

        vm.prank(hook1);
        index.register(key, QuoterType.STORAGE, 50_000, meta);

        vm.prank(hook1);
        index.update(key, false, "");

        QuoterEntry memory entry = index.getQuoter(hook1, key);
        assertEq(entry.metadata, meta);
    }

    function test_update_revertsUnauthorized() public {
        PoolKey memory key = _poolKey(hook1, tokenA, tokenB);

        vm.prank(hook1);
        index.register(key, QuoterType.STORAGE, 50_000, "");

        vm.expectRevert(IPropAMMIndex.UnauthorizedCaller.selector);
        vm.prank(address(0xdead));
        index.update(key, false, "");
    }

    function test_update_revertsNotRegistered() public {
        PoolKey memory key = _poolKey(hook1, tokenA, tokenB);

        vm.expectRevert(IPropAMMIndex.NotRegistered.selector);
        vm.prank(hook1);
        index.update(key, false, "");
    }

    function test_update_emitsEvent() public {
        PoolKey memory key = _poolKey(hook1, tokenA, tokenB);

        vm.prank(hook1);
        index.register(key, QuoterType.STORAGE, 50_000, "");

        vm.expectEmit(true, false, false, true);
        emit IPropAMMIndex.QuoterUpdated(hook1, key, false);

        vm.prank(hook1);
        index.update(key, false, "");
    }

    // ──── deregister ────

    function test_deregister_succeeds() public {
        PoolKey memory key = _poolKey(hook1, tokenA, tokenB);

        vm.prank(hook1);
        index.register(key, QuoterType.STORAGE, 50_000, "");

        vm.prank(hook1);
        index.deregister(key);

        assertFalse(index.isRegistered(hook1, key));

        QuoterEntry[] memory quoters = index.getQuoters(tokenA, tokenB);
        assertEq(quoters.length, 0);
    }

    function test_deregister_swapAndPop() public {
        // Register 3 quoters, deregister the first one, verify swap-and-pop
        PoolKey memory key1 = _poolKey(hook1, tokenA, tokenB);
        PoolKey memory key2 = _poolKey(hook2, tokenA, tokenB);
        PoolKey memory key3 = _poolKey(hook3, tokenA, tokenB);

        vm.prank(hook1);
        index.register(key1, QuoterType.STORAGE, 50_000, "");
        vm.prank(hook2);
        index.register(key2, QuoterType.HOOKDATA, 80_000, "");
        vm.prank(hook3);
        index.register(key3, QuoterType.EXTERNAL, 30_000, "");

        // Deregister hook1 (index 0) — hook3 should move to index 0
        vm.prank(hook1);
        index.deregister(key1);

        QuoterEntry[] memory quoters = index.getQuoters(tokenA, tokenB);
        assertEq(quoters.length, 2);
        // hook3 was swapped into position 0
        assertEq(quoters[0].hook, hook3);
        assertEq(quoters[1].hook, hook2);

        // Verify the moved entry is still retrievable
        assertTrue(index.isRegistered(hook3, key3));
        QuoterEntry memory entry3 = index.getQuoter(hook3, key3);
        assertEq(entry3.maxGas, 30_000);
    }

    function test_deregister_lastElement() public {
        // Deregistering the only/last element doesn't need a swap
        PoolKey memory key = _poolKey(hook1, tokenA, tokenB);

        vm.prank(hook1);
        index.register(key, QuoterType.STORAGE, 50_000, "");

        vm.prank(hook1);
        index.deregister(key);

        assertEq(index.getQuoters(tokenA, tokenB).length, 0);
    }

    function test_deregister_revertsUnauthorized() public {
        PoolKey memory key = _poolKey(hook1, tokenA, tokenB);

        vm.prank(hook1);
        index.register(key, QuoterType.STORAGE, 50_000, "");

        vm.expectRevert(IPropAMMIndex.UnauthorizedCaller.selector);
        vm.prank(address(0xdead));
        index.deregister(key);
    }

    function test_deregister_revertsNotRegistered() public {
        PoolKey memory key = _poolKey(hook1, tokenA, tokenB);

        vm.expectRevert(IPropAMMIndex.NotRegistered.selector);
        vm.prank(hook1);
        index.deregister(key);
    }

    function test_deregister_emitsEvent() public {
        PoolKey memory key = _poolKey(hook1, tokenA, tokenB);

        vm.prank(hook1);
        index.register(key, QuoterType.STORAGE, 50_000, "");

        vm.expectEmit(true, false, false, true);
        emit IPropAMMIndex.QuoterDeregistered(hook1, key);

        vm.prank(hook1);
        index.deregister(key);
    }

    // ──── getQuoters (pair symmetry) ────

    function test_getQuoters_pairSymmetry() public {
        PoolKey memory key = _poolKey(hook1, tokenA, tokenB);

        vm.prank(hook1);
        index.register(key, QuoterType.STORAGE, 50_000, "");

        QuoterEntry[] memory forward = index.getQuoters(tokenA, tokenB);
        QuoterEntry[] memory reverse = index.getQuoters(tokenB, tokenA);

        assertEq(forward.length, reverse.length);
        assertEq(forward[0].hook, reverse[0].hook);
    }

    function test_getQuoters_emptyForUnregisteredPair() public view {
        QuoterEntry[] memory quoters = index.getQuoters(tokenA, tokenC);
        assertEq(quoters.length, 0);
    }

    // ──── getQuotersByType ────

    function test_getQuotersByType_filtersCorrectly() public {
        PoolKey memory key1 = _poolKey(hook1, tokenA, tokenB);
        PoolKey memory key2 = _poolKey(hook2, tokenA, tokenB);
        PoolKey memory key3 = _poolKey(hook3, tokenA, tokenB);

        vm.prank(hook1);
        index.register(key1, QuoterType.STORAGE, 50_000, "");
        vm.prank(hook2);
        index.register(key2, QuoterType.HOOKDATA, 80_000, "");
        vm.prank(hook3);
        index.register(key3, QuoterType.STORAGE, 30_000, "");

        QuoterEntry[] memory storageQuoters = index.getQuotersByType(tokenA, tokenB, QuoterType.STORAGE);
        assertEq(storageQuoters.length, 2);

        QuoterEntry[] memory hookdataQuoters = index.getQuotersByType(tokenA, tokenB, QuoterType.HOOKDATA);
        assertEq(hookdataQuoters.length, 1);
        assertEq(hookdataQuoters[0].hook, hook2);

        QuoterEntry[] memory externalQuoters = index.getQuotersByType(tokenA, tokenB, QuoterType.EXTERNAL);
        assertEq(externalQuoters.length, 0);
    }

    // ──── getQuoter ────

    function test_getQuoter_revertsNotRegistered() public {
        PoolKey memory key = _poolKey(hook1, tokenA, tokenB);

        vm.expectRevert(IPropAMMIndex.NotRegistered.selector);
        index.getQuoter(hook1, key);
    }

    // ──── isRegistered ────

    function test_isRegistered_returnsFalseForUnknown() public view {
        PoolKey memory key = _poolKey(hook1, tokenA, tokenB);
        assertFalse(index.isRegistered(hook1, key));
    }

    // ──── re-register after deregister ────

    function test_reregisterAfterDeregister() public {
        PoolKey memory key = _poolKey(hook1, tokenA, tokenB);

        vm.prank(hook1);
        index.register(key, QuoterType.STORAGE, 50_000, "");

        vm.prank(hook1);
        index.deregister(key);

        // Should be able to re-register
        vm.prank(hook1);
        index.register(key, QuoterType.HOOKDATA, 100_000, "new");

        QuoterEntry memory entry = index.getQuoter(hook1, key);
        assertEq(entry.maxGas, 100_000);
        assertEq(uint8(entry.quoterType), uint8(QuoterType.HOOKDATA));
    }
}
