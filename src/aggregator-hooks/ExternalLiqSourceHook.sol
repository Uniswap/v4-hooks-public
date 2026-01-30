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

abstract contract ExternalLiqSourceHook is BaseHook, DeltaResolver {
    using CurrencyLibrary for Currency;
    using PoolIdLibrary for PoolKey;
    using SafeERC20 for IERC20;
    using StateLibrary for IPoolManager;

    /// @notice If true, skips settlement (used by implementations on which settlement is part of the composed swap action)
    bool private skipSettle;

    /// @notice Maps pool IDs to their corresponding aggregated pool addresses
    mapping(PoolId => address) public poolIdToAggregatedPool;

    error InsufficientLiquidity();
    error UnspecifiedAmountExceeded();
    error PoolDoesNotExist();

    event AggregatorPoolRegistered(PoolId indexed poolId);

    /// @notice Initializes the hook with required dependencies
    /// @param _manager The Uniswap V4 PoolManager contract
    constructor(IPoolManager _manager) BaseHook(_manager) {}

    /// @notice Returns the permissions this hook requires
    /// @dev Enables beforeSwap, beforeSwapReturnDelta, and beforeInitialize
    /// @return permissions The hook permissions struct indicating which hooks are enabled
    function getHookPermissions() public pure override returns (Hooks.Permissions memory permissions) {
        permissions.beforeSwap = true;
        permissions.beforeSwapReturnDelta = true;
        permissions.beforeInitialize = true;
    }

    function _beforeInitialize(address, PoolKey calldata key, uint160) internal virtual override returns (bytes4) {
        emit AggregatorPoolRegistered(key.toId());
        return IHooks.beforeInitialize.selector;
    }

    /// @notice Quotes amount of unspecified side for a given amount of specified side
    /// @param zeroToOne Whether the swap is from token0 to token1 or from token1 to token0
    /// @param amountSpecified The amount of tokens in or out (negative for exact-in, positive for exact-out)
    /// @return amountUnspecified amount of unspecified side (always positive)
    /// @dev This function is meant to be called as a view function even though it is not one. This is because the swap
    /// might be simulated but not finalized
    function quote(bool zeroToOne, int256 amountSpecified, PoolId poolId)
        external
        payable
        virtual
        returns (uint256 amountUnspecified);

    /// @notice Returns the pseudo TVL: the amount of the UniswapV4 pool's tokens locked in the aggregated pool
    /// @param poolId The pool ID of the UniswapV4 pool
    /// @return amount0 The amount of token0 in the aggregated pool
    /// @return amount1 The amount of token1 in the aggregated pool
    function pseudoTotalValueLocked(PoolId poolId) external view virtual returns (uint256 amount0, uint256 amount1);

    /// @notice Hook called before each swap
    /// @dev Validates signatures, calculates custom pricing, and settles deltas
    /// @param key The pool key
    /// @param params The swap parameters
    /// @return Function selector, delta to apply, and LP fee
    function _beforeSwap(address, PoolKey calldata key, SwapParams calldata params, bytes calldata)
        internal
        override
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        (uint256 amountIn, uint256 amountOut) = _internalSettle(key, params);
        int128 unspecifiedDelta = _processAmounts(amountIn, amountOut, params.amountSpecified < 0);
        int128 specified = int128(-params.amountSpecified); // cancel core

        if (params.amountSpecified > 0) {
            // For exactOut, external liquidity sources can be off by a few wei.
            // NOTE: it is up to the router to handle this
            specified = -int128(uint128(amountOut));
        }

        return (IHooks.beforeSwap.selector, toBeforeSwapDelta(specified, unspecifiedDelta), 0);
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
        // Check if an overflow happened when casting to int128
        if (uint256(int256(unspecifiedDelta < 0 ? -unspecifiedDelta : unspecifiedDelta)) < unspecified) {
            revert UnspecifiedAmountExceeded();
        }
    }

    function _internalSettle(PoolKey calldata key, SwapParams calldata params)
        internal
        returns (uint256 amountIn, uint256 amountOut)
    {
        if (skipSettle) {
            return (0, 0);
        }
        Currency settleCurrency = params.zeroForOne ? key.currency1 : key.currency0;
        Currency takeCurrency = params.zeroForOne ? key.currency0 : key.currency1;

        (uint256 amountSettle, uint256 amountTake, bool hasSettled) =
            _conductSwap(settleCurrency, takeCurrency, params, key.toId());

        if (!hasSettled) {
            _settle(settleCurrency, address(this), amountSettle);
        }

        return (amountTake, amountSettle);
    }

    function _conductSwap(Currency settleCurrency, Currency takeCurrency, SwapParams calldata params, PoolId poolId)
        internal
        virtual
        returns (uint256 amountSettle, uint256 amountTake, bool hasSettled);

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
