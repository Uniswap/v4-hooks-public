// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import {FeeController} from "../FeeController.sol";
import {IFeeController} from "../interfaces/IFeeController.sol";

/// @title FeeControllerImplementation
/// @notice Implementation of the FeeController contract
contract FeeControllerImplementation is FeeController {
    constructor(address _feeController) FeeController(_feeController) {}
}
