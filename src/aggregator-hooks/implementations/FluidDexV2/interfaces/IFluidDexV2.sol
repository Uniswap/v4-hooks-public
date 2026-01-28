// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title IFluidDexV2
/// @notice Interface for Fluid DEX V2 concentrated liquidity pools
interface IFluidDexV2 {
    struct DexKey {
        address token0;
        address token1;
        uint24 fee;
        uint24 tickSpacing;
        address controller;
    }

    struct SwapInParams {
        DexKey dexKey;
        bool swap0To1;
        uint256 amountIn;
        uint256 amountOutMin;
        bytes controllerData;
    }

    struct SwapOutParams {
        DexKey dexKey;
        bool swap0To1;
        uint256 amountOut;
        uint256 amountInMax;
        bytes controllerData;
    }
    /// @notice Initiates a batched operation with callback pattern
    /// @dev Calls back to the sender with IFluidDexV2Callback.startOperationCallback
    /// @param data Encoded operation data to be processed
    /// @return result The result data from the callback execution
    function startOperation(bytes calldata data) external returns (bytes memory result);

    /// @notice Executes a DEX operation within an active startOperation context
    /// @param dexType The type of DEX (3 for D3, 4 for D4)
    /// @param implementationId The implementation identifier for the operation
    /// @param data Encoded operation parameters
    /// @return returnData The result of the operation
    function operate(uint256 dexType, uint256 implementationId, bytes memory data)
        external
        returns (bytes memory returnData);

    /// @notice Settles token balances with the DEX, handling supply, borrow, and storage
    /// @param token The token address to settle
    /// @param supplyAmount Amount to supply (positive) or withdraw (negative)
    /// @param borrowAmount Amount to borrow (positive) or repay (negative)
    /// @param storeAmount Amount to store in the DEX's internal accounting
    /// @param to Recipient address for withdrawn/borrowed tokens
    /// @param isCallback If true, uses callback for token transfer instead of direct transfer
    function settle(
        address token,
        int256 supplyAmount,
        int256 borrowAmount,
        int256 storeAmount,
        address to,
        bool isCallback
    ) external payable;

    /// @notice Executes a swap with an exact input amount
    /// @param params SwapInParams struct containing:
    ///   - dexKey: Pool identification (tokens, fee, tickSpacing, controller)
    ///   - swap0To1: Direction of swap (true = token0→token1, false = token1→token0)
    ///   - amountIn: Exact amount of input tokens to swap
    ///   - amountOutMin: Minimum acceptable output amount (slippage protection)
    ///   - controllerData: Additional data for the pool controller
    /// @return amountOut The amount of output tokens received
    /// @return protocolFee The protocol fee charged on this swap
    /// @return lpFee The LP fee charged on this swap
    function swapIn(SwapInParams calldata params)
        external
        returns (uint256 amountOut, uint256 protocolFee, uint256 lpFee);

    /// @notice Executes a swap with an exact output amount
    /// @param params SwapOutParams struct containing:
    ///   - dexKey: Pool identification (tokens, fee, tickSpacing, controller)
    ///   - swap0To1: Direction of swap (true = token0→token1, false = token1→token0)
    ///   - amountOut: Exact amount of output tokens to receive
    ///   - amountInMax: Maximum acceptable input amount (slippage protection)
    ///   - controllerData: Additional data for the pool controller
    /// @return amountIn The amount of input tokens used
    /// @return protocolFee The protocol fee charged on this swap
    /// @return lpFee The LP fee charged on this swap
    function swapOut(SwapOutParams calldata params)
        external
        returns (uint256 amountIn, uint256 protocolFee, uint256 lpFee);
}
