// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {SpreadQuoterBase} from "./base/SpreadQuoterBase.sol";

/// @title SimpleSpreadQuoterHook
/// @author Uniswap Labs
/// @notice Bid/ask spread quoter with owner-restricted LP. Only authorized addresses
///         can add or remove liquidity, and all LP must be concentrated in a single
///         tick spacing at the active tick. Owner controls pricing via fee overrides
///         and signed hookData curve updates.
/// @custom:security-contact security@uniswap.org
contract SimpleSpreadQuoterHook is SpreadQuoterBase {
    /// @notice Whether an address is authorized to add or remove pool liquidity.
    mapping(address => bool) public authorizedLPs;

    /// @notice Emitted when an LP's authorization is granted or revoked by the owner.
    /// @param lp         The LP address whose authorization changed.
    /// @param authorized True if the LP can now add/remove liquidity, false if revoked.
    event AuthorizedLPUpdated(address indexed lp, bool authorized);

    /// @dev Caller is not in the `authorizedLPs` allowlist.
    error UnauthorizedLP();

    /// @param _poolManager The Uniswap v4 PoolManager.
    /// @param maxGas_      Gas budget declared for `getIndicativeQuote` staticcalls.
    /// @param owner_       Initial contract owner (Ownable2Step).
    constructor(IPoolManager _poolManager, uint32 maxGas_, address owner_)
        SpreadQuoterBase(_poolManager, maxGas_, owner_, "SimpleSpreadQuoterHook")
    {}

    // ──── Hook Permissions ────

    /// @notice The v4 hook permissions for this contract.
    /// @dev    `afterInitialize` registers the active tick; `beforeAddLiquidity` /
    ///         `beforeRemoveLiquidity` enforce the LP allowlist; `beforeSwap` applies
    ///         the directional fee override and applies any signed curve updates.
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

    function _beforeRemoveLiquidity(address sender, PoolKey calldata, ModifyLiquidityParams calldata, bytes calldata)
        internal
        view
        override
        returns (bytes4)
    {
        if (!authorizedLPs[sender]) revert UnauthorizedLP();
        return IHooks.beforeRemoveLiquidity.selector;
    }

    // ──── Owner Functions ────

    /// @notice Authorize or revoke an address for LP operations.
    /// @dev    Only the owner may toggle authorization. Emits {AuthorizedLPUpdated}.
    /// @param lp         The address to authorize or revoke.
    /// @param authorized True to grant LP access, false to revoke.
    function setAuthorizedLP(address lp, bool authorized) external onlyOwner {
        authorizedLPs[lp] = authorized;
        emit AuthorizedLPUpdated(lp, authorized);
    }
}
