// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {FixedPoint96} from "@uniswap/v4-core/src/libraries/FixedPoint96.sol";
import {SqrtPriceMath} from "@uniswap/v4-core/src/libraries/SqrtPriceMath.sol";
import {StableFeeCalculation} from "../../stable/libraries/StableFeeCalculation.sol";

/// @title IndexVaultMath
/// @notice IndexLpVault's pure valuation, position and range math
library IndexVaultMath {
    uint256 internal constant BPS = 10_000;

    /// @notice `amount` of stock in index-token wei at `sqrtPriceX96` (currency1 per currency0): × P when the stock is
    ///         currency0, ÷ P otherwise. Two mulDivs by 2^96 keep 18-decimal amounts clear of overflow up to
    ///         MAX_SQRT_PRICE; a 0 price (uninitialized pool) values the stock at 0.
    function stockToIndex(bool stockIsCurrency0, uint256 amount, uint160 sqrtPriceX96) internal pure returns (uint256) {
        if (amount == 0 || sqrtPriceX96 == 0) return 0;
        return stockIsCurrency0
            ? FullMath.mulDiv(FullMath.mulDiv(amount, sqrtPriceX96, FixedPoint96.Q96), sqrtPriceX96, FixedPoint96.Q96)
            : FullMath.mulDiv(FullMath.mulDiv(amount, FixedPoint96.Q96, sqrtPriceX96), FixedPoint96.Q96, sqrtPriceX96);
    }

    /// @notice LiquidityAmounts.getAmountsForLiquidity (v4-periphery's copy lacks it) on v4-core's round-down math, so
    ///         the amounts are exactly what a decrease of `liquidity` pays at `sqrtPriceX96`
    function amountsForLiquidity(uint160 sqrtPriceX96, uint160 sqrtPriceAX96, uint160 sqrtPriceBX96, uint128 liquidity)
        internal
        pure
        returns (uint256 amount0, uint256 amount1)
    {
        if (sqrtPriceX96 <= sqrtPriceAX96) {
            amount0 = SqrtPriceMath.getAmount0Delta(sqrtPriceAX96, sqrtPriceBX96, liquidity, false);
        } else if (sqrtPriceX96 < sqrtPriceBX96) {
            amount0 = SqrtPriceMath.getAmount0Delta(sqrtPriceX96, sqrtPriceBX96, liquidity, false);
            amount1 = SqrtPriceMath.getAmount1Delta(sqrtPriceAX96, sqrtPriceX96, liquidity, false);
        } else {
            amount1 = SqrtPriceMath.getAmount1Delta(sqrtPriceAX96, sqrtPriceBX96, liquidity, false);
        }
    }

    /// @notice 10000 × (halfWidth − distance to the nearer edge) / halfWidth, clamped to [0, 20000]; computed over the
    ///         whole width (identical for the even widths of tick-spaced ranges, and never a division by zero)
    function edgeProximityBps(int24 tick, int24 tickLower, int24 tickUpper) internal pure returns (uint16) {
        // ticks are int24, so none of this can overflow an int256
        unchecked {
            int256 width = int256(tickUpper) - tickLower;
            int256 below = int256(tick) - tickLower;
            int256 above = int256(tickUpper) - tick;
            int256 nearest = below < above ? below : above;
            int256 bps = 10_000 * (width - 2 * nearest) / width;
            return uint16(uint256(bps > 20_000 ? int256(20_000) : bps));
        }
    }

    /// @notice Whether the price at `sqrtPriceX96` is within `maxDeviationBps` of the reference price in either
    ///         direction: min/max of the two prices ≥ 1 − maxDeviationBps / 10000 (the hook's own ratio measure)
    function withinBand(uint160 sqrtPriceX96, uint160 referenceSqrtPriceX96, uint256 maxDeviationBps)
        internal
        pure
        returns (bool)
    {
        if (sqrtPriceX96 == 0 || referenceSqrtPriceX96 == 0) return false;
        return StableFeeCalculation.calculatePriceRatioX96(sqrtPriceX96, referenceSqrtPriceX96) * BPS
            >= FixedPoint96.Q96 * (BPS - maxDeviationBps);
    }
}
