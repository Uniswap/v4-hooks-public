// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import {IStableStableHook} from "./interfaces/IStableStableHook.sol";
import {FeeConfiguration} from "./base/FeeConfiguration.sol";
import {BaseHook} from "../base/BaseHook.sol";
import {StableLibrary} from "./libraries/StableLibrary.sol";
import {FeeConfig, FeeState} from "./interfaces/IFeeConfiguration.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";

/// @title StableStableHook
/// @notice Dynamic fee hook for stable/stable pools
contract StableStableHook is FeeConfiguration, BaseHook, Ownable, IStableStableHook {
    using LPFeeLibrary for uint24;
    using PoolIdLibrary for PoolKey;

    /// @notice Divide by this to convert fees from the internal 1e12 precision format to the Uniswap 1e6 precision format
    uint256 private constant TO_UNISWAP_FEE = 1e6;

    constructor(IPoolManager _manager, address _owner, address _configManager)
        FeeConfiguration(_configManager)
        Ownable(_owner)
        BaseHook(_manager)
    {}

    /// @inheritdoc IStableStableHook
    function initializePool(PoolKey calldata poolKey, uint160 sqrtPriceX96, FeeConfig calldata feeConfiguration)
        external
        onlyOwner
        returns (int24 tick)
    {
        if (!poolKey.fee.isDynamicFee()) {
            revert MustUseDynamicFee(poolKey.fee);
        }
        if (poolKey.hooks != IHooks(address(this))) {
            revert InvalidHookAddress(address(poolKey.hooks));
        }
        _updateFeeConfig(poolKey.toId(), feeConfiguration);
        tick = poolManager.initialize(poolKey, sqrtPriceX96);
        emit PoolInitialized(poolKey, sqrtPriceX96, feeConfiguration);
    }

    /// @inheritdoc BaseHook
    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: true,
            afterInitialize: false,
            beforeAddLiquidity: false,
            beforeRemoveLiquidity: false,
            afterAddLiquidity: false,
            afterRemoveLiquidity: false,
            beforeSwap: true,
            afterSwap: false,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: false,
            afterSwapReturnDelta: false,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    function _beforeInitialize(address sender, PoolKey calldata, uint160) internal pure override returns (bytes4) {
        // Since hooks cannot call themselves, this function is only called when another address tries to initialize a pool with this contract as the hook
        // Therefore this function always reverts to ensure only this contract can initialize new pools
        revert InvalidInitializer(sender);
    }

    function _beforeSwap(address, PoolKey calldata key, SwapParams calldata params, bytes calldata)
        internal
        override
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        PoolId poolId = key.toId();
        FeeConfig storage feeConfig_ = feeConfig[poolId];
        FeeState storage feeState_ = feeState[poolId];
        unchecked {

            uint160 sqrtAmmPriceX96 = uint160(_getSqrtPriceX96(poolId));
            uint160 referenceSqrtPriceX96 = uint160(feeConfig_.referenceSqrtPriceX96);

            bool userSellsZeroForOne = params.zeroForOne;
            bool ammPriceToTheLeft = (sqrtAmmPriceX96 < referenceSqrtPriceX96);

            int256 closeFee;
            uint256 farFee;
            bool insideOptimalSpread;
            uint256 insideOptimalSpreadFee;

            {
                uint256 optimalFeeRate = feeConfig_.optimalFeeRate;
                uint256 ratio = ammPriceToTheLeft
                    ? (uint256(sqrtAmmPriceX96) * 2 ** 48) / referenceSqrtPriceX96
                    : (uint256(referenceSqrtPriceX96) * 2 ** 48) / sqrtAmmPriceX96;
                ratio = ratio * ratio;
                /*
                if ammPriceToTheLeft then (as if userSellsZeroForOne = false, 'buy' deal increases prices)
                      ratio = ammPrice/RP <= 1
                ammPrice / (1 - closeFee) = (1 - optimalFeeSpread) * RP    (lowerBound price)
                closeFee = 1 - ammPrice/RP / (1 - optimalFeeSpread) = 1 - ratio / (1 - optimalFeeSpread)

                ammPrice / (1 - farFee) = RP / (1 - optimalFeeSpread)      (upperBound price)
                farFee = 1 - ammPrice/RP * (1 - optimalFeeSpread) = 1 - (1 - optimalFeeSpread) * ratio
                if !ammPriceToTheLeft then (as if userSellsZeroForOne = true, 'sell' deal decreases prices)
                      ratio = RP / ammPrice <= 1
                ammPrice * (1 - closeFee) = RP / (1 - optimalFeeSpread)    (upperBound price)
                ammPrice * (1 - farFee) = (1 - optimalFeeSpread) * RP      (lowerBound price)
                      ... still same formulas w.r.t. ratio:
                      closeFee = 1 - ratio / (1 - optimalFeeSpread)
                      farFee = 1 - (1 - optimalFeeSpread) * ratio
                */

                closeFee = int256(ONE) - int256((ONE * ratio * 1_000_000) / (1_000_000 - optimalFeeRate) / 2 ** 96);
                insideOptimalSpread = (closeFee <= 0);

                if (insideOptimalSpread) {
                    /*
                        if userSellsZeroForOne => sellPrice = (1 - optimalFeeSpread) * RP
                        ammPrice * (1 - fee) = (1 - optimalFeeSpread) * RP
                        fee = 1 - (1 - optimalFeeSpread) * RP / ammPrice

                        if !userSellsZeroForOne => buyPrice = RP / (1 - optimalFeeSpread)
                        ammPrice / (1 - fee) = RP / (1 - optimalFeeSpread)
                        fee = 1 - (1 - optimalFeeSpread) * ammPrice / RP
                    */
                    insideOptimalSpreadFee = ammPriceToTheLeft == userSellsZeroForOne
                        ? ONE - (ONE * (1_000_000 - optimalFeeRate) * 2 ** 96) / ratio / 1_000_000
                        : ONE - (ONE * (1_000_000 - optimalFeeRate) * ratio) / 2 ** 96 / 1_000_000;
                } else {
                    farFee = ONE - (ONE * (1_000_000 - optimalFeeRate) * ratio) / 2 ** 96 / 1_000_000;
                }
            }

            uint256 totalStableFee;
            {
                uint256 flexibleFee;
                if (insideOptimalSpread) {
                    totalStableFee = insideOptimalSpreadFee;
                    flexibleFee = UNDEFINED_FLEXIBLE_FEE;
                } else {
                    // Outside the optimal spread, from this point on 0 < closeFee < farFee, both fees are
                    // less than ONE, recalculate flexibleFee first
                    uint256 previousSqrtAmmPriceX96 = feeState_.previousSqrtAmmPriceX96;
                    uint256 previousFee = feeState_.previousFee;
                    // adjust previousFee if needed
                    if (
                        previousFee == UNDEFINED_FLEXIBLE_FEE
                            || (ammPriceToTheLeft != (previousSqrtAmmPriceX96 < referenceSqrtPriceX96))
                    ) {
                        // The AMM price has just left the optimal spread or it has jumped over it.
                        // Use the far border of the optimal spread as previousFee.
                        previousFee = farFee;
                    } else if (ammPriceToTheLeft == (sqrtAmmPriceX96 < previousSqrtAmmPriceX96)) {
                        // Adjust previousFee according to the price change (so that it would be w.r.t. sqrtAmmPrice,
                        // not w.r.t. previousSqrtAmmPrice).
                        // we want to use previous flexible fee *including* its price impact,
                        // so we do not need to adjust previousFee if the previous swap was at flexible fee
                        // AMM price moved further from the RP hence previous swap was at zero fee (AMM side)
                        uint256 ratio = ammPriceToTheLeft
                            ? (uint256(sqrtAmmPriceX96) * 2 ** 48) / previousSqrtAmmPriceX96
                            : (previousSqrtAmmPriceX96 * 2 ** 48) / sqrtAmmPriceX96;
                        ratio = ratio * ratio;
                        previousFee = ONE - (ratio * (ONE - previousFee)) / 2 ** 96;
                    } else if (previousFee > farFee) {
                        // The AMM price has just left the optimal spread or it has jumped over it.
                        // Use the far border of the optimal spread as previousFee.
                        previousFee = farFee;
                    }

                    // always > 0 since farFee > closeFee
                    uint256 targetFee = farFee - uint256(closeFee) / 2;
                    if (previousFee <= targetFee) {
                        // This case is impossible to reach via just swaps due to price impact recalculation above.
                        flexibleFee = targetFee;
                    } else {
                        // This case is possible to reach via just swaps.
                        uint256 blocksPassed = block.number - feeState_.blockNumber;
                        uint256 factorX24;
                        if (blocksPassed <= 4) {
                            factorX24 = StableLibrary.fastPow(feeConfig_.k, blocksPassed);
                        } else {
                            int256 exponent = -int256(uint256(feeConfig_.logK) << 40) * int256(blocksPassed);
                            factorX24 = (uint256(FixedPointMathLib.expWad(exponent)) << 24) / 1e18;
                        }
                        flexibleFee = targetFee + ((factorX24 * (previousFee - targetFee)) >> 24);
                    }
                    // Return the fee but in any event not greater than 99%
                    totalStableFee = (ammPriceToTheLeft == userSellsZeroForOne) ? 0 : flexibleFee;
                }

                feeState_.previousFee = flexibleFee;
                feeState_.previousSqrtAmmPriceX96 = sqrtAmmPriceX96;
                feeState_.blockNumber = block.number;
            }

            totalStableFee /= TO_UNISWAP_FEE;
            if (totalStableFee > 990_000) {
                totalStableFee = 990_000;
            }

            return (
                IHooks.beforeSwap.selector,
                BeforeSwapDeltaLibrary.ZERO_DELTA,
                uint24(totalStableFee) | LPFeeLibrary.OVERRIDE_FEE_FLAG
            );
        }
    }

    function _getSqrtPriceX96(PoolId _poolId) internal view returns (uint256) {
        (uint160 price,,,) = StateLibrary.getSlot0(poolManager, _poolId);
        return price;
    }
}
