// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {SpreadQuoterBase} from "./base/SpreadQuoterBase.sol";
import {IPropAMMIndex} from "./interfaces/IPropAMMIndex.sol";
import {IAttestationRegistry} from "./interfaces/IAttestationRegistry.sol";

/// @title OpenLPQuoterHook
/// @notice Bid/ask spread quoter with open LP — anyone can provide liquidity,
///         but all positions must be concentrated in a single tick spacing at
///         the active tick. Owner controls pricing via fee overrides and signed
///         hookData curve updates.
contract OpenLPQuoterHook is SpreadQuoterBase {
    constructor(
        IPoolManager _poolManager,
        IPropAMMIndex _index,
        IAttestationRegistry _attestationRegistry,
        uint32 maxGas_,
        address owner_
    )
        SpreadQuoterBase(
            _poolManager, _index, _attestationRegistry, maxGas_, owner_,
            "OpenLPQuoterHook"
        )
    {}

    // ──── Hook Permissions ────

    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: false,
            afterInitialize: true, // register in index + auto-set active tick
            beforeAddLiquidity: true, // tick enforcement only
            beforeRemoveLiquidity: false, // anyone can remove freely
            afterAddLiquidity: false,
            afterRemoveLiquidity: false,
            beforeSwap: true, // fee override + curve updates
            afterSwap: false,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: false,
            afterSwapReturnDelta: false,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    // ──── LP Tick Enforcement ────

    function _beforeAddLiquidity(
        address,
        PoolKey calldata key,
        ModifyLiquidityParams calldata params,
        bytes calldata
    ) internal view override returns (bytes4) {
        _enforceActiveTick(key, params);
        return IHooks.beforeAddLiquidity.selector;
    }
}
