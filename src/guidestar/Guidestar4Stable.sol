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
    error PoolNotRecognizedByHook();

    uint256 internal constant ONE = 1e12;
    uint256 internal constant UNDEFINED_FLEXIBLE_FEE = ONE + 1;
    uint256 internal constant TO_UNISWAP_FEE = ONE / 1e6;

    struct FeeData {
        uint256 flags; // bit0 = 1 => stable
        uint256 previousFee;
        uint160 previousSqrtAmmPrice;
        uint256 blockNumber;
    }

    struct HookParams {
        uint256 flags; // bit0=1 => stable
        uint256 k;
        uint256 logK;
        uint256 optimalFeeSpread;
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

    function beforeSwap(address, PoolKey calldata poolKey, SwapParams calldata params, bytes calldata)
        external
        onlyByGateway
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        PoolId poolId = poolKey.toId();
        PoolStorage storage poolStorage_ = poolStorage[poolId];
        unchecked {
            FeeData storage feeData_ = poolStorage_.feeData;

            if (feeData_.flags == 0) {
                revert PoolNotRecognizedByHook();
            }

            uint160 sqrtAmmPrice = uint160(getSqrtPriceX96(poolId));
            uint160 referenceSqrtPrice_ = uint160(poolStorage_.hookParams.referenceSqrtPrice);

            bool userSellsZeroForOne = params.zeroForOne;
            bool ammPriceToTheLeft = (sqrtAmmPrice < referenceSqrtPrice_);

            int256 closeFee;
            uint256 farFee;
            bool insideOptimalSpread;
            uint256 insideOptimalSpreadFee;

            {
                uint256 optimalFeeSpread_ = poolStorage_.hookParams.optimalFeeSpread;
                uint256 ratio = ammPriceToTheLeft
                    ? (uint256(sqrtAmmPrice) * 2 ** 48) / referenceSqrtPrice_
                    : (uint256(referenceSqrtPrice_) * 2 ** 48) / sqrtAmmPrice;
                ratio = ratio * ratio;

                closeFee = int256(ONE) - int256((ONE * ratio * 1_000_000) / (1_000_000 - optimalFeeSpread_) / 2 ** 96);
                insideOptimalSpread = (closeFee <= 0);

                if (insideOptimalSpread) {
                    insideOptimalSpreadFee = ammPriceToTheLeft == userSellsZeroForOne
                        ? ONE - (ONE * (1_000_000 - optimalFeeSpread_) * 2 ** 96) / ratio / 1_000_000
                        : ONE - (ONE * (1_000_000 - optimalFeeSpread_) * ratio) / 2 ** 96 / 1_000_000;
                } else {
                    farFee = ONE - (ONE * (1_000_000 - optimalFeeSpread_) * ratio) / 2 ** 96 / 1_000_000;
                }
            }

            uint256 totalStableFee;
            {
                uint256 flexibleFee;
                if (insideOptimalSpread) {
                    totalStableFee = insideOptimalSpreadFee;
                    flexibleFee = UNDEFINED_FLEXIBLE_FEE;
                } else {
                    uint256 previousSqrtAmmPrice = feeData_.previousSqrtAmmPrice;
                    uint256 previousFee = feeData_.previousFee;

                    if (
                        previousFee == UNDEFINED_FLEXIBLE_FEE
                            || (ammPriceToTheLeft != (previousSqrtAmmPrice < referenceSqrtPrice_))
                    ) {
                        previousFee = farFee;
                    } else if (ammPriceToTheLeft == (sqrtAmmPrice < previousSqrtAmmPrice)) {
                        uint256 ratio = ammPriceToTheLeft
                            ? (uint256(sqrtAmmPrice) * 2 ** 48) / previousSqrtAmmPrice
                            : (previousSqrtAmmPrice * 2 ** 48) / sqrtAmmPrice;
                        ratio = ratio * ratio;
                        previousFee = ONE - (ratio * (ONE - previousFee)) / 2 ** 96;
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

            totalStableFee /= TO_UNISWAP_FEE;
            if (totalStableFee > 990_000) {
                totalStableFee = 990_000;
            }

            return (
                Guidestar4Stable.beforeSwap.selector,
                BeforeSwapDeltaLibrary.ZERO_DELTA,
                uint24(totalStableFee) | LPFeeLibrary.OVERRIDE_FEE_FLAG
            );
        }
    }

    function beforeAddLiquidity(address, PoolKey calldata, ModifyLiquidityParams calldata, bytes calldata)
        external
        view
        onlyByGateway
        returns (bytes4)
    {
        return Guidestar4Stable.beforeAddLiquidity.selector;
    }

    // function afterAddLiquidity(
    //     address,
    //     PoolKey calldata,
    //     IPoolManager.ModifyLiquidityParams calldata,
    //     BalanceDelta,
    //     BalanceDelta,
    //     bytes calldata
    // )
    //     external
    //     onlyByGateway
    //     returns (bytes4, BalanceDelta)
    // {
    //     return (Guidestar4Stable.afterAddLiquidity.selector, BalanceDeltaLibrary.ZERO_DELTA);
    // }

    function afterRemoveLiquidity(
        address,
        PoolKey calldata,
        ModifyLiquidityParams calldata,
        BalanceDelta,
        BalanceDelta,
        bytes calldata
    ) external virtual onlyByGateway returns (bytes4, BalanceDelta) {
        return (Guidestar4Stable.afterRemoveLiquidity.selector, BalanceDeltaLibrary.ZERO_DELTA);
    }

    function initializePair(
        PoolKey calldata poolKey,
        uint160 sqrtPriceX96,
        FeeData memory feeData_,
        HookParams memory hookParams_
    ) external onlyOwner returns (int24 tick) {
        tick = poolManager.initialize(poolKey, sqrtPriceX96);
        PoolStorage storage poolStorage_ = getStorage(poolKey);
        poolStorage_.feeData = feeData_;
        poolStorage_.hookParams = hookParams_;
    }

    function beforeInitialize(address, PoolKey calldata poolKey, uint160) external view onlyByGateway returns (bytes4) {
        if (!LPFeeLibrary.isDynamicFee(poolKey.fee)) {
            revert MustUseDynamicFee();
        }
        return Guidestar4Stable.beforeInitialize.selector;
    }

    function getStorage(PoolKey calldata poolKey) internal view returns (PoolStorage storage) {
        return poolStorage[poolKey.toId()];
    }

    function getSqrtPriceX96(PoolId poolId) internal view returns (uint256) {
        (uint160 price,,,) = StateLibrary.getSlot0(poolManager, poolId);
        return price;
    }

    function feeData(PoolId poolId) external view returns (FeeData memory) {
        return poolStorage[poolId].feeData;
    }

    function setFeeData(PoolKey calldata poolKey, FeeData memory feeData_) external onlyOwner {
        poolStorage[poolKey.toId()].feeData = feeData_;
    }

    function hookParams(PoolId poolId) external view returns (HookParams memory) {
        return poolStorage[poolId].hookParams;
    }

    function setHookParams(PoolKey calldata poolKey, HookParams memory hookParams_) external onlyOwner {
        poolStorage[poolKey.toId()].hookParams = hookParams_;
    }

    function setReferenceSqrtPrice(PoolKey calldata poolKey, uint160 referenceSqrtPrice_) external onlyOwner {
        PoolStorage storage poolStorage_ = getStorage(poolKey);
        require((poolStorage_.hookParams.flags & 1) == 1 && (poolStorage_.feeData.flags & 1) == 1, "Not a stable pair");
        poolStorage_.hookParams.referenceSqrtPrice = referenceSqrtPrice_;
        poolStorage_.feeData.previousFee = UNDEFINED_FLEXIBLE_FEE;
        poolStorage_.feeData.blockNumber = block.number;
    }

    function setOptimalFeeSpread(PoolKey calldata poolKey, uint24 optimalFeeSpread_) external onlyOwner {
        PoolStorage storage poolStorage_ = getStorage(poolKey);
        require((poolStorage_.hookParams.flags & 1) == 1 && (poolStorage_.feeData.flags & 1) == 1, "Not a stable pair");
        poolStorage_.hookParams.optimalFeeSpread = optimalFeeSpread_;
        poolStorage_.feeData.previousFee = UNDEFINED_FLEXIBLE_FEE;
        poolStorage_.feeData.blockNumber = block.number;
    }
}
