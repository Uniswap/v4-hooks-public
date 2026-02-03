// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {
    IFluidDexLite
} from "../../../../src/aggregator-hooks/implementations/FluidDexLite/interfaces/IFluidDexLite.sol";

/// @title MockIFluidDexLite
/// @notice Mock Fluid DEX Lite pool with settable swapSingle return for unit tests.
contract MockIFluidDexLite is IFluidDexLite {
    uint256 public returnSwapSingle;
    bool public revertSwapSingle;

    function setReturnSwapSingle(uint256 amount) external {
        returnSwapSingle = amount;
    }

    function setRevertSwapSingle(bool doRevert) external {
        revertSwapSingle = doRevert;
    }

    function swapSingle(
        DexKey calldata,
        bool,
        int256,
        uint256,
        address to_,
        bool isCallback_,
        bytes calldata,
        bytes calldata
    ) external payable override returns (uint256 amountUnspecified_) {
        if (revertSwapSingle) revert("MockIFluidDexLite: swapSingle revert");
        if (isCallback_) {
            // Caller (aggregator) will receive callback; test can handle token flow separately
            (to_);
        }
        return returnSwapSingle;
    }
}
