// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import {IFeeController} from "./interfaces/IFeeController.sol";

/// @title FeeController
/// @notice Abstract contract that implements the IFeeController interface
abstract contract FeeController is IFeeController {
    /// @notice The address of the fee controller
    /// @dev The fee controller is the address that can update the fee configuration for a pool
    address public feeController;

    constructor(address _feeController) {
        feeController = _feeController;
    }

    /// @notice Modifier to only allow calls from the fee controller
    /// @dev This modifier is used to prevent unauthorized updates to the fee configuration per pool
    modifier onlyFeeController() {
        if (msg.sender != feeController) revert NotFeeController(msg.sender);
        _;
    }

    /// @inheritdoc IFeeController
    function setFeeController(address newFeeController) external onlyFeeController {
        feeController = newFeeController;
        emit FeeControllerUpdated(newFeeController);
    }
}
