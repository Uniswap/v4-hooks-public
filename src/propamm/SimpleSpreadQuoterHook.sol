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

/// @title SimpleSpreadQuoterHook
/// @notice Bid/ask spread quoter with owner-restricted LP. Only authorized addresses
///         can add or remove liquidity, and all LP must be concentrated in a single
///         tick spacing at the active tick. Owner controls pricing via fee overrides
///         and signed hookData curve updates.
contract SimpleSpreadQuoterHook is SpreadQuoterBase {
    mapping(address => bool) public authorizedLPs;

    event AuthorizedLPUpdated(address indexed lp, bool authorized);

    error UnauthorizedLP();

    constructor(
        IPoolManager _poolManager,
        IPropAMMIndex _index,
        IAttestationRegistry _attestationRegistry,
        uint32 maxGas_,
        address owner_
    )
        SpreadQuoterBase(
            _poolManager, _index, _attestationRegistry, maxGas_, owner_,
            "SimpleSpreadQuoterHook"
        )
    {}

    // ──── Hook Permissions ────

    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: false,
            afterInitialize: true, // register in index + auto-set active tick
            beforeAddLiquidity: true, // LP authorization + tick enforcement
            beforeRemoveLiquidity: true, // LP authorization
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

    // ──── LP Gating ────

    function _beforeAddLiquidity(
        address sender,
        PoolKey calldata key,
        ModifyLiquidityParams calldata params,
        bytes calldata
    ) internal view override returns (bytes4) {
        if (!authorizedLPs[sender]) revert UnauthorizedLP();
        _enforceActiveTick(key, params);
        return IHooks.beforeAddLiquidity.selector;
    }

    function _beforeRemoveLiquidity(
        address sender,
        PoolKey calldata,
        ModifyLiquidityParams calldata,
        bytes calldata
    ) internal view override returns (bytes4) {
        if (!authorizedLPs[sender]) revert UnauthorizedLP();
        return IHooks.beforeRemoveLiquidity.selector;
    }

    // ──── Owner Functions ────

    /// @notice Authorize or revoke an address for LP operations.
    function setAuthorizedLP(address lp, bool authorized) external onlyOwner {
        authorizedLPs[lp] = authorized;
        emit AuthorizedLPUpdated(lp, authorized);
    }
}
