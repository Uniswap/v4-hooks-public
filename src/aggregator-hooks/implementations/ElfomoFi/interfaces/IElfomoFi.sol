// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/// @title IElfomoFi
/// @notice Interface for ElfomoFi: a singleton PropAMM router with offchain-streamed quotes
/// @dev Lives at 0xf0f0F0F0FB0d738452EfD03A28e8be14C76d5f73 on Base and BSC.
///      Mirrors the relevant subset of the deployed ElfomoFi contract surface.
interface IElfomoFi {
    /// @notice A pair supported by ElfomoFi's pricing oracle.
    /// @param tokenA One side of the pair (order is ElfomoFi-defined, not necessarily sorted).
    /// @param tokenB The other side of the pair.
    struct TokenPair {
        address tokenA;
        address tokenB;
    }

    /// @notice Emitted when ElfomoFi registers a new supported token pair.
    /// @param tokenA One side of the newly-supported pair.
    /// @param tokenB The other side of the newly-supported pair.
    event PairAdded(address tokenA, address tokenB);

    /// @notice Emitted when ElfomoFi executes a swap.
    /// @param quoteId The pricing oracle's quote identifier consumed by the swap.
    /// @param partnerId Partner identifier supplied by the caller for rebate tracking.
    /// @param executor The `msg.sender` of the swap call.
    /// @param receiver The recipient of `toToken`.
    /// @param fromToken The token spent on the swap.
    /// @param toToken The token received from the swap.
    /// @param fromAmount Amount of `fromToken` actually paid, in token base units.
    /// @param toAmount Amount of `toToken` actually received, in token base units.
    event ElfomoTrade(
        uint256 indexed quoteId,
        uint256 indexed partnerId,
        address executor,
        address receiver,
        address fromToken,
        address toToken,
        uint256 fromAmount,
        uint256 toAmount
    );

    /// @dev Thrown when the realized swap amount violates the caller's limit
    ///      (exact-in: realized output below `limitAmount`; exact-out: realized input above `limitAmount`).
    /// @param limitAmount The caller-supplied limit, in token base units.
    /// @param actualAmount The realized amount that violated the limit, in token base units.
    error InsufficientAmount(uint256 limitAmount, uint256 actualAmount);
    /// @dev Thrown when the pricing oracle returns a zero amount for the requested swap.
    error ExecutionFailed();
    /// @dev Thrown when `swapWithContractBalance` is called while the contract holds zero `fromToken`.
    error ZeroBalance();

    /// @notice Get the expected output amount for an exact-input swap.
    /// @param fromToken The token to spend.
    /// @param toToken The token to receive.
    /// @param fromAmount Amount of `fromToken` to spend, in token base units.
    /// @return toAmount Expected amount of `toToken` received, in token base units.
    function getAmountOut(address fromToken, address toToken, uint256 fromAmount)
        external
        view
        returns (uint256 toAmount);

    /// @notice Get the required input amount for an exact-output swap.
    /// @param fromToken The token to spend.
    /// @param toToken The token to receive.
    /// @param toAmount Desired amount of `toToken`, in token base units.
    /// @return fromAmount Required amount of `fromToken`, in token base units.
    function getAmountIn(address fromToken, address toToken, uint256 toAmount)
        external
        view
        returns (uint256 fromAmount);

    /// @notice Get the full list of token pairs currently supported by ElfomoFi.
    /// @return The list of supported pairs (order is ElfomoFi-defined).
    function getSupportedPairs() external view returns (TokenPair[] memory);

    /// @notice Swap tokens without prior approval; ElfomoFi pulls `fromToken` from `msg.sender` via the callback.
    /// @param fromToken The address of the token to swap from.
    /// @param toToken The address of the token to swap to.
    /// @param specifiedAmount Positive for exact input in `fromToken`, negative for exact output in `toToken`.
    /// @param limitAmount Minimum `toAmount` for exact input, maximum `fromAmount` for exact output. Use `0` to
    ///        skip the exact-output limit check.
    /// @param receiver The address to receive the `toToken`.
    /// @param partnerId Partner identifier for rebates/tracking, `0` if not used.
    /// @param callbackData Opaque bytes passed through to the callback on `msg.sender`.
    function swapWithCallback(
        address fromToken,
        address toToken,
        int256 specifiedAmount,
        uint256 limitAmount,
        address receiver,
        uint256 partnerId,
        bytes calldata callbackData
    ) external;
}
