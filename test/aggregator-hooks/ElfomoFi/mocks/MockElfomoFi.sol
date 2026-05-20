// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IElfomoFi} from "../../../../src/aggregator-hooks/implementations/ElfomoFi/interfaces/IElfomoFi.sol";
import {
    IElfomoSwapCallback
} from "../../../../src/aggregator-hooks/implementations/ElfomoFi/interfaces/IElfomoSwapCallback.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @title MockElfomoFi
/// @notice Mock implementation of the ElfomoFi PropAMM router for unit tests
/// @dev The mock serves as both router and vault (so pulls are pure `transfer`s).
///      Pricing is a flat 0.1% fee on a 1:1 base rate, matching MockTempoExchange's style.
contract MockElfomoFi is IElfomoFi {
    using SafeERC20 for IERC20;

    uint256 public constant FEE_BPS = 10; // 0.1%
    uint256 public constant BPS_DENOMINATOR = 10_000;

    mapping(address => mapping(address => bool)) public supportedPairs;
    TokenPair[] private _allPairs;

    /// @notice Test knob: when true, the next `swapWithCallback` underpays the engine-side
    ///         "specified" amount by `mismatchOffset` (used to exercise the hook's
    ///         `EngineSpecifiedAmountMismatch` defense).
    bool public engineMisreportNext;
    uint256 public engineMisreportOffset;

    /// @notice Test knob: when true, the next callback fires with inverted signs (used to exercise
    ///         the hook's `InvalidCallbackAmounts` defense).
    bool public engineInvertSignsNext;

    /// @notice Register a token pair as supported (order-independent)
    function addSupportedPair(address tokenA, address tokenB) external {
        if (!supportedPairs[tokenA][tokenB]) {
            supportedPairs[tokenA][tokenB] = true;
            supportedPairs[tokenB][tokenA] = true;
            _allPairs.push(TokenPair({tokenA: tokenA, tokenB: tokenB}));
            emit PairAdded(tokenA, tokenB);
        }
    }

    /// @notice Register support in one direction only (for bidirectional-probe tests)
    function addSupportedPairOneWay(address fromToken, address toToken) external {
        supportedPairs[fromToken][toToken] = true;
        // do not add reverse direction, do not push into `_allPairs`
    }

    /// @notice Knob: cause the next swap's callback to report a "specified" amount short by `offset`.
    function setEngineMisreportNext(bool enabled, uint256 offset) external {
        engineMisreportNext = enabled;
        engineMisreportOffset = offset;
    }

    /// @notice Knob: cause the next swap's callback to fire with inverted (positive output / negative input) signs.
    function setEngineInvertSignsNext(bool enabled) external {
        engineInvertSignsNext = enabled;
    }

    function getAmountOut(address fromToken, address toToken, uint256 fromAmount)
        external
        view
        override
        returns (uint256 toAmount)
    {
        if (!supportedPairs[fromToken][toToken]) return 0;
        toAmount = (fromAmount * (BPS_DENOMINATOR - FEE_BPS)) / BPS_DENOMINATOR;
    }

    function getAmountIn(address fromToken, address toToken, uint256 toAmount)
        external
        view
        override
        returns (uint256 fromAmount)
    {
        if (!supportedPairs[fromToken][toToken]) return 0;
        // Ceiling: ensure user pays enough
        fromAmount = (toAmount * BPS_DENOMINATOR + (BPS_DENOMINATOR - FEE_BPS - 1)) / (BPS_DENOMINATOR - FEE_BPS);
    }

    function getSupportedPairs() external view override returns (TokenPair[] memory) {
        return _allPairs;
    }

    function swapWithCallback(
        address fromToken,
        address toToken,
        int256 specifiedAmount,
        uint256 limitAmount,
        address receiver,
        uint256, // partnerId
        bytes calldata callbackData
    ) external override {
        if (!supportedPairs[fromToken][toToken]) revert ExecutionFailed();

        uint256 fromAmount;
        uint256 toAmount;
        if (specifiedAmount >= 0) {
            fromAmount = uint256(specifiedAmount);
            toAmount = (fromAmount * (BPS_DENOMINATOR - FEE_BPS)) / BPS_DENOMINATOR;
            if (toAmount == 0) revert ExecutionFailed();
            if (toAmount < limitAmount) revert InsufficientAmount(limitAmount, toAmount);
        } else {
            toAmount = uint256(-specifiedAmount);
            fromAmount = (toAmount * BPS_DENOMINATOR + (BPS_DENOMINATOR - FEE_BPS - 1)) / (BPS_DENOMINATOR - FEE_BPS);
            if (fromAmount == 0) revert ExecutionFailed();
            if (limitAmount != 0 && fromAmount > limitAmount) revert InsufficientAmount(limitAmount, fromAmount);
        }

        // Mock is its own vault: deliver toToken directly to receiver
        IERC20(toToken).safeTransfer(receiver, toAmount);

        // Apply test knobs to the values reported to the callback (engine misbehavior simulation).
        int256 reportedFrom = int256(fromAmount);
        int256 reportedTo = -int256(toAmount);
        if (engineMisreportNext) {
            // Underreport the side the user specified, leaving the unspecified side honest.
            if (specifiedAmount >= 0) {
                // exact-in: shortchange the input the engine claims it consumed
                reportedFrom = int256(fromAmount - engineMisreportOffset);
            } else {
                // exact-out: shortchange the output the engine claims it delivered
                reportedTo = -int256(toAmount - engineMisreportOffset);
            }
            engineMisreportNext = false;
            engineMisreportOffset = 0;
        }
        if (engineInvertSignsNext) {
            reportedFrom = -int256(fromAmount);
            reportedTo = int256(toAmount);
            engineInvertSignsNext = false;
        }

        uint256 balanceBefore = IERC20(fromToken).balanceOf(address(this));
        IElfomoSwapCallback(msg.sender).elfomoSwapCallback(reportedFrom, reportedTo, callbackData);
        uint256 delta = IERC20(fromToken).balanceOf(address(this)) - balanceBefore;
        if (delta < fromAmount) revert InsufficientAmount(fromAmount, delta);
        _emitTrade(receiver, fromToken, toToken, delta, toAmount);
    }

    function _emitTrade(address receiver, address fromToken, address toToken, uint256 fromAmount, uint256 toAmount)
        private
    {
        emit ElfomoTrade(0, 0, msg.sender, receiver, fromToken, toToken, fromAmount, toAmount);
    }
}
