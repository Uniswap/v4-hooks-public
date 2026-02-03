// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IFluidDexT1} from "../../../../src/aggregator-hooks/implementations/FluidDexT1/interfaces/IFluidDexT1.sol";
import {IDexCallback} from "../../../../src/aggregator-hooks/implementations/FluidDexT1/interfaces/IDexCallback.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

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

    // Tokens for callback simulation
    address public token0;
    address public token1;

    error SwapInRevert();
    error SwapOutRevert();
    error SwapInWithCallbackRevert();
    error SwapOutWithCallbackRevert();

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

    function setTokens(address _token0, address _token1) external {
        token0 = _token0;
        token1 = _token1;
    }

    function swapIn(bool, uint256, uint256, address to_) external payable override returns (uint256 amountOut_) {
        if (revertSwapIn) revert SwapInRevert();
        (to_);
        return returnSwapIn;
    }

    function swapOut(bool, uint256 amountOut_, uint256, address to_)
        external
        payable
        override
        returns (uint256 amountIn_)
    {
        if (revertSwapOut) revert SwapOutRevert();
        (to_);
        return returnSwapOut;
    }

    function swapInWithCallback(bool swap0to1_, uint256 amountIn_, uint256, address to_)
        external
        payable
        override
        returns (uint256 amountOut_)
    {
        if (revertSwapInWithCallback) revert SwapInWithCallbackRevert();
        // Determine tokenIn based on swap direction
        address tokenIn = swap0to1_ ? token0 : token1;
        address tokenOut = swap0to1_ ? token1 : token0;
        // Call back the hook to pull tokens (simulating Fluid's callback)
        IDexCallback(msg.sender).dexCallback(tokenIn, amountIn_);
        // Transfer output tokens to recipient
        IERC20(tokenOut).transfer(to_, returnSwapInWithCallback);
        return returnSwapInWithCallback;
    }

    function swapOutWithCallback(bool swap0to1_, uint256 amountOut_, uint256, address to_)
        external
        payable
        override
        returns (uint256 amountIn_)
    {
        if (revertSwapOutWithCallback) revert SwapOutWithCallbackRevert();
        // Determine tokenIn based on swap direction
        address tokenIn = swap0to1_ ? token0 : token1;
        address tokenOut = swap0to1_ ? token1 : token0;
        // Call back the hook to pull tokens (simulating Fluid's callback)
        IDexCallback(msg.sender).dexCallback(tokenIn, returnSwapOutWithCallback);
        // Transfer output tokens to recipient
        IERC20(tokenOut).transfer(to_, amountOut_);
        return returnSwapOutWithCallback;
    }
}
