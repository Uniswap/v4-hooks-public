// SPDX-License-Identifier: MIT
pragma solidity 0.8.29;

import {BaseAggregatorHook} from "../../BaseAggregatorHook.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";

import {IUniswapV2Pair} from "./interfaces/IUniswapV2Pair.sol";
import {IUniswapV2Factory} from "./interfaces/IUniswapV2Factory.sol";

/// @title UniswapV2Aggregator
/// @notice Hook that aggregates liquidity from a canonical Uniswap V2 compatible pair resolved via factory.getPair
/// @dev Fee and tickSpacing on PoolKey do not participate in routing; routing is keyed by currency pair only.
contract UniswapV2Aggregator is BaseAggregatorHook {
    using StateLibrary for IPoolManager;
    using SafeERC20 for IERC20;
    using PoolIdLibrary for PoolKey;

    address public immutable factory;

    uint256 internal constant FEE = 3;
    uint256 internal constant FEE_DENOMINATOR = 1000;

    mapping(PoolId => address) public poolIdToExternalPair;
    mapping(address => PoolKey) private _canonicalPoolKeyByAddress;

    error NativeCurrencyNotSupported();
    error ExternalPoolNotFound();
    error ExternalPoolTokenMismatch();
    error Reentrancy();
    error UnexpectedSwapOutputDelta();
    error AmountInZero();
    error AmountOutZero();
    error InsufficientLiquidity();
    error PairAlreadyHasCanonicalPool(PoolId existingPoolId);
    error CallerNotV2Pair();
    error SenderNotSelf();

    struct FlashCallbackData {
        address pairAddr;
        Currency takeCurrency;
        Currency settleCurrency;
        uint256 amountIn;
    }

    constructor(IPoolManager manager, address factory_, string memory hookVersion)
        BaseAggregatorHook(manager, hookVersion)
    {
        factory = factory_;
    }

    /// @inheritdoc BaseAggregatorHook
    function pseudoTotalValueLocked(PoolId poolId) external view override returns (uint256 amount0, uint256 amount1) {
        address pairAddr = poolIdToExternalPair[poolId];
        if (pairAddr == address(0)) revert PoolDoesNotExist();
        PoolKey storage poolKey = _canonicalPoolKeyByAddress[pairAddr];
        amount0 = poolKey.currency0.balanceOf(pairAddr);
        amount1 = poolKey.currency1.balanceOf(pairAddr);
    }

    function _resolveExternalPool(address token0, address token1) internal view returns (address pool) {
        pool = IUniswapV2Factory(factory).getPair(token0, token1);
        if (pool == address(0)) revert ExternalPoolNotFound();
    }

    /// @inheritdoc BaseAggregatorHook
    function _rawQuote(bool zeroForOne, int256 amountSpecified, PoolId poolId)
        internal
        view
        override
        returns (uint256 amountUnspecified)
    {
        address pairAddr = poolIdToExternalPair[poolId];
        if (pairAddr == address(0)) revert PoolDoesNotExist();

        (uint112 reserve0, uint112 reserve1,) = IUniswapV2Pair(pairAddr).getReserves();
        (uint256 reserveIn, uint256 reserveOut) =
            zeroForOne ? (uint256(reserve0), uint256(reserve1)) : (uint256(reserve1), uint256(reserve0));

        if (amountSpecified < 0) {
            uint256 amtIn = uint256(-amountSpecified);
            amountUnspecified = getAmountOut(amtIn, reserveIn, reserveOut);
        } else {
            uint256 amtOut = uint256(amountSpecified);
            amountUnspecified = getAmountIn(amtOut, reserveIn, reserveOut);
        }
    }

    function _beforeInitialize(address, PoolKey calldata key, uint160) internal virtual override returns (bytes4) {
        if (key.currency0.isAddressZero() || key.currency1.isAddressZero()) revert NativeCurrencyNotSupported();

        address token0 = Currency.unwrap(key.currency0);
        address token1 = Currency.unwrap(key.currency1);

        address pairAddr = _resolveExternalPool(token0, token1);

        if (IUniswapV2Pair(pairAddr).token0() != token0 || IUniswapV2Pair(pairAddr).token1() != token1) {
            revert ExternalPoolTokenMismatch();
        }

        PoolKey storage existing = _canonicalPoolKeyByAddress[pairAddr];
        if (address(existing.hooks) != address(0)) {
            revert PairAlreadyHasCanonicalPool(existing.toId());
        }
        _canonicalPoolKeyByAddress[pairAddr] = key;

        poolIdToExternalPair[key.toId()] = pairAddr;

        emit AggregatorPoolRegistered(key.toId());
        pollTokenJar();
        return IHooks.beforeInitialize.selector;
    }

    /// @inheritdoc BaseAggregatorHook
    function _conductSwap(Currency settleCurrency, Currency takeCurrency, SwapParams calldata params, PoolId poolId)
        internal
        virtual
        override
        returns (uint256 amountSettle, uint256 amountTake, bool hasSettled)
    {
        if (settleCurrency.isAddressZero() || takeCurrency.isAddressZero()) revert NativeCurrencyNotSupported();

        address pairAddr = poolIdToExternalPair[poolId];
        if (pairAddr == address(0)) revert PoolDoesNotExist();

        if (params.amountSpecified < 0) {
            // Exact-in: existing path unchanged
            poolManager.sync(settleCurrency);
            (amountTake, amountSettle) = _swapOnPair(pairAddr, takeCurrency, settleCurrency, params);
            poolManager.settle();
        } else {
            // Exact-out: sync/settle happen inside uniswapV2Call
            (amountTake, amountSettle) = _flashSwapExactOut(pairAddr, takeCurrency, settleCurrency, params);
        }
        hasSettled = true;

        if (params.amountSpecified > 0 && uint256(params.amountSpecified) != amountSettle) {
            revert UnexpectedSwapOutputDelta();
        }
    }

    function getAmountOut(uint256 amountIn, uint256 reserveIn, uint256 reserveOut)
        internal
        pure
        returns (uint256 amountOut)
    {
        if (amountIn == 0) revert AmountInZero();
        if (reserveIn == 0 || reserveOut == 0) revert InsufficientLiquidity();
        uint256 amountInWithFee = amountIn * (FEE_DENOMINATOR - FEE);
        uint256 numerator = amountInWithFee * reserveOut;
        uint256 denominator = reserveIn * FEE_DENOMINATOR + amountInWithFee;
        amountOut = numerator / denominator;
    }

    function getAmountIn(uint256 amountOut, uint256 reserveIn, uint256 reserveOut)
        internal
        pure
        returns (uint256 amountIn)
    {
        if (amountOut == 0) revert AmountOutZero();
        if (reserveIn == 0 || reserveOut == 0 || amountOut > reserveOut) revert InsufficientLiquidity();
        uint256 numerator = reserveIn * amountOut * FEE_DENOMINATOR;
        uint256 denominator = (reserveOut - amountOut) * (FEE_DENOMINATOR - FEE);
        amountIn = numerator / denominator + 1;
    }

    /// @dev Executes exact-in Constant-Product swap on `pair`. Pulls input from PoolManager to `pair` via `take`; pair sends output to PoolManager.
    /// @return amountTakeUsed Input amount taken from PoolManager for the pair.
    /// @return amountSettle Output amount sent by the pair to PoolManager (must match `settle` after `sync`).
    function _swapOnPair(address pairAddr, Currency takeCurrency, Currency settleCurrency, SwapParams calldata params)
        private
        returns (uint256 amountTakeUsed, uint256 amountSettle)
    {
        bool zeroForOne = params.zeroForOne;

        uint256 amountOut;
        {
            (uint112 r0Before, uint112 r1Before,) = IUniswapV2Pair(pairAddr).getReserves();
            (uint256 reserveIn, uint256 reserveOut) =
                zeroForOne ? (uint256(r0Before), uint256(r1Before)) : (uint256(r1Before), uint256(r0Before));
            if (reserveIn == 0 || reserveOut == 0) revert ExternalPoolTokenMismatch();

            amountTakeUsed = uint256(-params.amountSpecified);
            // FoT: use amount that actually lands on the pair for the quote.
            uint256 balanceTakeBefore = takeCurrency.balanceOf(pairAddr);
            poolManager.take(takeCurrency, pairAddr, amountTakeUsed);
            uint256 balanceTakeAfter = takeCurrency.balanceOf(pairAddr);
            uint256 amountArrived = balanceTakeAfter - balanceTakeBefore;
            amountOut = getAmountOut(amountArrived, reserveIn, reserveOut);
        }

        uint256 amount0Out;
        uint256 amount1Out;
        if (zeroForOne) {
            amount1Out = amountOut;
        } else {
            amount0Out = amountOut;
        }
        uint256 balanceSettleBefore = settleCurrency.balanceOf(address(poolManager));
        IUniswapV2Pair(pairAddr).swap(amount0Out, amount1Out, address(poolManager), "");
        uint256 balanceSettleAfter = settleCurrency.balanceOf(address(poolManager));

        amountSettle = balanceSettleAfter - balanceSettleBefore;
    }

    /// @dev Executes exact-out Constant-Product swap on `pair` via V2 flash-swap inversion: pair sends output to this hook
    /// optimistically, then `uniswapV2Call` settles the output into PoolManager and `take`s the input from PoolManager to
    /// repay the pair. Required for lazy-settlement exact-out routing where PoolManager may not yet hold the input token.
    /// @return amountTakeUsed Input amount taken from PoolManager to repay the pair.
    /// @return amountSettle Output amount delivered to PoolManager (must equal `params.amountSpecified`).
    function _flashSwapExactOut(
        address pairAddr,
        Currency takeCurrency,
        Currency settleCurrency,
        SwapParams calldata params
    ) private returns (uint256 amountTakeUsed, uint256 amountSettle) {
        uint256 amountOut = uint256(params.amountSpecified);
        {
            (uint112 r0, uint112 r1,) = IUniswapV2Pair(pairAddr).getReserves();
            (uint256 reserveIn, uint256 reserveOut) =
                params.zeroForOne ? (uint256(r0), uint256(r1)) : (uint256(r1), uint256(r0));
            amountTakeUsed = getAmountIn(amountOut, reserveIn, reserveOut);
        }

        uint256 pmBalBefore = settleCurrency.balanceOf(address(poolManager));

        IUniswapV2Pair(pairAddr)
            .swap(
                params.zeroForOne ? 0 : amountOut,
                params.zeroForOne ? amountOut : 0,
                address(this),
                abi.encode(
                    FlashCallbackData({
                        pairAddr: pairAddr,
                        takeCurrency: takeCurrency,
                        settleCurrency: settleCurrency,
                        amountIn: amountTakeUsed
                    })
                )
            );
        amountSettle = settleCurrency.balanceOf(address(poolManager)) - pmBalBefore;
    }

    /// @notice Uniswap V2 flash-swap callback. Invoked by the pair after it has optimistically transferred the output
    ///         token to this hook in an exact-out flow. Settles the output into PoolManager and repays the pair with
    ///         the input token taken from PoolManager.
    /// @dev Auth checks are load-bearing: only the encoded pair may invoke this, and only when this hook initiated the
    ///      flash swap (sender == self). Otherwise an attacker could drain PoolManager via `take`.
    function uniswapV2Call(address sender, uint256 amount0, uint256 amount1, bytes calldata data) external {
        FlashCallbackData memory cb = abi.decode(data, (FlashCallbackData));
        if (msg.sender != cb.pairAddr) revert CallerNotV2Pair();
        if (sender != address(this)) revert SenderNotSelf();

        // 1. Settle V2's output into PM
        poolManager.sync(cb.settleCurrency);
        uint256 received = amount0 > 0 ? amount0 : amount1;
        IERC20(Currency.unwrap(cb.settleCurrency)).safeTransfer(address(poolManager), received);
        poolManager.settle();

        // 2. Repay V2 from PM
        poolManager.take(cb.takeCurrency, msg.sender, cb.amountIn);
    }
}
