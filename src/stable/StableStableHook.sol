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
/// @custom:security-contact security@uniswap.org
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
        uint256 sqrtReferencePriceX96 = config.referenceSqrtPriceX96;
        uint256 optimalFeeE6 = config.optimalFeeE6;

        // Calculate the price ratio in x96 format between the current sqrt price and the reference sqrt price, always <= 2^96
        uint256 priceRatioX96 = FeeCalculation.calculatePriceRatioX96(sqrtAmmPriceX96, sqrtReferencePriceX96);

        // The optimalFee creates a price range (the "optimal spread") around the reference price:
        //   - Lower bound: RP * (1 - optimalFee)
        //   - Upper bound: RP / (1 - optimalFee)

        // closeFeeE12 represents the fee to reach whichever boundary is closer to the current AMM price.
        //   - If closeFeeE12 <= 0: AMM price is inside the optimal range (past the close boundary)
        //   - If closeFeeE12 > 0: AMM price is outside the optimal range (hasn't reached the close boundary)
        int256 closeFeeE12 = FeeCalculation.calculateCloseFee(priceRatioX96, optimalFeeE6);

        bool userSellsZeroForOne = params.zeroForOne;
        bool ammPriceToTheLeft = sqrtAmmPriceX96 < sqrtReferencePriceX96;
        uint256 totalStableFeeE12; // the fee to be charged to the swapper in 1e12 precision
        uint256 flexibleFeeE12;

        if (closeFeeE12 <= 0) {
            // Inside optimal range: The fee is calculated such that all swappers face consistent buy/sell prices:
            //   - All buys happen at the lower bound
            //   - All sells happen at the upper bound
            totalStableFeeE12 = FeeCalculation.calculateInsideOptimalRangeFee(
                priceRatioX96, optimalFeeE6, ammPriceToTheLeft, userSellsZeroForOne
            );
            flexibleFeeE12 = FeeCalculation.UNDEFINED_FLEXIBLE_FEE_E12; // No flexible fee inside optimal range
        } else {
            // Outside optimal range: The fee is calculated such that the fee decays exponentially toward a target fee
            // farFee represents the fee to reach whichever boundary is farther from the current AMM price.
            uint256 farFeeE12 = FeeCalculation.calculateFarFee(priceRatioX96, optimalFeeE6);

            // closeFeeE12 is positive since we are outside the optimal range
            flexibleFeeE12 = _calculateFlexibleFee(
                config,
                feeState,
                sqrtAmmPriceX96,
                sqrtReferencePriceX96,
                uint256(closeFeeE12),
                farFeeE12,
                ammPriceToTheLeft
            );

            // Select which fee to charge based on swap direction
            totalStableFeeE12 = (ammPriceToTheLeft == userSellsZeroForOne) ? 0 : flexibleFeeE12;
        }

        // Update historical data for next swap's calculations
        feeState.previousFeeE12 = uint40(flexibleFeeE12);
        feeState.previousSqrtAmmPriceX96 = uint160(sqrtAmmPriceX96);
        feeState.blockNumber = uint40(_getBlockNumberish());

        // Convert to Uniswap fee format (1e12 / 1e6 = 1e6)
        uint24 uniswapFeeE6 = uint24(totalStableFeeE12 / FeeCalculation.ONE_E6);

        return
            (
                IHooks.beforeSwap.selector,
                BeforeSwapDeltaLibrary.ZERO_DELTA,
                uniswapFeeE6 | LPFeeLibrary.OVERRIDE_FEE_FLAG
            );
    }

    /// @notice Calculate flexible fee when price is outside optimal range
    /// @param config The FeeConfig of the pool
    /// @param feeState The FeeState of the pool
    /// @param sqrtAmmPriceX96 The current AMM sqrt price
    /// @param sqrtReferencePriceX96 The reference sqrt price
    /// @param closeFeeE12 The fee to reach the close boundary, > 0 since we are outside the optimal range
    /// @param farFeeE12 The fee to reach the far boundary
    /// @param ammPriceToTheLeft True if current AMM price < reference price
    /// @return flexibleFeeE12 The calculated flexible fee in 1e12 precision
    function _calculateFlexibleFee(
        FeeConfig storage config,
        FeeState storage feeState,
        uint256 sqrtAmmPriceX96,
        uint256 sqrtReferencePriceX96,
        uint256 closeFeeE12,
        uint256 farFeeE12,
        bool ammPriceToTheLeft
    ) private view returns (uint256 flexibleFeeE12) {
        uint256 previousSqrtAmmPriceX96 = feeState.previousSqrtAmmPriceX96;
        uint256 previousFeeE12 = feeState.previousFeeE12;

        // Step 1: Determine if previous fee needs to be reset
        if (
            previousFeeE12 == FeeCalculation.UNDEFINED_FLEXIBLE_FEE_E12
                || (previousSqrtAmmPriceX96 < sqrtReferencePriceX96) != ammPriceToTheLeft
        ) {
            // Price just left optimal spread or jumped across reference
            // Start from far boundary
            previousFeeE12 = farFeeE12;
        } else if (ammPriceToTheLeft == (sqrtAmmPriceX96 < previousSqrtAmmPriceX96)) {
            // Price moved further from reference
            // Adjust previous fee to account for price movement
            uint256 priceRatioX96 = FeeCalculation.calculatePriceRatioX96(sqrtAmmPriceX96, previousSqrtAmmPriceX96); // price impact
            previousFeeE12 = FeeCalculation.adjustPreviousFeeForPriceMovement(priceRatioX96, previousFeeE12);
        } else if (previousFeeE12 > farFeeE12) {
            // Price jumped back toward reference but still outside spread
            // Cap at far boundary
            previousFeeE12 = farFeeE12;
        }

        // Step 2: Calculate target fee
        // Target fee is farFee reduced by half the closeFee.
        // The further outside the optimal range (larger closeFee), the more the target drops below farFee.
        uint256 targetFeeE12 = farFeeE12 - closeFeeE12 / 2;

        // Step 3: Apply exponential decay toward target
        flexibleFeeE12 = FeeCalculation.calculateFlexibleFee(
            targetFeeE12, previousFeeE12, config.k, config.logK, _getBlockNumberish() - feeState.blockNumber
        );
    }
}
