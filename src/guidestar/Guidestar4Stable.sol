// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";

import {BalanceDelta, BalanceDeltaLibrary} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

import {BaseGuidestarHook} from "./BaseGuidestarHook.sol";
import {GuidestarLibrary} from "./libraries/GuidestarLibrary.sol";
import {ModifyLiquidityParams, SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";

/// @title Guidestar4Stable
/// @notice A hook for stable pairs that allows for dynamic fees
contract Guidestar4Stable is BaseGuidestarHook {
    using CurrencyLibrary for Currency;
    using PoolIdLibrary for PoolKey;

    error MustUseDynamicFee();

    /// @notice The maximum fee is 99%
    uint256 public constant MAX_FEE = 990_000;
    /// @notice Used for sqrt price ratio calculations
    uint256 internal constant Q48 = 2 ** 48;
    uint256 internal constant Q96 = 2 ** 96;
    uint256 internal constant FEE_PRECISION = 1e12;
    /// @notice Denominator in pips used for fee calculations
    uint256 internal constant FEE_DENOMINATOR = 1e6;
    uint256 internal constant UNDEFINED_FLEXIBLE_FEE = FEE_PRECISION + 1;
    uint256 internal constant TO_UNISWAP_FEE = FEE_PRECISION / 1e6;

    struct FeeData {
        uint256 previousFee;
        uint160 previousSqrtAmmPrice;
        uint256 blockNumber;
    }

    struct HookParams {
        uint256 k;
        uint256 logK;
        uint256 optimalFeeSpread; // optimal fee spread in pips (1e6 = 100%)
        uint160 referenceSqrtPrice;
    }

    struct PoolStorage {
        FeeData feeData;
        HookParams hookParams;
    }

    mapping(PoolId => PoolStorage) private poolStorage;

    constructor(IPoolManager _poolManager, address _initialOwner, address _gateway)
        BaseGuidestarHook(_poolManager, _initialOwner, _gateway)
    {}

    /// @notice Initializes a v4 pool and sets its fee data and hook params
    /// @param poolKey the poolKey of the pool to initialize
    /// @param sqrtPriceX96 the initial price of the pool to be set
    /// @param feeData_ the fee data for the poolKey
    /// @param hookParams_ the hook params for the poolKey
    /// @return tick the tick of the new initialized pool
    function initializePair(
        PoolKey calldata poolKey,
        uint160 sqrtPriceX96,
        FeeData memory feeData_,
        HookParams memory hookParams_
    ) external onlyOwner returns (int24 tick) {
        tick = poolManager.initialize(poolKey, sqrtPriceX96);
        PoolStorage storage poolStorage_ = _getStorage(poolKey);
        poolStorage_.feeData = feeData_;
        poolStorage_.hookParams = hookParams_;
    }

    /// @notice Gets the fee data for a given pool
    /// @param poolId The pool ID
    /// @return The fee data for the pool
    function feeData(PoolId poolId) external view returns (FeeData memory) {
        return poolStorage[poolId].feeData;
    }

    /// @notice Sets the fee data for a given pool
    /// @param poolKey The pool key
    /// @param feeData_ The fee data for the pool
    function setFeeData(PoolKey calldata poolKey, FeeData memory feeData_) external onlyOwner {
        poolStorage[poolKey.toId()].feeData = feeData_;
    }

    /// @notice Gets the hook params for a given pool
    /// @param poolId The pool ID
    /// @return The hook params for the pool
    function hookParams(PoolId poolId) external view returns (HookParams memory) {
        return poolStorage[poolId].hookParams;
    }

    /// @notice Sets the hook params for a given pool
    /// @param poolKey The pool key
    /// @param hookParams_ The hook params for the pool
    function setHookParams(PoolKey calldata poolKey, HookParams memory hookParams_) external onlyOwner {
        poolStorage[poolKey.toId()].hookParams = hookParams_;
    }

    /// @notice Sets the reference sqrt price for a given pool
    /// @param poolKey The pool key
    /// @param referenceSqrtPrice_ The reference sqrt price for the pool
    function setReferenceSqrtPrice(PoolKey calldata poolKey, uint160 referenceSqrtPrice_) external onlyOwner {
        PoolStorage storage poolStorage_ = _getStorage(poolKey);
        poolStorage_.hookParams.referenceSqrtPrice = referenceSqrtPrice_;
        poolStorage_.feeData.previousFee = UNDEFINED_FLEXIBLE_FEE;
        poolStorage_.feeData.blockNumber = block.number;
    }

    /// @notice Sets the optimal fee spread for a given pool
    /// @param poolKey The pool key
    /// @param optimalFeeSpread_ The optimal fee spread for the pool in pips
    function setOptimalFeeSpread(PoolKey calldata poolKey, uint24 optimalFeeSpread_) external onlyOwner {
        PoolStorage storage poolStorage_ = _getStorage(poolKey);
        poolStorage_.hookParams.optimalFeeSpread = optimalFeeSpread_;
        poolStorage_.feeData.previousFee = UNDEFINED_FLEXIBLE_FEE;
        poolStorage_.feeData.blockNumber = block.number;
    }

    /// @notice Before initialize hook
    /// @dev Checks that the pool is using a dynamic fee
    /// @param poolKey The pool key
    /// @return The selector for the before initialize hook
    function beforeInitialize(address, PoolKey calldata poolKey, uint160) external view onlyByGateway returns (bytes4) {
        if (!LPFeeLibrary.isDynamicFee(poolKey.fee)) {
            revert MustUseDynamicFee();
        }
        return Guidestar4Stable.beforeInitialize.selector;
    }

    /// @notice Before swap hook
    /// @dev Calculates the fee for the swap
    /// @param poolKey The pool key
    /// @param params The swap parameters
    /// @return The selector for the before swap hook
    /// @return The delta for the swap (always 0)
    /// @return The fee for the swap
    function beforeSwap(address, PoolKey calldata poolKey, SwapParams calldata params, bytes calldata)
        external
        onlyByGateway
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        PoolId poolId = poolKey.toId();
        PoolStorage storage poolStorage_ = poolStorage[poolId];
        unchecked {
            FeeData storage feeData_ = poolStorage_.feeData;

            // Get the current sqrt price of the pool
            uint160 sqrtAmmPrice = uint160(_getSqrtPriceX96(poolId));
            // Get the reference sqrt price of the pool
            uint160 referenceSqrtPrice_ = uint160(poolStorage_.hookParams.referenceSqrtPrice);

            // Whether the user is selling zero for one or not
            bool userSellsZeroForOne = params.zeroForOne;
            // Whether the AMM price is less than the ideal reference sqrt price or not
            bool ammPriceToTheLeft = (sqrtAmmPrice < referenceSqrtPrice_);

            int256 closeFee;
            uint256 farFee; // fee when its outside the optimal spread
            bool insideOptimalSpread; // true if price is within optimal spread
            uint256 insideOptimalSpreadFee; // fee when its within the optimal spread

            {
                uint256 optimalFeeSpread_ = poolStorage_.hookParams.optimalFeeSpread; // grab optimal fee spread
                // multiply by 2 ** 48 to maintain 48 bits of precision
                uint256 ratio = ammPriceToTheLeft
                    ? (uint256(sqrtAmmPrice) * Q48) / referenceSqrtPrice_
                    : (uint256(referenceSqrtPrice_) * Q48) / sqrtAmmPrice;
                // square the sqrt ratio of 48 bits to get actual price ratio in 96 bits
                ratio = ratio * ratio;

                closeFee = int256(FEE_PRECISION)
                    - int256((FEE_PRECISION * ratio * FEE_DENOMINATOR) / (FEE_DENOMINATOR - optimalFeeSpread_) / Q96);
                insideOptimalSpread = (closeFee <= 0);

                if (insideOptimalSpread) {
                    insideOptimalSpreadFee = ammPriceToTheLeft == userSellsZeroForOne
                        ? FEE_PRECISION - (FEE_PRECISION * (FEE_DENOMINATOR - optimalFeeSpread_) * Q96) / ratio
                            / FEE_DENOMINATOR
                        : FEE_PRECISION - (FEE_PRECISION * (FEE_DENOMINATOR - optimalFeeSpread_) * ratio) / Q96
                            / FEE_DENOMINATOR;
                } else {
                    farFee = FEE_PRECISION - (FEE_PRECISION * (FEE_DENOMINATOR - optimalFeeSpread_) * ratio) / Q96
                        / FEE_DENOMINATOR;
                }
            }

            uint256 totalStableFee;
            {
                uint256 flexibleFee;
                // if price is within optimal spread, set fee to insideOptimalSpreadFee
                if (insideOptimalSpread) {
                    totalStableFee = insideOptimalSpreadFee;
                    flexibleFee = UNDEFINED_FLEXIBLE_FEE;
                } else {
                    // if price is outside optimal spread, calculate the flexible fee
                    uint256 previousSqrtAmmPrice = feeData_.previousSqrtAmmPrice;
                    uint256 previousFee = feeData_.previousFee;

                    if (
                        previousFee == UNDEFINED_FLEXIBLE_FEE
                            || (ammPriceToTheLeft != (previousSqrtAmmPrice < referenceSqrtPrice_))
                    ) {
                        previousFee = farFee;
                    } else if (ammPriceToTheLeft == (sqrtAmmPrice < previousSqrtAmmPrice)) {
                        uint256 ratio = ammPriceToTheLeft
                            ? (uint256(sqrtAmmPrice) * Q48) / previousSqrtAmmPrice
                            : (previousSqrtAmmPrice * Q48) / sqrtAmmPrice;
                        ratio = ratio * ratio;
                        previousFee = FEE_PRECISION - (ratio * (FEE_PRECISION - previousFee)) / Q96;
                    } else if (previousFee > farFee) {
                        previousFee = farFee;
                    }

                    uint256 targetFee = farFee - uint256(closeFee) / 2;
                    if (previousFee <= targetFee) {
                        flexibleFee = targetFee;
                    } else {
                        PoolStorage storage poolStorageCopy = poolStorage_;
                        uint256 blocksPassed = block.number - feeData_.blockNumber;
                        uint256 factorX24 = blocksPassed <= 4
                            ? GuidestarLibrary.fastPow(poolStorageCopy.hookParams.k, blocksPassed)
                            : (uint256(
                                            FixedPointMathLib.expWad(
                                                -int256(((poolStorageCopy.hookParams.logK) << 40) * blocksPassed)
                                            )
                                        ) << 24) / 1e18;
                        flexibleFee = targetFee + ((factorX24 * (previousFee - targetFee)) >> 24);
                    }

                    totalStableFee = (ammPriceToTheLeft == userSellsZeroForOne) ? 0 : flexibleFee;
                }

                feeData_.previousFee = flexibleFee;
                feeData_.previousSqrtAmmPrice = sqrtAmmPrice;
                feeData_.blockNumber = block.number;
            }

            totalStableFee /= TO_UNISWAP_FEE; // divide by TO_UNISWAP_FEE to get fee in pips (1e12 -> 1e6)
            if (totalStableFee > MAX_FEE) {
                // this caps the fee to 99%
                totalStableFee = MAX_FEE; // set fee to 990_000 if it is greater than 990_000
            }

            return (
                Guidestar4Stable.beforeSwap.selector,
                BeforeSwapDeltaLibrary.ZERO_DELTA,
                uint24(totalStableFee) | LPFeeLibrary.OVERRIDE_FEE_FLAG
            );
        }
    }

    /// @dev Internal function to get the pool storage
    /// @param poolKey The pool key
    /// @return The pool storage
    function _getStorage(PoolKey calldata poolKey) internal view returns (PoolStorage storage) {
        return poolStorage[poolKey.toId()];
    }

    /// @dev Internal function to get the sqrt price X96
    /// @param poolId The pool ID
    /// @return The sqrt price X96
    function _getSqrtPriceX96(PoolId poolId) internal view returns (uint256) {
        (uint160 price,,,) = StateLibrary.getSlot0(poolManager, poolId);
        return price;
    }
}
