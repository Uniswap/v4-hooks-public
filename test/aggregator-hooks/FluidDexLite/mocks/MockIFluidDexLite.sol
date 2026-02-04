// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {
    IFluidDexLite
} from "../../../../src/aggregator-hooks/implementations/FluidDexLite/interfaces/IFluidDexLite.sol";
import {
    IFluidDexLiteCallback
} from "../../../../src/aggregator-hooks/implementations/FluidDexLite/interfaces/IFluidDexLiteCallback.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @title MockIFluidDexLite
/// @notice Mock Fluid DEX Lite pool with settable swapSingle return for unit tests.
contract MockIFluidDexLite is IFluidDexLite {
    uint256 public returnSwapSingle;
    bool public revertSwapSingle;
    bool public useNativeCurrencyInCallback;
    address private constant FLUID_NATIVE_CURRENCY = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;

    error SwapSingleRevert();

    function setReturnSwapSingle(uint256 amount) external {
        returnSwapSingle = amount;
    }

    function setRevertSwapSingle(bool doRevert) external {
        revertSwapSingle = doRevert;
    }

    function setUseNativeCurrencyInCallback(bool useNative) external {
        useNativeCurrencyInCallback = useNative;
    }

    receive() external payable {}

    function swapSingle(
        DexKey calldata dexKey_,
        bool swap0to1_,
        int256 amountSpecified_,
        uint256,
        address to_,
        bool isCallback_,
        bytes calldata,
        bytes calldata data_
    ) external payable override returns (uint256 amountUnspecified_) {
        if (revertSwapSingle) revert SwapSingleRevert();

        // Determine tokens based on swap direction
        address tokenIn = swap0to1_ ? dexKey_.token0 : dexKey_.token1;
        address tokenOut = swap0to1_ ? dexKey_.token1 : dexKey_.token0;

        // For exact-in (positive amountSpecified_), amountIn = amountSpecified_
        // For exact-out (negative amountSpecified_), amountIn = returnSwapSingle
        uint256 amountIn = amountSpecified_ > 0 ? uint256(amountSpecified_) : returnSwapSingle;

        if (isCallback_) {
            // Call back the hook to pull tokens
            // Use FLUID_NATIVE_CURRENCY if flag is set (for testing native currency conversion)
            address callbackToken = useNativeCurrencyInCallback ? FLUID_NATIVE_CURRENCY : tokenIn;
            IFluidDexLiteCallback(msg.sender).dexCallback(callbackToken, amountIn, data_);
        }

        // Transfer output tokens to recipient
        if (tokenOut == FLUID_NATIVE_CURRENCY || tokenOut == address(0)) {
            // Native currency output
            (bool success,) = to_.call{value: returnSwapSingle}("");
            require(success, "ETH transfer failed");
        } else {
            IERC20(tokenOut).transfer(to_, returnSwapSingle);
        }

        return returnSwapSingle;
    }
}
