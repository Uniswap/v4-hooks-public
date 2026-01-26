// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {ConfigManagerImplementation} from "../../src/stable/test/ConfigManagerImplementation.sol";
import {IConfigManager} from "../../src/stable/interfaces/IConfigManager.sol";

contract ConfigManagerTest is Test {
    event ConfigManagerUpdated(address indexed configManager);
    ConfigManagerImplementation public configManagerImplementation;
    address poolConfigManager = makeAddr("poolConfigManager");

    function setUp() public {
        configManagerImplementation = new ConfigManagerImplementation(poolConfigManager);
    }

    function test_setConfigManager_revertsWithNotConfigManager() public {
        vm.prank(address(this));
        vm.expectRevert(abi.encodeWithSelector(IConfigManager.NotConfigManager.selector, address(this)));
        configManagerImplementation.setConfigManager(address(1));
    }

    function test_setConfigManager_succeeds() public {
        assertEq(configManagerImplementation.configManager(), poolConfigManager);
        vm.expectEmit(true, false, false, true);
        emit ConfigManagerUpdated(address(1));
        vm.prank(poolConfigManager);
        configManagerImplementation.setConfigManager(address(1));
        assertEq(configManagerImplementation.configManager(), address(1));
    }

    function test_setConfigManager_gas() public {
        vm.prank(poolConfigManager);
        configManagerImplementation.setConfigManager(address(1));
        vm.snapshotGasLastCall("setConfigManager");
    }
}
