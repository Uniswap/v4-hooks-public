// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IFluidDexT1} from "../../../../src/aggregator-hooks/implementations/FluidDexT1/interfaces/IFluidDexT1.sol";

/// @title MockIFluidDexT1
/// @notice Mock Fluid DEX T1 pool with settable swap return values for unit tests.
contract MockIFluidDexT1 is IFluidDexT1 {
    uint256 public returnSwapIn;
    uint256 public returnSwapOut;
    uint256 public returnSwapInWithCallback;
    uint256 public returnSwapOutWithCallback;
    bool public revertSwapIn;
    bool public revertSwapOut;
    bool public revertSwapInWithCallback;
    bool public revertSwapOutWithCallback;

    function setReturnSwapIn(uint256 amount) external {
        returnSwapIn = amount;
    }

    function setReturnSwapOut(uint256 amount) external {
        returnSwapOut = amount;
    }

    function setReturnSwapInWithCallback(uint256 amount) external {
        returnSwapInWithCallback = amount;
    }

    function setReturnSwapOutWithCallback(uint256 amount) external {
        returnSwapOutWithCallback = amount;
    }

    function setRevertSwapIn(bool doRevert) external {
        revertSwapIn = doRevert;
    }

    function setRevertSwapOut(bool doRevert) external {
        revertSwapOut = doRevert;
    }

    function setRevertSwapInWithCallback(bool doRevert) external {
        revertSwapInWithCallback = doRevert;
    }

    function setRevertSwapOutWithCallback(bool doRevert) external {
        revertSwapOutWithCallback = doRevert;
    }

    function swapIn(bool, uint256, uint256, address to_) external payable override returns (uint256 amountOut_) {
        if (revertSwapIn) revert("MockIFluidDexT1: swapIn revert");
        (to_);
        return returnSwapIn;
    }

    function swapOut(bool, uint256 amountOut_, uint256, address to_)
        external
        payable
        override
        returns (uint256 amountIn_)
    {
        if (revertSwapOut) revert("MockIFluidDexT1: swapOut revert");
        (to_);
        return returnSwapOut;
    }

    function swapInWithCallback(bool, uint256, uint256, address to_)
        external
        payable
        override
        returns (uint256 amountOut_)
    {
        if (revertSwapInWithCallback) revert("MockIFluidDexT1: swapInWithCallback revert");
        (to_);
        return returnSwapInWithCallback;
    }

    function swapOutWithCallback(bool, uint256, uint256, address to_)
        external
        payable
        override
        returns (uint256 amountIn_)
    {
        if (revertSwapOutWithCallback) revert("MockIFluidDexT1: swapOutWithCallback revert");
        (to_);
        return returnSwapOutWithCallback;
    }
}
