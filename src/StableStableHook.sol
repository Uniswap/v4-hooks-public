// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import {IStableStableHook} from "./interfaces/IStableStableHook.sol";
import {BaseHook} from "./base/BaseHook.sol";
import {FeeConfig} from "./types/FeeConfig.sol";
import {HistoricalFeeData} from "./types/HistoricalFeeData.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Multicall} from "@openzeppelin/contracts/utils/Multicall.sol";

/// @title StableStableHook
/// @notice Dynamic fee hook for stable/stable pools
contract StableStableHook is BaseHook, Ownable, Multicall, IStableStableHook {
    using LPFeeLibrary for uint24;

    /// @notice The fee configuration for each pool
    mapping(PoolId => FeeConfig) public feeConfig;
    /// @notice The historical data for each pool
    mapping(PoolId => HistoricalFeeData) public historicalFeeData;

    /// @notice The address of the fee controller
    /// @dev The fee controller is the address that can update the fee configuration for a pool
    address public immutable feeController;

    constructor(IPoolManager _manager, address _owner, address _feeController) BaseHook(_manager) Ownable(_owner) {
        feeController = _feeController;
    }

    /// @notice Modifier to only allow calls from the fee controller
    /// @dev This modifier is used to prevent unauthorized updates to the fee configuration per pool
    modifier onlyFeeController() {
        if (msg.sender != feeController) revert NotFeeController(msg.sender);
        _;
    }

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
        _validateDecayFactor(feeConfiguration.decayFactor);
        _validateOptimalFeeSpread(feeConfiguration.optimalFeeSpread);
        _validateReferenceSqrtPrice(feeConfiguration.referenceSqrtPrice);
        tick = poolManager.initialize(poolKey, sqrtPriceX96);
        feeConfig[poolKey.toId()] = feeConfiguration;
        emit PoolInitialized(poolKey, sqrtPriceX96, feeConfiguration);
    }

    /// @inheritdoc IStableStableHook
    /// @dev Should be called in a multicall with clearHistoricalFeeData()
    function updateDecayFactor(PoolKey calldata poolKey, uint256 decayFactor) external onlyFeeController {
        _validateDecayFactor(decayFactor);
        feeConfig[poolKey.toId()].decayFactor = decayFactor;
        emit DecayFactorUpdated(poolKey, decayFactor);
    }

    /// @inheritdoc IStableStableHook
    /// @dev Should be called in a multicall with clearHistoricalFeeData()
    function updateOptimalFeeSpread(PoolKey calldata poolKey, uint256 optimalFeeSpread) external onlyFeeController {
        _validateOptimalFeeSpread(optimalFeeSpread);
        feeConfig[poolKey.toId()].optimalFeeSpread = optimalFeeSpread;
        emit OptimalFeeSpreadUpdated(poolKey, optimalFeeSpread);
    }

    /// @inheritdoc IStableStableHook
    /// @dev Should be called in a multicall with clearHistoricalFeeData()
    function updateReferenceSqrtPrice(PoolKey calldata poolKey, uint160 referenceSqrtPrice) external onlyFeeController {
        _validateReferenceSqrtPrice(referenceSqrtPrice);
        feeConfig[poolKey.toId()].referenceSqrtPrice = referenceSqrtPrice;
        emit ReferenceSqrtPriceUpdated(poolKey, referenceSqrtPrice);
    }

    /// @inheritdoc IStableStableHook
    function clearHistoricalFeeData(PoolKey calldata poolKey) external onlyFeeController {
        delete historicalFeeData[poolKey.toId()];
        emit HistoricalFeeDataCleared(poolKey);
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

    function _beforeInitialize(address sender, PoolKey calldata, uint160) internal view override returns (bytes4) {
        // Since hooks cannot call themselves, this function is only called when another address tries to initialize a pool with this contract as the hook
        // Therefore this function always reverts to ensure only this contract can initialize new pools
        revert InvalidInitializer(sender);
    }

    function _beforeSwap(address, PoolKey calldata, SwapParams calldata, bytes calldata)
        internal
        pure
        override
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        return (IHooks.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
    }

    function _validateDecayFactor(uint256 _decayFactor) internal pure {
        // TODO: set bounds on decay factor
    }

    function _validateOptimalFeeSpread(uint256 _optimalFeeSpread) internal pure {
        // TODO: set bounds on optimal fee spread
    }

    function _validateReferenceSqrtPrice(uint160 _referenceSqrtPrice) internal pure {
        // TODO: set bounds on reference sqrt price
        // should they be close to stable price?
    }
}
