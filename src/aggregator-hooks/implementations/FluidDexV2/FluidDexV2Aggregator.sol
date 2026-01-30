// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ExternalLiqSourceHook} from "../../ExternalLiqSourceHook.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IFluidDexV2} from "./interfaces/IFluidDexV2.sol";
import {IFluidDexV2Callback} from "./interfaces/IFluidDexV2Callback.sol";
import {IFluidDexV2Resolver} from "./interfaces/IFluidDexV2Resolver.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @title FluidDexV2Aggregator
/// @notice Uniswap V4 hook that aggregates liquidity from Fluid DEX V2 pools
/// @dev Implements the IFluidDexV2Callback interface for swap callbacks
contract FluidDexV2Aggregator is ExternalLiqSourceHook, IFluidDexV2Callback {
    using StateLibrary for IPoolManager;

    enum SwapKind {
        ExactIn,
        ExactOut
    }

    struct FluidDexV2SwapParams {
        SwapKind kind;
        IFluidDexV2.DexKey key;
        bool swap0To1;
        uint256 amount;
        bytes controllerData;
        bool isQuote;
    }

    /// @notice The Fluid DEX V2 contract
    IFluidDexV2 public immutable FLUID_DEX_V2;
    /// @notice The Fluid DEX V2 resolver for pool state queries
    IFluidDexV2Resolver public immutable FLUID_DEX_V2_RESOLVER;
    /// @notice The unique identifier for this DEX pool
    bytes32 public dexId;
    /// @notice The key identifying the Fluid DEX pool
    IFluidDexV2.DexKey public dexKey;
    /// @notice The DEX type identifier
    uint256 public dexType;
    /// @notice The controller address for the Fluid DEX pool
    address public controller;
    /// @notice The Uniswap V4 pool ID associated with this aggregator
    PoolId public localPoolId;

    bool private _isReversed;
    address private constant FLUID_NATIVE_CURRENCY = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;
    // The slot holding the inflight state, transiently. bytes32(uint256(keccak256("InFlight")) - 1)
    bytes32 private constant INFLIGHT_SLOT = 0x60d3e47259b598a408c0f35a2690d6e03fbf8cbc79ab359d5d81f5f451a5750e;
    /// Swap Module ID of 1 is used for exactIn and exactOut swaps
    uint256 private constant SWAP_MODULE_ID = 1;

    error TokenNotInPool(address token);
    error TokensNotInPool(address token0, address token1);
    error InvalidSwapKind();
    error UnauthorizedCaller();
    error Reentrancy();
    error SlippageExceeded();
    error AmountInMaxExceeded();
    error QuoteResult(uint256 amountIn, uint256 amountOut);
    error UnexpectedSuccess();
    error UnexpectedError();

    constructor(
        IPoolManager _manager,
        IFluidDexV2 _dexV2,
        IFluidDexV2Resolver _dexV2Resolver,
        address _controller,
        uint256 _dexType
    ) ExternalLiqSourceHook(_manager) {
        FLUID_DEX_V2 = _dexV2;
        FLUID_DEX_V2_RESOLVER = _dexV2Resolver;
        controller = _controller;
        dexType = _dexType;
    }

    /// @notice Callback invoked by FluidDexV2 during startOperation to execute the swap
    /// @dev Decodes swap parameters and executes the appropriate swap (exactIn or exactOut)
    /// @param data ABI-encoded FluidDexV2SwapParams containing swap configuration
    /// @return The result bytes from the swap operation
    function startOperationCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != address(FLUID_DEX_V2)) revert UnauthorizedCaller();
        if (_getTransientInflight()) revert Reentrancy();

        FluidDexV2SwapParams memory fluidParams = abi.decode(data, (FluidDexV2SwapParams));
        _setTransientInflight(true);

        bytes memory swapResult;
        uint256 amountIn;
        uint256 amountOut;

        if (fluidParams.kind == SwapKind.ExactIn) {
            amountIn = fluidParams.amount;
            IFluidDexV2.SwapInParams memory p = IFluidDexV2.SwapInParams({
                dexKey: fluidParams.key,
                swap0To1: fluidParams.swap0To1,
                amountIn: amountIn,
                amountOutMin: 0,
                controllerData: fluidParams.controllerData
            });

            bytes memory callData = abi.encodeWithSelector(IFluidDexV2.swapIn.selector, p);
            swapResult = FLUID_DEX_V2.operate(dexType, SWAP_MODULE_ID, callData);

            (amountOut,,) = abi.decode(swapResult, (uint256, uint256, uint256));

            _settleSwap(fluidParams, fluidParams.amount, amountOut);
        } else {
            amountOut = fluidParams.amount;
            IFluidDexV2.SwapOutParams memory p = IFluidDexV2.SwapOutParams({
                dexKey: fluidParams.key,
                swap0To1: fluidParams.swap0To1,
                amountOut: amountOut,
                amountInMax: type(uint256).max,
                controllerData: fluidParams.controllerData
            });

            bytes memory callData = abi.encodeWithSelector(IFluidDexV2.swapOut.selector, p);
            swapResult = FLUID_DEX_V2.operate(dexType, SWAP_MODULE_ID, callData);

            (amountIn,,) = abi.decode(swapResult, (uint256, uint256, uint256));

            _settleSwap(fluidParams, amountIn, fluidParams.amount);
        }

        _setTransientInflight(false);
        if (fluidParams.isQuote) {
            revert QuoteResult(amountIn, amountOut);
        }
        return swapResult;
    }

    /// @inheritdoc ExternalLiqSourceHook
    function quote(bool zeroToOne, int256 amountSpecified, PoolId poolId) external payable override returns (uint256) {
        if (PoolId.unwrap(poolId) != PoolId.unwrap(localPoolId)) revert PoolDoesNotExist();
        bool fluidSwap0to1 = _isReversed ? !zeroToOne : zeroToOne;
        FluidDexV2SwapParams memory fluidParams = FluidDexV2SwapParams({
            kind: amountSpecified < 0 ? SwapKind.ExactIn : SwapKind.ExactOut,
            key: dexKey,
            swap0To1: fluidSwap0to1,
            amount: amountSpecified < 0 ? uint256(-amountSpecified) : uint256(amountSpecified),
            controllerData: "",
            isQuote: false
        });
        (bool ok, bytes memory ret) = address(FLUID_DEX_V2)
            .call(abi.encodeWithSelector(IFluidDexV2.startOperation.selector, abi.encode(fluidParams)));

        // startOperation should "fail" because callback reverts with QuoteResult error
        if (ok) revert UnexpectedSuccess();

        // If it reverted with QuoteResult error, decode it.
        // Custom error encoding: selector (4 bytes) + abi-encoded args
        if (ret.length >= 4 && bytes4(ret) == QuoteResult.selector) {
            // Strip selector
            assembly {
                ret := add(ret, 4)
            }
            (uint256 amountIn, uint256 amountOut) = abi.decode(ret, (uint256, uint256));
            if (amountSpecified < 0) {
                return amountOut;
            } else {
                return amountIn;
            }
        }
        revert UnexpectedError();
    }

    /// @inheritdoc ExternalLiqSourceHook
    function pseudoTotalValueLocked(PoolId poolId) external view override returns (uint256 amount0, uint256 amount1) {
        if (PoolId.unwrap(poolId) != PoolId.unwrap(localPoolId)) revert PoolDoesNotExist();
        address token0 = dexKey.token0 == FLUID_NATIVE_CURRENCY ? address(0) : dexKey.token0;
        address token1 = dexKey.token1 == FLUID_NATIVE_CURRENCY ? address(0) : dexKey.token1;
        uint256 balance0;
        uint256 balance1;
        if (token0 == address(0)) {
            balance0 = address(FLUID_DEX_V2).balance;
        } else {
            balance0 = IERC20(token0).balanceOf(address(FLUID_DEX_V2));
        }
        if (token1 == address(0)) {
            balance1 = address(FLUID_DEX_V2).balance;
        } else {
            balance1 = IERC20(token1).balanceOf(address(FLUID_DEX_V2));
        }
        return _isReversed ? (balance1, balance0) : (balance0, balance1);
    }

    function _beforeInitialize(address, PoolKey calldata key, uint160) internal override returns (bytes4) {
        // Convert address(0) (Uniswap v4 native currency) to Fluid's native currency representation
        address token0 = Currency.unwrap(key.currency0);
        address token1 = Currency.unwrap(key.currency1);
        if (token0 == address(0)) {
            token0 = FLUID_NATIVE_CURRENCY;
            _isReversed = true;
            (token0, token1) = (token1, token0);
        }

        dexKey = IFluidDexV2.DexKey({
            token0: token0, token1: token1, fee: key.fee, tickSpacing: uint24(key.tickSpacing), controller: controller
        });

        dexId = keccak256(abi.encode(dexKey));

        IFluidDexV2Resolver.DexPoolState memory dexPoolState = FLUID_DEX_V2_RESOLVER.getDexPoolState(dexType, dexKey);

        // As recommended by the docs: https://docs.fluid.instadapp.io/integrate/dex-v2-swaps.html
        if (dexPoolState.dexPoolStateRaw.dexVariablesUnpacked.currentSqrtPriceX96 > 0) revert PoolDoesNotExist();

        localPoolId = key.toId();

        emit AggregatorPoolRegistered(key.toId());
        return IHooks.beforeInitialize.selector;
    }

    function _conductSwap(Currency, Currency, SwapParams calldata params, PoolId)
        internal
        override
        returns (uint256 amountSettle, uint256 amountTake, bool hasSettled)
    {
        bool fluidSwap0to1 = _isReversed ? !params.zeroForOne : params.zeroForOne;
        FluidDexV2SwapParams memory fluidParams = FluidDexV2SwapParams({
            kind: params.amountSpecified < 0 ? SwapKind.ExactIn : SwapKind.ExactOut,
            key: dexKey,
            swap0To1: fluidSwap0to1,
            amount: params.amountSpecified < 0 ? uint256(-params.amountSpecified) : uint256(params.amountSpecified),
            controllerData: "",
            isQuote: false
        });

        bytes memory res = FLUID_DEX_V2.startOperation(abi.encode(fluidParams));
        (uint256 resultAmount,,) = abi.decode(res, (uint256, uint256, uint256));

        if (params.amountSpecified < 0) {
            // Exact-In: resultAmount is amount Out
            amountTake = uint256(-params.amountSpecified);
            amountSettle = resultAmount;
        } else {
            // Exact-Out: resultAmount is amount In
            amountSettle = uint256(params.amountSpecified);
            amountTake = resultAmount;
        }

        hasSettled = true;
        return (amountSettle, amountTake, hasSettled);
    }

    function _settleSwap(FluidDexV2SwapParams memory fluidParams, uint256 amountIn, uint256 amountOut) internal {
        address inToken = fluidParams.swap0To1 ? fluidParams.key.token0 : fluidParams.key.token1;
        address outToken = fluidParams.swap0To1 ? fluidParams.key.token1 : fluidParams.key.token0;

        // Check if tokens are native currency
        bool inTokenIsNative = inToken == FLUID_NATIVE_CURRENCY;
        bool outTokenIsNative = outToken == FLUID_NATIVE_CURRENCY;
        uint256 msgValue = inTokenIsNative ? amountIn : 0;

        FLUID_DEX_V2.settle{value: msgValue}(inToken, int256(amountIn), 0, 0, address(this), true);

        // Convert Fluid native currency to address(0) for Uniswap v4 poolManager
        address outTokenForV4 = outTokenIsNative ? address(0) : outToken;
        poolManager.sync(Currency.wrap(outTokenForV4));

        if (outTokenIsNative) {
            FLUID_DEX_V2.settle(outToken, 0, 0, int256(amountOut), address(this), false);
            poolManager.settle{value: amountOut}();
        } else {
            FLUID_DEX_V2.settle(outToken, 0, 0, int256(amountOut), address(poolManager), false);
            poolManager.settle();
        }
    }

    /// @inheritdoc IFluidDexV2Callback
    function dexCallback(address token, address to, uint256 amount) external {
        if (msg.sender != address(FLUID_DEX_V2)) revert UnauthorizedCaller();
        if (!_getTransientInflight()) revert Reentrancy();
        // Convert Fluid's native currency representation to address(0) for Uniswap v4
        if (token == FLUID_NATIVE_CURRENCY) {
            token = address(0);
        }
        poolManager.take(Currency.wrap(token), to, amount);
    }

    function _setTransientInflight(bool value) private {
        uint256 _value = value ? 1 : 0;
        assembly {
            tstore(INFLIGHT_SLOT, _value)
        }
    }

    function _getTransientInflight() private view returns (bool value) {
        uint256 _value;
        assembly {
            _value := tload(INFLIGHT_SLOT)
        }
        // Results to true if the slot is not empty
        value = _value > 0;
    }
}
