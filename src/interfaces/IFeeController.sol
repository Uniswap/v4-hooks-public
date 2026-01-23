// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

/// @notice Interface for the FeeController
interface IFeeController {
    /// @notice Error thrown when the caller is not the fee controller
    /// @param caller The invalid address attempting to update the pool fee data
    error NotFeeController(address caller);

    /// @notice Event emitted when the fee controller is updated
    /// @param feeController The new fee controller
    event FeeControllerUpdated(address indexed feeController);

    /// @notice Set the fee controller
    /// @param newFeeController The address of the new fee controller
    function setFeeController(address newFeeController) external;
}
