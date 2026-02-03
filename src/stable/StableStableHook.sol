// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import {IStableStableHook} from "./interfaces/IStableStableHook.sol";
import {FeeConfiguration} from "./base/FeeConfiguration.sol";
import {BaseHook} from "../base/BaseHook.sol";
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
        // closeFee represents the fee to reach whichever boundary is closest to the current AMM price.
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
        } else {
            // closeFee represents the fee to reach whichever boundary is closest to the current AMM price.
            uint40 farFee = FeeCalculation.calculateFarFee(priceRatioX96, optimalFeeRate);

            flexibleFee = _calculateFlexibleFee(
                config, feeState, sqrtAmmPriceX96, sqrtReferencePriceX96, closeFee, farFee, ammPriceToTheLeft
            );

            // Select which fee to charge based on swap direction
            totalStableFee = (ammPriceToTheLeft == userSellsZeroForOne) ? 0 : flexibleFee;
        }

        // Update historical data for next swap's calculations
        feeState.previousFee = flexibleFee;
        feeState.previousSqrtAmmPriceX96 = sqrtAmmPriceX96;
        feeState.blockNumber = block.number;

        // Convert to Uniswap fee format (1e12 / 1e6 = 1e6)
        uint24 uniswapFee = uint24(totalStableFee / FeeCalculation.PPM);

        return
            (IHooks.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, uniswapFee | LPFeeLibrary.OVERRIDE_FEE_FLAG);
    }

    /// @notice Calculate flexible fee when price is outside optimal rate
    /// @param config The FeeConfig of the pool
    /// @param feeState The FeeState of the pool
    /// @param sqrtAmmPriceX96 The current AMM sqrt price
    /// @param sqrtReferencePriceX96 The reference sqrt price
    /// @param closeFee The fee to reach the close boundary
    /// @param farFee The fee to reach the far boundary
    /// @param ammPriceToTheLeft True if current AMM price < reference price
    /// @return flexibleFee The calculated flexible fee
    function _calculateFlexibleFee(
        FeeConfig storage config,
        FeeState storage feeState,
        uint160 sqrtAmmPriceX96,
        uint160 sqrtReferencePriceX96,
        int40 closeFee,
        uint40 farFee,
        bool ammPriceToTheLeft
    ) private view returns (uint40 flexibleFee) {
        uint160 previousSqrtAmmPriceX96 = feeState.previousSqrtAmmPriceX96;
        uint40 previousFee = feeState.previousFee;

        // Step 1: Determine if previous fee needs to be reset
        if (
            previousFee == FeeCalculation.UNDEFINED_FLEXIBLE_FEE
                || (previousSqrtAmmPriceX96 < sqrtReferencePriceX96) != ammPriceToTheLeft
        ) {
            // Price just left optimal spread or jumped across reference
            // Start from far boundary
            previousFee = farFee;
        } else if (ammPriceToTheLeft == (sqrtAmmPriceX96 < previousSqrtAmmPriceX96)) {
            // Price moved further from reference
            // Adjust previous fee to account for price movement
            uint160 priceRatioX96 = FeeCalculation.calculatePriceRatioX96(sqrtAmmPriceX96, previousSqrtAmmPriceX96); // price impact
            previousFee = FeeCalculation.adjustPreviousFeeForPriceMovement(priceRatioX96, previousFee);
        } else if (previousFee > farFee) {
            // Price jumped back toward reference but still outside spread
            // Cap at far boundary
            previousFee = farFee;
        }

        // Step 2: Calculate target fee
        uint40 targetFee = farFee - uint40(closeFee) / 2; // closeFee is positive since we are outside the optimal rate

        // Step 3: Apply exponential decay toward target
        if (previousFee <= targetFee) {
            // Already at or below target (shouldn't happen in normal operation)
            flexibleFee = targetFee;
        } else {
            // Apply decay: fee moves from previous toward target
            flexibleFee = FeeCalculation.calculateFlexibleFee(
                targetFee, previousFee, config.k, config.logK, block.number - feeState.blockNumber
            );
        }
    }
}
