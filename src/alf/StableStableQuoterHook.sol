// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {Ownable2Step, Ownable} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import {BaseALFHook} from "./base/BaseALFHook.sol";
import {IAttestationRegistry} from "./interfaces/IAttestationRegistry.sol";
import {SwapSimulator} from "./libraries/SwapSimulator.sol";
import {FeeConfiguration} from "../stable/base/FeeConfiguration.sol";
import {FeeCalculation} from "../stable/libraries/FeeCalculation.sol";
import {FeeConfig, FeeState} from "../stable/interfaces/IFeeConfiguration.sol";

/// @title StableStableQuoterHook
/// @notice IALFHook-compliant dynamic fee hook for stable/stable pairs, integrating the
///         StableStableHook's reference-price fee model with the ALF quoter framework.
///         Discoverable via ALFQuoterRegistry, queryable via getIndicativeQuote, routable by the
///         auction hook. Supports EIP-712 signed curve updates for atomic fee config changes.
contract StableStableQuoterHook is BaseALFHook, FeeConfiguration, EIP712, Ownable2Step {
    using LPFeeLibrary for uint24;
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    // ──── ALF State ────

    struct StableCurveUpdate {
        FeeConfig feeConfig;
        uint16 attestedDiscountBps;
        bool live;
    }

    bytes32 private constant STABLE_CURVE_UPDATE_TYPEHASH = keccak256(
        "StableCurveUpdate(uint24 k,uint24 logK,uint24 optimalFeeE6,uint160 referenceSqrtPriceX96,uint16 attestedDiscountBps,bool live,bytes32 poolId,uint256 deadline)"
    );

    mapping(PoolId => uint16) public attestedDiscountBps;
    mapping(PoolId => bool) public poolLive;

    // ──── Errors & Events ────

    error MustUseDynamicFee(uint24 lpFee);
    error InvalidHookAddress(address hookAddress);
    error InvalidInitializer(address caller);

    event PoolInitialized(PoolKey indexed poolKey, uint160 sqrtPriceX96, FeeConfig feeConfig);
    event PoolConfigUpdated(PoolId indexed poolId);
    event PoolLivenessUpdated(PoolId indexed poolId, bool isLive);

    // ──── Constructor ────

    constructor(
        IPoolManager _poolManager,
        IAttestationRegistry _attestationRegistry,
        uint32 maxGas_,
        address owner_,
        address configManager_
    )
        BaseALFHook(_poolManager, _attestationRegistry, maxGas_)
        FeeConfiguration(configManager_)
        EIP712("StableStableQuoterHook", "1")
        Ownable(owner_)
    {}

    // ──── Hook Permissions ────

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

    // ──── IALFHook ────

    function isLive() external pure override returns (bool) {
        return true;
    }

    /// @notice Indicative quote with hookData-aware dynamic fee pricing.
    /// @dev If hookData contains a curve update, the new FeeConfig is used for simulation
    ///      with a reset fee state (matching what _applyCurveUpdate would do on execution).
    function getIndicativeQuote(PoolKey calldata key, bool zeroForOne, int256 amountSpecified, bytes calldata hookData)
        external
        view
        override
        returns (uint256 outputAmount)
    {
        PoolId poolId = key.toId();
        int24 tickSpacing = key.tickSpacing;
        (uint24 feePips, uint16 discount, bool isAttested, bool live) =
            _resolveQuoteParams(poolId, zeroForOne, hookData);

        if (!live) return 0;

        outputAmount =
            SwapSimulator.simulateSwap(poolManager, poolId, zeroForOne, amountSpecified, feePips, tickSpacing);

        if (isAttested && discount > 0) {
            outputAmount = (outputAmount * (10_000 + uint256(discount))) / 10_000;
        }
    }

    /// @dev Resolve fee, discount, attestation, and liveness for an indicative quote.
    ///      Handles hookData curve updates by computing fees against the updated config.
    function _resolveQuoteParams(PoolId poolId, bool zeroForOne, bytes calldata hookData)
        internal
        view
        returns (uint24 feePips, uint16 discount, bool isAttested, bool live)
    {
        FeeConfig memory config = _loadFeeConfig(poolId);
        FeeState memory state = _loadFeeState(poolId);
        discount = attestedDiscountBps[poolId];
        live = poolLive[poolId];

        {
            bytes memory curveUpdateData;
            (curveUpdateData, isAttested,) = _resolveHookData(hookData);

            if (curveUpdateData.length > 0) {
                (StableCurveUpdate memory update,,,) =
                    abi.decode(curveUpdateData, (StableCurveUpdate, PoolId, uint256, bytes));
                config = update.feeConfig;
                discount = update.attestedDiscountBps;
                live = update.live;
                state.decayingFeeE12 = uint40(FeeCalculation.UNDEFINED_DECAYING_FEE_E12);
                state.blockNumber = uint40(_getBlockNumberish());
            }
        }

        if (!live) return (0, discount, isAttested, false);

        (uint160 sqrtAmmPriceX96,,,) = poolManager.getSlot0(poolId);
        (uint256 lpFeeE12,) = _computeDynamicFeeFromMemory(config, state, sqrtAmmPriceX96, zeroForOne);
        feePips = uint24(lpFeeE12 / FeeCalculation.ONE_E6);
    }

    /// @dev Load FeeConfig from storage into memory.
    function _loadFeeConfig(PoolId poolId) internal view returns (FeeConfig memory) {
        FeeConfig storage s = feeConfig[poolId];
        return
            FeeConfig({
                k: s.k, logK: s.logK, optimalFeeE6: s.optimalFeeE6, referenceSqrtPriceX96: s.referenceSqrtPriceX96
            });
    }

    /// @dev Load FeeState from storage into memory.
    function _loadFeeState(PoolId poolId) internal view returns (FeeState memory) {
        FeeState storage s = feeState[poolId];
        return
            FeeState({decayingFeeE12: s.decayingFeeE12, sqrtAmmPriceX96: s.sqrtAmmPriceX96, blockNumber: s.blockNumber});
    }

    // ──── Pool Initialization ────

    /// @notice Initialize a pool with this hook and register it in the ALFQuoterRegistry.
    /// @dev v4 skips hook callbacks when msg.sender == key.hooks, so beforeInitialize
    ///      won't fire and we register in the index inline.
    function initializePool(
        PoolKey calldata poolKey,
        uint160 sqrtPriceX96,
        FeeConfig calldata feeConfiguration,
        uint16 attestedDiscount,
        bool live
    ) external onlyOwner returns (int24 tick) {
        if (!poolKey.fee.isDynamicFee()) revert MustUseDynamicFee(poolKey.fee);
        if (poolKey.hooks != IHooks(address(this))) revert InvalidHookAddress(address(poolKey.hooks));

        PoolId poolId = poolKey.toId();
        _updateFeeConfig(poolId, feeConfiguration);
        attestedDiscountBps[poolId] = attestedDiscount;
        poolLive[poolId] = live;

        tick = poolManager.initialize(poolKey, sqrtPriceX96);

        emit PoolInitialized(poolKey, sqrtPriceX96, feeConfiguration);
    }

    // ──── Hook Lifecycle ────

    function _beforeInitialize(address sender, PoolKey calldata, uint160) internal pure override returns (bytes4) {
        revert InvalidInitializer(sender);
    }

    function _beforeSwap(address, PoolKey calldata key, SwapParams calldata params, bytes calldata hookData)
        internal
        override
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        PoolId poolId = key.toId();

        // 1. Handle curve update from hookData
        {
            (bytes memory curveUpdateData,,) = _resolveHookData(hookData);
            if (curveUpdateData.length > 0) {
                _applyCurveUpdate(poolId, curveUpdateData);
            }
        }

        // 2. Check liveness
        if (!poolLive[poolId]) {
            return (IHooks.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
        }

        // 3. Calculate dynamic fee
        FeeConfig storage poolFeeConfig = feeConfig[poolId];
        FeeState storage poolFeeState = feeState[poolId];
        (uint160 sqrtAmmPriceX96,,,) = poolManager.getSlot0(poolId);

        (uint256 lpFeeE12, uint256 decayingFeeE12) =
            _computeDynamicFee(poolFeeConfig, poolFeeState, sqrtAmmPriceX96, params.zeroForOne);

        // 4. Update fee state
        poolFeeState.decayingFeeE12 = uint40(decayingFeeE12);
        poolFeeState.sqrtAmmPriceX96 = uint160(sqrtAmmPriceX96);
        poolFeeState.blockNumber = uint40(_getBlockNumberish());

        // 5. Return fee override
        uint24 feeOverride = uint24(lpFeeE12 / FeeCalculation.ONE_E6) | LPFeeLibrary.OVERRIDE_FEE_FLAG;
        return (IHooks.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, feeOverride);
    }

    // ──── Pricing ────

    function _price(PoolKey calldata key, bool zeroForOne, int256 amountSpecified, bool isAttested, address)
        internal
        view
        override
        returns (uint256 outputAmount)
    {
        PoolId poolId = key.toId();
        if (!poolLive[poolId]) return 0;

        (uint160 sqrtAmmPriceX96,,,) = poolManager.getSlot0(poolId);
        (uint256 lpFeeE12,) = _computeDynamicFee(feeConfig[poolId], feeState[poolId], sqrtAmmPriceX96, zeroForOne);
        uint24 feePips = uint24(lpFeeE12 / FeeCalculation.ONE_E6);

        outputAmount =
            SwapSimulator.simulateSwap(poolManager, poolId, zeroForOne, amountSpecified, feePips, key.tickSpacing);

        uint16 discount = attestedDiscountBps[poolId];
        if (isAttested && discount > 0) {
            outputAmount = (outputAmount * (10_000 + uint256(discount))) / 10_000;
        }
    }

    // ──── Dynamic Fee Calculation ────

    /// @dev Storage-ref convenience wrapper: loads to memory and delegates.
    function _computeDynamicFee(
        FeeConfig storage config,
        FeeState storage state,
        uint160 sqrtAmmPriceX96,
        bool zeroForOne
    ) internal view returns (uint256 lpFeeE12, uint256 decayingFeeE12) {
        return _computeDynamicFeeFromMemory(
            FeeConfig(config.k, config.logK, config.optimalFeeE6, config.referenceSqrtPriceX96),
            FeeState(state.decayingFeeE12, state.sqrtAmmPriceX96, state.blockNumber),
            sqrtAmmPriceX96,
            zeroForOne
        );
    }

    /// @dev Core fee calculation operating on memory params.
    function _computeDynamicFeeFromMemory(
        FeeConfig memory config,
        FeeState memory state,
        uint160 sqrtAmmPriceX96,
        bool zeroForOne
    ) internal view returns (uint256 lpFeeE12, uint256 decayingFeeE12) {
        uint256 sqrtReferencePriceX96 = config.referenceSqrtPriceX96;
        uint256 optimalFeeE6 = config.optimalFeeE6;
        uint256 priceRatioX96 = FeeCalculation.calculatePriceRatioX96(sqrtAmmPriceX96, sqrtReferencePriceX96);
        int256 closeBoundaryFeeE12 = FeeCalculation.calculateCloseBoundaryFee(priceRatioX96, optimalFeeE6);

        bool ammPriceBelowRP = sqrtAmmPriceX96 < sqrtReferencePriceX96;

        if (closeBoundaryFeeE12 <= 0) {
            lpFeeE12 =
                FeeCalculation.calculateInsideOptimalRangeFee(priceRatioX96, optimalFeeE6, ammPriceBelowRP, zeroForOne);
            decayingFeeE12 = FeeCalculation.UNDEFINED_DECAYING_FEE_E12;
        } else {
            uint256 farBoundaryFeeE12 = FeeCalculation.calculateFarBoundaryFee(priceRatioX96, optimalFeeE6);

            decayingFeeE12 = _calculateDecayingFeeFromMemory(
                config,
                state,
                sqrtAmmPriceX96,
                sqrtReferencePriceX96,
                uint256(closeBoundaryFeeE12),
                farBoundaryFeeE12,
                ammPriceBelowRP
            );

            lpFeeE12 = (ammPriceBelowRP == zeroForOne) ? 0 : decayingFeeE12;
        }
    }

    // ──── Decaying Fee ────

    function _calculateDecayingFeeFromMemory(
        FeeConfig memory poolFeeConfig,
        FeeState memory poolFeeState,
        uint256 sqrtAmmPriceX96,
        uint256 sqrtReferencePriceX96,
        uint256 closeBoundaryFeeE12,
        uint256 farBoundaryFeeE12,
        bool ammPriceBelowRP
    ) private view returns (uint256 decayingFeeE12) {
        uint256 previousSqrtAmmPriceX96 = poolFeeState.sqrtAmmPriceX96;
        uint256 previousDecayingFeeE12 = poolFeeState.decayingFeeE12;
        uint256 previousBlockNumber = poolFeeState.blockNumber;

        uint256 decayStartFeeE12;
        if (
            previousDecayingFeeE12 == FeeCalculation.UNDEFINED_DECAYING_FEE_E12
                || (previousSqrtAmmPriceX96 < sqrtReferencePriceX96) != ammPriceBelowRP
        ) {
            decayStartFeeE12 = farBoundaryFeeE12;
        } else if (ammPriceBelowRP == (sqrtAmmPriceX96 < previousSqrtAmmPriceX96)) {
            uint256 priceMovementRatioX96 =
                FeeCalculation.calculatePriceRatioX96(sqrtAmmPriceX96, previousSqrtAmmPriceX96);
            decayStartFeeE12 =
                FeeCalculation.adjustPreviousFeeForPriceMovement(priceMovementRatioX96, previousDecayingFeeE12);
        } else if (previousDecayingFeeE12 > farBoundaryFeeE12) {
            decayStartFeeE12 = farBoundaryFeeE12;
        } else {
            decayStartFeeE12 = previousDecayingFeeE12;
        }

        decayingFeeE12 = FeeCalculation.calculateDecayingFee(
            farBoundaryFeeE12 - closeBoundaryFeeE12 / 2,
            decayStartFeeE12,
            poolFeeConfig.k,
            poolFeeConfig.logK,
            _getBlockNumberish() - previousBlockNumber
        );
    }

    // ──── Curve Update (EIP-712 Signed) ────

    function _applyCurveUpdate(PoolId poolId, bytes memory curveUpdateData) internal {
        (StableCurveUpdate memory update, PoolId updatePoolId, uint256 deadline, bytes memory sig) =
            abi.decode(curveUpdateData, (StableCurveUpdate, PoolId, uint256, bytes));

        _validateCurveUpdateMeta(poolId, updatePoolId, deadline);

        if (_checkAndMarkCurveUpdate(poolId, curveUpdateData)) {
            _verifySignature(update, poolId, deadline, sig);

            _applyFeeConfig(poolId, update.feeConfig);
            attestedDiscountBps[poolId] = update.attestedDiscountBps;
            poolLive[poolId] = update.live;

            emit PoolConfigUpdated(poolId);
        }
    }

    /// @dev Validate and store a FeeConfig from memory (bypasses _updateFeeConfig's calldata requirement).
    function _applyFeeConfig(PoolId poolId, FeeConfig memory config) internal {
        _validateKAndLogK(config.k, config.logK);
        _validateOptimalFeeE6(config.optimalFeeE6);
        _validateReferenceSqrtPriceX96(config.referenceSqrtPriceX96);
        _resetFeeState(poolId);
        feeConfig[poolId] = config;
    }

    function _verifySignature(StableCurveUpdate memory update, PoolId poolId, uint256 deadline, bytes memory sig)
        internal
        view
    {
        bytes32 structHash = keccak256(
            abi.encode(
                STABLE_CURVE_UPDATE_TYPEHASH,
                update.feeConfig.k,
                update.feeConfig.logK,
                update.feeConfig.optimalFeeE6,
                update.feeConfig.referenceSqrtPriceX96,
                update.attestedDiscountBps,
                update.live,
                PoolId.unwrap(poolId),
                deadline
            )
        );
        bytes32 digest = _hashTypedDataV4(structHash);
        address signer = ECDSA.recover(digest, sig);
        if (signer != priceSigner) revert InvalidPriceSigner();
    }

    // ──── Owner Functions ────

    /// @notice Update fee configuration and ALF state for a pool.
    function updatePoolConfig(
        PoolKey calldata key,
        FeeConfig calldata feeConfiguration,
        uint16 attestedDiscount,
        bool live
    ) external onlyOwner {
        PoolId poolId = key.toId();
        _updateFeeConfig(poolId, feeConfiguration);
        attestedDiscountBps[poolId] = attestedDiscount;
        poolLive[poolId] = live;
        emit PoolConfigUpdated(poolId);
    }

    /// @notice Toggle liveness for a pool.
    function setPoolLive(PoolKey calldata key, bool live) external onlyOwner {
        PoolId poolId = key.toId();
        poolLive[poolId] = live;
        emit PoolLivenessUpdated(poolId, live);
    }

    /// @notice Set the authorized price signer for hookData curve updates.
    function setPriceSigner(address _priceSigner) external onlyOwner {
        priceSigner = _priceSigner;
        emit PriceSignerUpdated(_priceSigner);
    }
}
