// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ITesseraSwap} from "../../../../src/aggregator-hooks/implementations/Tessera/interfaces/ITesseraSwap.sol";
import {ITesseraSwapCallback} from
    "../../../../src/aggregator-hooks/implementations/Tessera/interfaces/ITesseraSwapCallback.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @title MockTesseraSwap
/// @notice Mock implementation of TesseraSwap for tests. Acts as both router and treasury
///         (so the input pull just verifies a balance bump on this contract).
contract MockTesseraSwap is ITesseraSwap {
    using SafeERC20 for IERC20;

    uint256 public constant FEE_BPS = 10;
    uint256 public constant BPS_DENOMINATOR = 10_000;

    mapping(address => mapping(address => bool)) public supportedPairs;

    /// @notice Test knob: when true, the next `tesseraSwapWithCallback` underpays the engine-side
    ///         "specified" amount by `mismatchOffset` (used to exercise the hook's
    ///         `EngineSpecifiedAmountMismatch` defense).
    bool public engineMisreportNext;
    uint256 public engineMisreportOffset;

    /// @notice Test knob: when true, the next callback fires with inverted signs.
    bool public engineInvertSignsNext;

    error UnsupportedPair(address tokenA, address tokenB);
    error AmountCheckFailed();
    error InputNotDelivered(uint256 expected, uint256 actual);

    function addSupportedPair(address tokenA, address tokenB) external {
        supportedPairs[tokenA][tokenB] = true;
        supportedPairs[tokenB][tokenA] = true;
    }

    /// @notice Knob: cause the next swap's callback to report a "specified" amount short by `offset`.
    function setEngineMisreportNext(bool enabled, uint256 offset) external {
        engineMisreportNext = enabled;
        engineMisreportOffset = offset;
    }

    /// @notice Knob: cause the next swap's callback to fire with inverted signs.
    function setEngineInvertSignsNext(bool enabled) external {
        engineInvertSignsNext = enabled;
    }

    function tesseraSwapViewAmounts(address tokenIn, address tokenOut, int256 amountSpecified)
        external
        view
        override
        returns (uint256 amountIn, uint256 amountOut)
    {
        if (!supportedPairs[tokenIn][tokenOut]) revert UnsupportedPair(tokenIn, tokenOut);
        if (amountSpecified > 0) {
            amountIn = uint256(amountSpecified);
            amountOut = (amountIn * (BPS_DENOMINATOR - FEE_BPS)) / BPS_DENOMINATOR;
        } else {
            amountOut = uint256(-amountSpecified);
            amountIn = (amountOut * BPS_DENOMINATOR + (BPS_DENOMINATOR - FEE_BPS - 1)) / (BPS_DENOMINATOR - FEE_BPS);
        }
    }

    function tesseraSwapWithAllowances(
        address tokenIn,
        address tokenOut,
        int256 amountSpecified,
        uint256 amountCheck,
        address recipient,
        bytes calldata // swapData
    ) external override {
        (uint256 amountIn, uint256 amountOut) = _viewAmounts(tokenIn, tokenOut, amountSpecified);
        _checkLimits(amountSpecified, amountIn, amountOut, amountCheck);
        IERC20(tokenOut).safeTransfer(recipient, amountOut);
        IERC20(tokenIn).safeTransferFrom(msg.sender, address(this), amountIn);
        emit TesseraTrade(tokenIn, tokenOut, amountIn, amountOut, recipient);
    }

    function tesseraSwapWithCallback(
        address tokenIn,
        address tokenOut,
        int256 amountSpecified,
        uint256 amountCheck,
        address recipient,
        bytes calldata callbackData,
        bytes calldata // swapData
    ) external override {
        (uint256 amountIn, uint256 amountOut) = _viewAmounts(tokenIn, tokenOut, amountSpecified);
        _checkLimits(amountSpecified, amountIn, amountOut, amountCheck);

        // Apply test knobs to the callback-reported values (engine misbehavior simulation).
        int256 reportedIn = int256(amountIn);
        int256 reportedOut = -int256(amountOut);
        if (engineMisreportNext) {
            if (amountSpecified > 0) {
                // Tessera exact-in: shortchange the input the engine claims it consumed
                reportedIn = int256(amountIn - engineMisreportOffset);
            } else {
                // Tessera exact-out: shortchange the output the engine claims it delivered
                reportedOut = -int256(amountOut - engineMisreportOffset);
            }
            engineMisreportNext = false;
            engineMisreportOffset = 0;
        }
        if (engineInvertSignsNext) {
            reportedIn = -int256(amountIn);
            reportedOut = int256(amountOut);
            engineInvertSignsNext = false;
        }

        uint256 balanceBefore = IERC20(tokenIn).balanceOf(address(this));
        IERC20(tokenOut).safeTransfer(recipient, amountOut);
        ITesseraSwapCallback(msg.sender).tesseraSwapCallback(reportedIn, reportedOut, callbackData);
        uint256 delta = IERC20(tokenIn).balanceOf(address(this)) - balanceBefore;
        if (delta < amountIn) revert InputNotDelivered(amountIn, delta);

        emit TesseraTrade(tokenIn, tokenOut, amountIn, amountOut, recipient);
    }

    function _viewAmounts(address tokenIn, address tokenOut, int256 amountSpecified)
        private
        view
        returns (uint256 amountIn, uint256 amountOut)
    {
        if (!supportedPairs[tokenIn][tokenOut]) revert UnsupportedPair(tokenIn, tokenOut);
        if (amountSpecified > 0) {
            amountIn = uint256(amountSpecified);
            amountOut = (amountIn * (BPS_DENOMINATOR - FEE_BPS)) / BPS_DENOMINATOR;
        } else {
            amountOut = uint256(-amountSpecified);
            amountIn = (amountOut * BPS_DENOMINATOR + (BPS_DENOMINATOR - FEE_BPS - 1)) / (BPS_DENOMINATOR - FEE_BPS);
        }
    }

    function _checkLimits(int256 amountSpecified, uint256 amountIn, uint256 amountOut, uint256 amountCheck)
        private
        pure
    {
        bool ok = amountSpecified > 0 ? amountOut >= amountCheck : amountIn <= amountCheck;
        if (!ok) revert AmountCheckFailed();
    }
}
