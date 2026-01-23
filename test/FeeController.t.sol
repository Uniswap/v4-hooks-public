// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {FeeControllerImplementation} from "../src/test/FeeControllerImplementation.sol";
import {IFeeController} from "../src/interfaces/IFeeController.sol";

contract FeeControllerTest is Test {
    event FeeControllerUpdated(address indexed feeController);
    FeeControllerImplementation public feeControllerImplementation;
    address poolFeeController = makeAddr("poolFeeController");

    function setUp() public {
        feeControllerImplementation = new FeeControllerImplementation(poolFeeController);
    }

    function test_setFeeController_revertsWithNotFeeController() public {
        vm.prank(address(this));
        vm.expectRevert(abi.encodeWithSelector(IFeeController.NotFeeController.selector, address(this)));
        feeControllerImplementation.setFeeController(address(1));
    }

    function test_setFeeController_succeeds() public {
        assertEq(feeControllerImplementation.feeController(), poolFeeController);
        vm.expectEmit(true, false, false, true);
        emit FeeControllerUpdated(address(1));
        vm.prank(poolFeeController);
        feeControllerImplementation.setFeeController(address(1));
        assertEq(feeControllerImplementation.feeController(), address(1));
    }
}
