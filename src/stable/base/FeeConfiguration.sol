// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IFeeConfiguration, FeeConfig, FeeState} from "../interfaces/IFeeConfiguration.sol";
import {FeeCalculation} from "../libraries/FeeCalculation.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {BlockNumberish} from "@uniswap/blocknumberish/src/BlockNumberish.sol";
import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";

/// @title FeeConfiguration
/// @notice Abstract contract that implements the IFeeConfiguration interface
abstract contract FeeConfiguration is IFeeConfiguration, BlockNumberish {
    /// @notice The maximum optimal fee in 1e6 precision: 1% (1e4 out of 1e6)
    uint256 public constant MAX_OPTIMAL_FEE_E6 = 1e4;
    /// @notice The scale used to preserve precision in decay factor math.
    uint256 internal constant Q24 = 2 ** 24; // 16,777,216

    /// @notice The address of the config manager
    /// @dev The config manager is the address that can update the fee configuration for a pool
    address public configManager;

    /// @notice The fee config for each pool
    mapping(PoolId => FeeConfig) public feeConfig;
    /// @notice The fee state for each pool
    mapping(PoolId => FeeState) public feeState;

    constructor(address _configManager) {
        configManager = _configManager;
    }

    /// @notice Modifier to only allow calls from the config manager
    /// @dev This modifier is used to prevent unauthorized updates to the fee configuration per pool
    modifier onlyConfigManager() {
        if (msg.sender != configManager) revert NotConfigManager(msg.sender);
        _;
    }

    /// @inheritdoc IFeeConfiguration
    function setConfigManager(address configManager_) external onlyConfigManager {
        // Setting the config manager to address(0) disables further updates to the fee configuration
        configManager = configManager_;
        emit ConfigManagerUpdated(configManager_);
    }

    /// @inheritdoc IFeeConfiguration
    function updateFeeConfig(PoolId poolId_, FeeConfig calldata feeConfig_) external onlyConfigManager {
        _updateFeeConfig(poolId_, feeConfig_);
        emit FeeConfigUpdated(poolId_, feeConfig_);
    }

    /// @notice Internal helper to initialize fee config and fee state
    /// @param _poolId The pool ID to initialize
    /// @param _feeConfig The fee config to set
    function _updateFeeConfig(PoolId _poolId, FeeConfig calldata _feeConfig) internal {
        _validateKAndLogK(_feeConfig.k, _feeConfig.logK);
        _validateOptimalFeeE6(_feeConfig.optimalFeeE6);
        _validateReferenceSqrtPriceX96(_feeConfig.referenceSqrtPriceX96);
        _resetFeeState(_poolId);
        feeConfig[_poolId] = _feeConfig;
    }

    /// @notice Validate the decay factor
    /// @param _k The k value to validate
    /// @param _logK The logK value to validate
    function _validateKAndLogK(uint256 _k, uint256 _logK) internal pure {
        // k == 0 causes instant decay (invalid).
        // logK == 0 rejects k values so close to Q24 (1.0) that -ln(k) >> 40 rounds to 0,
        // which would make the decay factor always 1.0 (fee never decays).
        if (_k == 0 || _logK == 0) {
            revert InvalidKAndLogK(_k, _logK);
        }
        // Convert k from Q24 to wad format (1e18 scale)
        uint256 kWad = (_k * 1e18) >> 24;

        // lnWad computes ln(k) * 1e18
        // Since k < 1, ln(k) is negative
        int256 lnK = FixedPointMathLib.lnWad(int256(kWad));

        // expectedLogK = -lnK / 2^40
        uint256 expectedLogK = uint256(-lnK) >> 40;

        if (_logK != expectedLogK) revert InvalidKAndLogK(_k, _logK);
    }

    /// @notice Validate the optimal fee
    /// @param _optimalFeeE6 The optimal fee to validate
    function _validateOptimalFeeE6(uint256 _optimalFeeE6) internal pure {
        if (_optimalFeeE6 > MAX_OPTIMAL_FEE_E6) {
            revert InvalidOptimalFeeE6(_optimalFeeE6);
        }
    }

    /// @notice Validate the reference sqrt price
    /// @dev The optimal range is defined in terms of PRICE (not sqrt price):
    ///      [referencePrice * (1 - maxOptimalFee), referencePrice / (1 - maxOptimalFee)]
    ///      Since price = sqrtPrice², the sqrt price bounds are:
    ///      [referenceSqrtPrice * sqrt(1 - maxOptimalFee), referenceSqrtPrice / sqrt(1 - maxOptimalFee)]
    ///      Note: MIN_SQRT_PRICE is valid (inclusive) but MAX_SQRT_PRICE is invalid (exclusive) in v4.
    /// @param _referenceSqrtPriceX96 The reference sqrt price to validate
    function _validateReferenceSqrtPriceX96(uint256 _referenceSqrtPriceX96) internal pure {
        // Calculate bounds that ensure optimal range stays within v4 sqrt price limits
        // The optimal range boundaries in sqrt price terms use sqrt(1 - fee), not (1 - fee)
        // minBound: referenceSqrtPrice * sqrt(1 - maxOptimalFee) >= MIN_SQRT_PRICE
        //           => referenceSqrtPrice >= MIN_SQRT_PRICE / sqrt(1 - maxOptimalFee)
        // maxBound: referenceSqrtPrice / sqrt(1 - maxOptimalFee) < MAX_SQRT_PRICE  (strictly less than!)
        //           => referenceSqrtPrice < MAX_SQRT_PRICE * sqrt(1 - maxOptimalFee)
        uint256 oneMinusMaxFee = FeeCalculation.ONE_E6 - MAX_OPTIMAL_FEE_E6;
        uint256 sqrtOneMinusMaxFeeE6 = FixedPointMathLib.sqrt(oneMinusMaxFee * FeeCalculation.ONE_E6);
        uint256 minBoundedReferenceSqrtPrice =
            (uint256(TickMath.MIN_SQRT_PRICE) * FeeCalculation.ONE_E6 + sqrtOneMinusMaxFeeE6 - 1) / sqrtOneMinusMaxFeeE6;
        uint256 maxBoundedReferenceSqrtPrice =
            uint256(TickMath.MAX_SQRT_PRICE) * sqrtOneMinusMaxFeeE6 / FeeCalculation.ONE_E6;

        if (
            _referenceSqrtPriceX96 < minBoundedReferenceSqrtPrice
                || _referenceSqrtPriceX96 >= maxBoundedReferenceSqrtPrice
        ) {
            revert InvalidReferenceSqrtPriceX96(_referenceSqrtPriceX96);
        }
    }

    /// @notice Internal helper to reset fee state
    /// @param _poolId The pool ID to reset fee state for
    function _resetFeeState(PoolId _poolId) internal {
        feeState[_poolId].previousFeeE12 = uint40(FeeCalculation.UNDEFINED_DECAYING_FEE_E12);
        feeState[_poolId].blockNumber = uint40(_getBlockNumberish());
        // previousSqrtAmmPriceX96 is intentionally not reset: the UNDEFINED_DECAYING_FEE_E12 sentinel
        // causes _calculateDecayingFee to ignore the stale value and start fresh from farBoundaryFee.
    }
}
