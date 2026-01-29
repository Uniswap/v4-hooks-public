// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import {IStableStableHook} from "./interfaces/IStableStableHook.sol";
import {FeeConfiguration} from "./base/FeeConfiguration.sol";
import {BaseHook} from "../base/BaseHook.sol";
import {StableLibrary} from "./libraries/StableLibrary.sol";
import {FeeCalculation} from "./libraries/FeeCalculation.sol";
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

/// @title StableStableHook
/// @notice Dynamic fee hook for stable/stable pools
contract StableStableHook is FeeConfiguration, BaseHook, Ownable, IStableStableHook {
    using LPFeeLibrary for uint24;
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

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

    /// @notice Reject initialization of the pool by another address
    /// @param sender The address that attempted to initialize the pool (not address(this))
    function _beforeInitialize(address sender, PoolKey calldata, uint160) internal pure override returns (bytes4) {
        // Since hooks cannot call themselves, this function is only called when another address tries to initialize a pool with this contract as the hook
        // Therefore this function always reverts to ensure only this contract can initialize new pools
        revert InvalidInitializer(sender);
    }

    /// @notice Calculate and apply dynamic fee before each swap
    /// @param key The PoolKey of the pool
    /// @param params The SwapParams of the swap
    /// @return selector The function selector for IHooks.beforeSwap
    /// @return delta BeforeSwapDelta (always zero for this hook)
    /// @return lpFeeOverride The calculated dynamic fee with override flag
    function _beforeSwap(address, PoolKey calldata key, SwapParams calldata params, bytes calldata)
        internal
        override
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        PoolId poolId = key.toId();
        FeeConfig storage config = feeConfig[poolId];
        FeeState storage feeState = feeState[poolId];

        (uint160 sqrtAmmPriceX96,,,) = poolManager.getSlot0(poolId); // grab the current sqrt price of the pool
        uint160 sqrtReferencePriceX96 = config.referenceSqrtPriceX96;
        uint24 optimalFeeRate = config.optimalFeeRate;

        // Calculate the price ratio in x96 format between the current sqrt price and the reference sqrt price, always <= 2^96
        uint160 priceRatioX96 = FeeCalculation.calculatePriceRatioX96(sqrtAmmPriceX96, sqrtReferencePriceX96);

        // closeFee is a threshold test to determine if we're inside or outside the optimal rate.
        // The optimal rate has two boundaries around the reference price:
        //   - Lower bound: RP * (1 - optimalFeeRate)
        //   - Upper bound: RP / (1 - optimalFeeRate)
        //
        // closeFee represents the fee at whichever boundary is closest to the current AMM price.
        //   - If closeFee <= 0: AMM price is inside the optimal rate (past the close boundary)
        //   - If closeFee > 0: AMM price is outside the optimal rate (hasn't reached the close boundary)
        int40 closeFee = FeeCalculation.calculateCloseFee(priceRatioX96, optimalFeeRate);

        bool userSellsZeroForOne = params.zeroForOne;
        bool ammPriceToTheLeft = sqrtAmmPriceX96 < sqrtReferencePriceX96;
        uint40 totalStableFee; // the fee to be charged to the swapper in 1e12 precision
        uint40 flexibleFee;

        if (closeFee <= 0) {
            // Inside optimal rate: The fee is calculated such that all swappers face consistent buy/sell prices:
            //   - All buys happen at the lower bound
            //   - All sells happen at the upper bound
            totalStableFee = FeeCalculation.calculateInsideOptimalRateFee(
                priceRatioX96, optimalFeeRate, ammPriceToTheLeft, userSellsZeroForOne
            );
            flexibleFee = FeeCalculation.UNDEFINED_FLEXIBLE_FEE; // No flexible fee inside optimal fee rate
        }
        // else {
        //     // outside optimal rate
        //     // TODO
        // }

        // Update historical data for next swap's calculations
        feeState.previousFee = flexibleFee;
        feeState.previousSqrtAmmPriceX96 = sqrtAmmPriceX96;
        feeState.blockNumber = block.number;

        // Convert to Uniswap fee format
        uint24 uniswapFee = FeeCalculation.convertToUniswapFee(totalStableFee);

        return
            (IHooks.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, uniswapFee | LPFeeLibrary.OVERRIDE_FEE_FLAG);
    }
}
