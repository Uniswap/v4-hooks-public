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
import {ICurveStableSwap} from "./interfaces/IStableSwap.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @title StableSwapAggregator
/// @notice Uniswap V4 hook that aggregates liquidity from Curve StableSwap pools
/// @dev Supports exact-input swaps only due to StableSwap pool limitations
contract StableSwapAggregator is ExternalLiqSourceHook {
    using StateLibrary for IPoolManager;
    using SafeERC20 for IERC20;

    /// @notice The Curve StableSwap pool
    ICurveStableSwap public pool;

    struct PoolInfo {
        int128 token0Index;
        int128 token1Index;
    }

    /// @notice Maps Uniswap V4 pool IDs to their corresponding token indices in the Curve pool
    mapping(PoolId => PoolInfo) public poolIdToTokenInfo;

    error TokenNotInPool(address token);
    error TokensNotInPool(address token0, address token1);
    error ExactOutputNotSupported();

    constructor(IPoolManager _manager, ICurveStableSwap _pool) ExternalLiqSourceHook(_manager) {
        pool = _pool;
    }

    /// @inheritdoc ExternalLiqSourceHook
    function quote(bool zeroToOne, int256 amountSpecified, PoolId poolId)
        external
        payable
        override
        returns (uint256 amountUnspecified)
    {
        if (amountSpecified >= 0) revert ExactOutputNotSupported();
        PoolInfo storage poolInfo = poolIdToTokenInfo[poolId];
        if (zeroToOne) {
            amountUnspecified = pool.get_dy(poolInfo.token0Index, poolInfo.token1Index, uint256(-amountSpecified));
        } else {
            amountUnspecified = pool.get_dy(poolInfo.token1Index, poolInfo.token0Index, uint256(-amountSpecified));
        }
    }

    /// @inheritdoc ExternalLiqSourceHook
    function pseudoTotalValueLocked(PoolId poolId) external view override returns (uint256 amount0, uint256 amount1) {
        PoolInfo memory poolInfo = poolIdToTokenInfo[poolId];
        amount0 = pool.balances(uint256(uint128(poolInfo.token0Index)));
        amount1 = pool.balances(uint256(uint128(poolInfo.token1Index)));
    }

    function _beforeInitialize(address, PoolKey calldata key, uint160) internal override returns (bytes4) {
        // Find token indices by iterating through pool coins (max 8 coins in Curve pools)
        bool token0Found = false;
        bool token1Found = false;
        int128 token0Index;
        int128 token1Index;

        for (int128 i = 0; i < 8; i++) {
            // Try to get coin at index i, break if it reverts (end of coins)
            try pool.coins(uint256(uint128(i))) returns (address coin) {
                if (coin == address(0)) break;
                if (coin == Currency.unwrap(key.currency0)) {
                    token0Index = i;
                    token0Found = true;
                }
                if (coin == Currency.unwrap(key.currency1)) {
                    token1Index = i;
                    token1Found = true;
                }
                // If both found, we can stop early
                if (token0Found && token1Found) break;
            } catch {
                // No more coins in pool
                break;
            }
        }

        if (!token0Found && !token1Found) {
            revert TokensNotInPool(Currency.unwrap(key.currency0), Currency.unwrap(key.currency1));
        }
        if (!token0Found) {
            revert TokenNotInPool(Currency.unwrap(key.currency0));
        }
        if (!token1Found) {
            revert TokenNotInPool(Currency.unwrap(key.currency1));
        }

        poolIdToTokenInfo[key.toId()] = PoolInfo({token0Index: token0Index, token1Index: token1Index});

        IERC20(Currency.unwrap(key.currency0)).safeIncreaseAllowance(address(pool), type(uint256).max);
        IERC20(Currency.unwrap(key.currency1)).safeIncreaseAllowance(address(pool), type(uint256).max);

        emit AggregatorPoolRegistered(key.toId());
        return IHooks.beforeInitialize.selector;
    }

    function _conductSwap(Currency, Currency takeCurrency, SwapParams calldata params, PoolId poolId)
        internal
        override
        returns (uint256 amountSettle, uint256 amountTake, bool hasSettled)
    {
        PoolInfo storage poolInfo = poolIdToTokenInfo[poolId];
        int128 tokenInIndex;
        int128 tokenOutIndex;
        if (params.zeroForOne) {
            tokenInIndex = poolInfo.token0Index;
            tokenOutIndex = poolInfo.token1Index;
        } else {
            tokenInIndex = poolInfo.token1Index;
            tokenOutIndex = poolInfo.token0Index;
        }

        if (params.amountSpecified < 0) {
            // Exact-In
            amountTake = uint256(-params.amountSpecified);
        } else {
            // Exact-Out: StableSwap pools don't have get_dx, so exact output is not supported
            revert ExactOutputNotSupported();
        }

        poolManager.take(takeCurrency, address(this), amountTake);

        amountSettle = pool.exchange(tokenInIndex, tokenOutIndex, amountTake, 0);

        hasSettled = false;
        return (amountSettle, amountTake, hasSettled);
    }
}
