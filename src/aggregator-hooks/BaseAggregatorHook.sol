// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {BeforeSwapDelta, toBeforeSwapDelta} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {BaseHook} from "@uniswap/v4-periphery/src/utils/BaseHook.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {DeltaResolver} from "@uniswap/v4-periphery/src/base/DeltaResolver.sol";
import {IAggregatorHook} from "./interfaces/IAggregatorHook.sol";
import {IV4FeeAdapter} from "@protocol-fees/interfaces/IV4FeeAdapter.sol";
import {ProtocolFeeLibrary} from "@uniswap/v4-core/src/libraries/ProtocolFeeLibrary.sol";

/// @title BaseAggregatorHook
/// @notice Abstract contract for implementing aggregator hooks in Uniswap V4
/// @dev Implements the IAggregatorHook interface and extends the BaseHook contract
abstract contract BaseAggregatorHook is IAggregatorHook, BaseHook, DeltaResolver {
    using CurrencyLibrary for Currency;
    using PoolIdLibrary for PoolKey;
    using SafeERC20 for IERC20;
    using StateLibrary for IPoolManager;

    /// @notice The V4 protocol fee adapter used for fee resolution
    IV4FeeAdapter public immutable protocolFeeAdapter;

    /// @notice Maps pool IDs to their corresponding aggregated pool addresses
    mapping(PoolId => address) public poolIdToAggregatedPool;

    /// @notice Maps pool IDs to their corresponding protocol fees
    mapping(PoolId => uint24) public poolIdToProtocolFee;

    /// @notice Initializes the hook with required dependencies
    /// @param _manager The Uniswap V4 PoolManager contract
    /// @param _protocolFeeAdapter The V4FeeAdapter contract for protocol fee resolution
    constructor(IPoolManager _manager, IV4FeeAdapter _protocolFeeAdapter) BaseHook(_manager) {
        if (address(_protocolFeeAdapter) == address(0)) revert InvalidProtocolFeeAdapter();
        protocolFeeAdapter = _protocolFeeAdapter;
    }

    /// @inheritdoc IAggregatorHook
    function pseudoTotalValueLocked(PoolId poolId) external view virtual returns (uint256 amount0, uint256 amount1);

    /// @inheritdoc IAggregatorHook
    function quote(bool zeroToOne, int256 amountSpecified, PoolId poolId)
        external
        payable
        returns (uint256 amountUnspecified)
    {
        amountUnspecified = _rawQuote(zeroToOne, amountSpecified, poolId);

        uint24 protocolFee = _getProtocolFee(zeroToOne, poolId);

        if (protocolFee == 0) return amountUnspecified;

        bool isExactInput = amountSpecified < 0;
        uint256 feeAmount = _calculateProtocolFeeAmount(protocolFee, isExactInput, amountUnspecified);

        if (isExactInput) {
            amountUnspecified -= feeAmount;
        } else {
            amountUnspecified += feeAmount;
        }
    }

    /// @inheritdoc IAggregatorHook
    function refreshProtocolFee(PoolKey calldata key) external {
        PoolId poolId = key.toId();
        uint24 protocolFee = protocolFeeAdapter.getFee(key);
        uint24 oldProtocolFee = poolIdToProtocolFee[poolId];

        if (protocolFee == oldProtocolFee) return;

        poolIdToProtocolFee[poolId] = protocolFee;
        emit ProtocolFeeUpdated(poolId, protocolFee);
    }

    /// @inheritdoc BaseHook
    function getHookPermissions() public pure override returns (Hooks.Permissions memory permissions) {
        permissions.beforeSwap = true;
        permissions.beforeSwapReturnDelta = true;
        permissions.beforeInitialize = true;
    }

    /// @notice Abstract function for contracts to implement conducting the swap on the aggregated liquidity source
    /// @param settleCurrency The currency to be settled on the V4 PoolManager (swapper's output currency)
    /// @param takeCurrency The currency to be taken from the V4 PoolManager (swapper's input currency)
    /// @param params The swap parameters
    /// @param poolId The V4 Pool ID
    /// @return amountSettle The amount of the currency being settled (swapper's output amount)
    /// @return amountTake The amount of the currency being taken (swapper's input amount)
    /// @return hasSettled Whether the swap has been settled inside of the _conductSwap function
    /// @dev To settle the swap inside of the _conductSwap function, you must follow the 'sync, send,
    ///      settle' pattern and set hasSettled to true
    function _conductSwap(Currency settleCurrency, Currency takeCurrency, SwapParams calldata params, PoolId poolId)
        internal
        virtual
        returns (uint256 amountSettle, uint256 amountTake, bool hasSettled);

    /// @notice Returns the raw quote from the underlying liquidity source without protocol fees
    /// @param zeroToOne Whether the swap is from token0 to token1
    /// @param amountSpecified The amount specified (negative for exact-in, positive for exact-out)
    /// @param poolId The pool ID
    /// @return amountUnspecified The raw unspecified amount before protocol fee adjustment
    function _rawQuote(bool zeroToOne, int256 amountSpecified, PoolId poolId)
        internal
        virtual
        returns (uint256 amountUnspecified);

    function _beforeInitialize(address, PoolKey calldata key, uint160) internal virtual override returns (bytes4) {
        emit AggregatorPoolRegistered(key.toId());
        return IHooks.beforeInitialize.selector;
    }

    function _beforeSwap(address, PoolKey calldata key, SwapParams calldata params, bytes calldata)
        internal
        override
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        (uint256 amountIn, uint256 amountOut) = _internalSettle(key, params);
        int128 unspecifiedDelta = _processAmounts(amountIn, amountOut, params.amountSpecified < 0);
        int128 specified = int128(-params.amountSpecified); // cancel core

        unspecifiedDelta += _applyProtocolFee(key, params, unspecifiedDelta);

        if (params.amountSpecified > 0) {
            // For exactOut, in cases where the implementation's amountOut may be off.
            // NOTE: it would be up to the router to handle this
            specified = -int128(uint128(amountOut));
        }

        return (IHooks.beforeSwap.selector, toBeforeSwapDelta(specified, unspecifiedDelta), 0);
    }

    function _applyProtocolFee(PoolKey calldata key, SwapParams calldata params, int128 unspecifiedDelta)
        internal
        returns (int128)
    {
        uint24 protocolFee = _getProtocolFee(params.zeroForOne, key.toId());

        if (protocolFee == 0) return 0;

        bool isExactInput = params.amountSpecified < 0;

        // Determine the unspecified currency (the side protocol fee is taken from)
        Currency unspecifiedCurrency = params.zeroForOne == isExactInput ? key.currency1 : key.currency0;

        uint256 absUnspecified = uint256(uint128(unspecifiedDelta < 0 ? -unspecifiedDelta : unspecifiedDelta));
        uint256 protocolFeeAmount = _calculateProtocolFeeAmount(protocolFee, isExactInput, absUnspecified);

        // Send the protocol fee to the token jar
        poolManager.take(unspecifiedCurrency, protocolFeeAdapter.TOKEN_JAR(), protocolFeeAmount);

        return int128(uint128(protocolFeeAmount));
    }

    function _calculateProtocolFeeAmount(uint24 protocolFee, bool isExactInput, uint256 amountUnspecified)
        internal
        pure
        returns (uint256)
    {
        if (isExactInput) {
            return (amountUnspecified * protocolFee) / ProtocolFeeLibrary.PIPS_DENOMINATOR;
        } else {
            // This calculation ensures the fee is the correct proportion of the total input.
            // For a protocol fee of X%, the fee amount will be X% of the total input rather than X%
            // of the pre-protocol fee input.
            return (amountUnspecified * protocolFee) / (ProtocolFeeLibrary.PIPS_DENOMINATOR - protocolFee);
        }
    }

    function _getProtocolFee(bool zeroToOne, PoolId poolId) internal view returns (uint24 protocolFee) {
        uint24 protocolFeeRaw = poolIdToProtocolFee[poolId];
        protocolFee = zeroToOne
            ? ProtocolFeeLibrary.getZeroForOneFee(protocolFeeRaw)
            : ProtocolFeeLibrary.getOneForZeroFee(protocolFeeRaw);
    }

    function _processAmounts(uint256 amountIn, uint256 amountOut, bool exactInput)
        internal
        pure
        returns (int128 unspecifiedDelta)
    {
        uint256 unspecified;
        if (exactInput) {
            // Exact-In
            unspecified = amountOut;
            unspecifiedDelta = -int128(uint128(unspecified));
        } else {
            // Exact-Out
            unspecified = amountIn;
            unspecifiedDelta = int128(uint128(unspecified));
        }
    }

    function _internalSettle(PoolKey calldata key, SwapParams calldata params)
        internal
        returns (uint256 amountIn, uint256 amountOut)
    {
        Currency settleCurrency = params.zeroForOne ? key.currency1 : key.currency0;
        Currency takeCurrency = params.zeroForOne ? key.currency0 : key.currency1;

        (uint256 amountSettle, uint256 amountTake, bool hasSettled) =
            _conductSwap(settleCurrency, takeCurrency, params, key.toId());

        if (!hasSettled) {
            _settle(settleCurrency, address(this), amountSettle);
        }

        return (amountTake, amountSettle);
    }

    function _pay(Currency token, address payer, uint256 amount) internal override {
        if (token.balanceOf(payer) >= amount) {
            token.transfer(address(poolManager), amount);
        } else {
            revert InsufficientLiquidity();
        }
        poolManager.settle();
    }

    /// @notice Allows the contract to receive ETH for native currency swaps
    /// @dev Required for handling native ETH transfers during swap operations
    receive() external payable {}
}
