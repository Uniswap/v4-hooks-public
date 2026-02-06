// SPDX-License-Identifier: MIT
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

        // The optimalFee defines a price range (the "optimal spread") in PRICE space (not sqrt price space).
        // Let RP = the actual reference price (i.e., sqrtReferencePriceX96² expressed as a price).
        // The optimal range bounds are:
        //   - Lower bound (price): RP * (1 - optimalFee)
        //   - Upper bound (price): RP / (1 - optimalFee)

        // closeBoundaryFeeE12 represents the fee to reach whichever boundary is closer to the current AMM price.
        //   - If closeBoundaryFeeE12 <= 0: AMM price is inside the optimal range (past the close boundary)
        //   - If closeBoundaryFeeE12 > 0: AMM price is outside the optimal range (hasn't reached the close boundary)
        int256 closeBoundaryFeeE12 = FeeCalculation.calculateCloseBoundaryFee(priceRatioX96, optimalFeeE6);

        bool userSellsZeroForOne = params.zeroForOne;
        bool ammPriceToTheLeft = sqrtAmmPriceX96 < sqrtReferencePriceX96;
        uint256 totalStableFeeE12; // the fee to be charged to the swapper in 1e12 precision
        uint256 decayingFeeE12;

        // closeBoundaryFee is the fee that would place the effective price at the close boundary.
        // A negative value means the AMM price is already inside the optimal range (past the close boundary).
        if (closeBoundaryFeeE12 <= 0) {
            // Inside optimal range: The fee is calculated such that all swappers face consistent buy/sell prices:
            //   - All buys happen at the lower bound
            //   - All sells happen at the upper bound
            totalStableFeeE12 = FeeCalculation.calculateInsideOptimalRangeFee(
                priceRatioX96, optimalFeeE6, ammPriceToTheLeft, userSellsZeroForOne
            );
            decayingFeeE12 = FeeCalculation.UNDEFINED_DECAYING_FEE_E12; // No decaying fee inside optimal range
        } else {
            // Outside optimal range: The fee is calculated such that the fee decays exponentially toward a target fee
            // farBoundaryFeeE12 represents the fee to reach whichever boundary is farther from the current AMM price.
            uint256 farBoundaryFeeE12 = FeeCalculation.calculateFarBoundaryFee(priceRatioX96, optimalFeeE6);

            // closeBoundaryFeeE12 is positive since we are outside the optimal range
            decayingFeeE12 = _calculateDecayingFee(
                config,
                feeState,
                sqrtAmmPriceX96,
                sqrtReferencePriceX96,
                uint256(closeBoundaryFeeE12),
                farBoundaryFeeE12,
                ammPriceToTheLeft
            );

            // Select which fee to charge based on swap direction
            // Price is moving further from reference: charge 0 fee. Otherwise, charge the decaying fee.
            totalStableFeeE12 = (ammPriceToTheLeft == userSellsZeroForOne) ? 0 : decayingFeeE12;
        }

        // Update historical data for next swap's calculations
        feeState.previousFeeE12 = uint40(decayingFeeE12);
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

    /// @notice Calculate decaying fee when price is outside optimal range
    /// @param config The FeeConfig of the pool
    /// @param feeState The FeeState of the pool
    /// @param sqrtAmmPriceX96 The current AMM sqrt price
    /// @param sqrtReferencePriceX96 The reference sqrt price
    /// @param closeBoundaryFeeE12 The fee to reach the close boundary of the optimal range (negative = already inside)
    /// @param farBoundaryFeeE12 The fee to reach the far boundary of the optimal range
    /// @param ammPriceToTheLeft True if current AMM price < reference price
    /// @return decayingFeeE12 The calculated decaying fee in 1e12 precision
    function _calculateDecayingFee(
        FeeConfig storage config,
        FeeState storage feeState,
        uint256 sqrtAmmPriceX96,
        uint256 sqrtReferencePriceX96,
        uint256 closeBoundaryFeeE12,
        uint256 farBoundaryFeeE12,
        bool ammPriceToTheLeft
    ) private view returns (uint256 decayingFeeE12) {
        uint256 previousSqrtAmmPriceX96 = feeState.previousSqrtAmmPriceX96;
        uint256 previousFeeE12 = feeState.previousFeeE12;
        uint256 previousBlockNumber = feeState.blockNumber;

        // Step 1: Determine if previous fee needs to be reset
        if (
            previousFeeE12 == FeeCalculation.UNDEFINED_DECAYING_FEE_E12
                || (previousSqrtAmmPriceX96 < sqrtReferencePriceX96) != ammPriceToTheLeft
        ) {
            // Price just left optimal range or jumped across reference
            // Start from far boundary
            previousFeeE12 = farBoundaryFeeE12;
        } else if (ammPriceToTheLeft == (sqrtAmmPriceX96 < previousSqrtAmmPriceX96)) {
            // Price moved further from reference (left of ref and moved more left, OR right of ref and moved more right)
            // Adjust fee upward to preserve the same effective price, then decay starts from this adjusted fee
            uint256 priceRatioX96 = FeeCalculation.calculatePriceRatioX96(sqrtAmmPriceX96, previousSqrtAmmPriceX96); // price impact
            previousFeeE12 = FeeCalculation.adjustPreviousFeeForPriceMovement(priceRatioX96, previousFeeE12);
        } else if (previousFeeE12 > farBoundaryFeeE12) {
            // Price moved toward reference, lowering farBoundaryFee below previousFee
            // Cap at the new far boundary
            previousFeeE12 = farBoundaryFeeE12;
        }

        // Step 2: Calculate target fee
        // Subtracting half the closeBoundaryFee is a design choice that controls how aggressively
        // the target fee drops below farBoundaryFee as price moves further from optimal range.
        uint256 targetFeeE12 = farBoundaryFeeE12 - closeBoundaryFeeE12 / 2;

        // Step 3: Apply exponential decay toward target
        decayingFeeE12 = FeeCalculation.calculateDecayingFee(
            targetFeeE12, previousFeeE12, config.k, config.logK, _getBlockNumberish() - previousBlockNumber
        );
    }
}
