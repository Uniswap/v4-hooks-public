// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IFluidDexV2} from "./IFluidDexV2.sol";

interface IFluidDexV2Resolver {
    // Pool configuration with metadata
    struct DexConfig {
        uint256 dexType; // 3 for D3, 4 for D4
        IFluidDexV2.DexKey dexKey; // Pool identification
        bytes32 dexId; // Computed pool ID
        bytes32 dexAssetId; // Asset ID for money market integration
    }

    // Combined pool configuration and state
    struct DexPoolInfo {
        DexConfig dexConfig;
        DexPoolState dexPoolState;
    }

    // Pool state variables (packed and unpacked versions)
    struct DexVariables {
        int256 currentTick;
        uint256 currentSqrtPriceX96;
        uint256 feeGrowthGlobal0X102;
        uint256 feeGrowthGlobal1X102;
    }

    struct DexVariables2 {
        uint256 protocolFee0To1;
        uint256 protocolFee1To0;
        uint256 protocolCutFee;
        uint256 token0Decimals;
        uint256 token1Decimals;
        uint256 activeLiquidity;
        bool poolAccountingFlag; // Per pool accounting flag
        bool fetchDynamicFeeFlag;
        uint256 feeVersion; // 0 = static fee, 1 = dynamic fee
        uint256 lpFee;
        uint256 maxDecayTime;
        uint256 priceImpactToFeeDivisionFactor;
        uint256 minFee;
        uint256 maxFee;
        int256 netPriceImpact;
        uint256 lastUpdateTimestamp;
        uint256 decayTimeRemaining;
    }

    // Raw pool state data
    struct DexPoolStateRaw {
        uint256 dexVariablesPacked;
        uint256 dexVariables2Packed;
        DexVariables dexVariablesUnpacked;
        DexVariables2 dexVariables2Unpacked;
    }

    // Complete pool state (returned by resolver)
    struct DexPoolState {
        bytes32 dexId;
        uint256 dexPriceParsed;
        DexPoolStateRaw dexPoolStateRaw;
    }

    // Position-related structures
    struct PositionData {
        uint256 liquidity;
        uint256 feeGrowthInside0X102;
        uint256 feeGrowthInside1X102;
    }

    struct PositionInfo {
        PositionData positionData;
        uint256 amount0;
        uint256 amount1;
        uint256 feeAccruedToken0;
        uint256 feeAccruedToken1;
    }

    // Liquidity distribution analysis
    struct TickLiquidity {
        int24 tick;
        uint256 liquidity;
    }

    /// @notice Computes the unique pool ID from a DexKey
    /// @param dexKey The pool identification parameters
    /// @return dexId The computed unique identifier for the pool
    function getDexId(IFluidDexV2.DexKey memory dexKey) external pure returns (bytes32 dexId);

    /// @notice Retrieves the DexKey for a given pool ID
    /// @param dexType The type of DEX (3 for D3, 4 for D4)
    /// @param dexId The unique pool identifier
    /// @return dexKey The pool identification parameters
    function getDexKey(uint256 dexType, bytes32 dexId) external view returns (IFluidDexV2.DexKey memory dexKey);

    /// @notice Returns all permissioned D3-type DEX pools listed in the money market
    /// @return dexKeys Array of DexKey structs for D3 pools
    function getD3PermissionedDexes() external view returns (IFluidDexV2.DexKey[] memory dexKeys);

    /// @notice Returns all permissioned D4-type DEX pools listed in the money market
    /// @return dexKeys Array of DexKey structs for D4 pools
    function getD4PermissionedDexes() external view returns (IFluidDexV2.DexKey[] memory dexKeys);

    /// @notice Returns configuration for all permissioned DEX pools
    /// @return dexConfigs Array of DexConfig structs with pool metadata
    function getAllPermissionedDexes() external view returns (DexConfig[] memory dexConfigs);

    /// @notice Returns configuration and current state for all permissioned DEX pools
    /// @return dexPoolInfos Array of DexPoolInfo structs with complete pool data
    function getAllPermissionedDexesPoolState() external view returns (DexPoolInfo[] memory dexPoolInfos);

    /// @notice Retrieves the current state of a DEX pool
    /// @param dexType The type of DEX (3 for D3, 4 for D4)
    /// @param dexKey The pool identification parameters
    /// @return The current DexPoolState including prices, fees, and liquidity
    function getDexPoolState(uint256 dexType, IFluidDexV2.DexKey memory dexKey)
        external
        view
        returns (DexPoolState memory);

    /// @notice Retrieves raw position data for a liquidity position
    /// @param dexType The type of DEX (3 for D3, 4 for D4)
    /// @param dexKey The pool identification parameters
    /// @param user The position owner address
    /// @param tickLower The lower tick boundary of the position
    /// @param tickUpper The upper tick boundary of the position
    /// @param positionSalt Unique salt to differentiate positions with same parameters
    /// @return Position data including liquidity and fee growth values
    function getPositionData(
        uint256 dexType,
        IFluidDexV2.DexKey memory dexKey,
        address user,
        int24 tickLower,
        int24 tickUpper,
        bytes32 positionSalt
    ) external view returns (PositionData memory);

    /// @notice Retrieves detailed position info including token amounts and accrued fees
    /// @param dexType The type of DEX (3 for D3, 4 for D4)
    /// @param dexKey The pool identification parameters
    /// @param user The position owner address
    /// @param tickLower The lower tick boundary of the position
    /// @param tickUpper The upper tick boundary of the position
    /// @param positionSalt Unique salt to differentiate positions with same parameters
    /// @return Complete position info with amounts and fees for both tokens
    function getPositionInfo(
        uint256 dexType,
        IFluidDexV2.DexKey memory dexKey,
        address user,
        int24 tickLower,
        int24 tickUpper,
        bytes32 positionSalt
    ) external view returns (PositionInfo memory);

    /// @notice Retrieves liquidity distribution across a tick range
    /// @param dexType The type of DEX (Two possibilities: 3 for D3, 4 for D4)
    /// @param dexKey The pool identification parameters
    /// @param startTick The starting tick for the analysis
    /// @param endTick The ending tick for the analysis
    /// @param startLiquidity The liquidity at the start tick
    /// @return Array of TickLiquidity structs showing liquidity at each tick
    function getLiquidityAmounts(
        uint256 dexType,
        IFluidDexV2.DexKey memory dexKey,
        int24 startTick,
        int24 endTick,
        uint256 startLiquidity
    ) external view returns (TickLiquidity[] memory);
}
