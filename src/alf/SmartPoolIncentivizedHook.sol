// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {SmartPoolHook} from "./SmartPoolHook.sol";
import {VaultId} from "./types/VaultId.sol";
import {Rewards} from "./types/Rewards.sol";

/// @title SmartPoolIncentivizedHook
/// @author Uniswap Labs
/// @notice `SmartPoolHook` composed with the `Rewards` liquidity-incentives capability. LP shares
///         earn a third reward token via Synthetix-style per-second accrual, on top of the JIT
///         spread quoting and ERC-4626 rehypothecation inherited unchanged from `SmartPoolHook`.
///
///         The composition adds no new v4 hook callback, so the permission flags (and the
///         address-mining requirement) are identical to `SmartPoolHook`; it does not touch the
///         swap path; and it reuses the base's share ledger. The `Rewards` capability is held as a
///         plain storage field (`_rewards`), and its behavior is invoked on it directly via
///         type-driven free functions, as `_rewards.checkpoint(...)`. It wires
///         `MultiAssetVault._onShareCheckpoint` (which fires on bootstrap, deposit, and
///         withdraw, before the share counts move) to `Rewards.checkpoint`, so accrual settles
///         when LP positions change.
///
///         ## Trust model
///
///         Adds one capability to the operator surface: funding rewards. The owner binds a reward
///         token ({setRewardToken}, permanent), sets the period cadence ({setRewardsDuration}),
///         and funds periods ({notifyRewardAmount}, pulling the reward token from the caller). The
///         reward token MUST NOT be either pool currency, so reward custody never aliases the
///         pool's ERC-20 inventory tracked by `InventoryLib`. The owner cannot touch accrued LP
///         rewards; only the earning LP can {claimRewards}.
/// @custom:security-contact security@uniswap.org
contract SmartPoolIncentivizedHook is SmartPoolHook {
    using PoolIdLibrary for PoolKey;
    using SafeERC20 for IERC20;

    /// @notice Liquidity-incentives capability storage: a Synthetix reward program per pool vault.
    Rewards internal _rewards;

    /// @dev `notifyRewardAmount` was called before a reward token was bound via {setRewardToken}.
    error RewardTokenNotConfigured();
    /// @dev `setRewardToken` was given one of the pool's own currencies. The reward token must be
    ///      distinct so reward custody never aliases `InventoryLib`'s per-pool ERC-20 ledger.
    error RewardTokenIsPoolCurrency();

    /// @param pm                  The Uniswap v4 PoolManager.
    /// @param maxGas_             Gas budget declared for `getIndicativeQuote` staticcalls.
    /// @param owner_              Initial owner (see {SmartPoolBase}).
    /// @param maxMinDepositBlocks_ Per-deployment upper bound on `PoolConfig.minDepositBlocks`.
    constructor(IPoolManager pm, uint32 maxGas_, address owner_, uint64 maxMinDepositBlocks_)
        SmartPoolHook(pm, maxGas_, owner_, maxMinDepositBlocks_)
    {}

    // ═══════════════════════════════════════════════════════════════════════════
    //                        CAPABILITY WIRING
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Settle reward accrual on the pre-mutation balances. Overrides the `MultiAssetVault`
    ///         checkpoint seam; fires on bootstrap, deposit, and withdraw, never on swaps.
    /// @param vaultId           The vault whose shares are about to change.
    /// @param user              The account whose share balance is about to change.
    /// @param totalSharesBefore Total shares outstanding immediately before the mutation.
    /// @param userSharesBefore  `user`'s share balance immediately before the mutation.
    function _onShareCheckpoint(VaultId vaultId, address user, uint256 totalSharesBefore, uint256 userSharesBefore)
        internal
        override
    {
        _rewards.checkpoint(vaultId, user, totalSharesBefore, userSharesBefore);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    //                        OWNER: REWARD CONFIGURATION
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Bind the reward token for a pool. Permanent (accrued balances must resolve against
    ///         one token). Rejects either pool currency.
    /// @param key   The pool to configure.
    /// @param token The reward ERC-20.
    function setRewardToken(PoolKey calldata key, IERC20 token) external onlyOwner whenJITNotInProgress {
        if (Currency.unwrap(key.currency0) == address(token) || Currency.unwrap(key.currency1) == address(token)) {
            revert RewardTokenIsPoolCurrency();
        }
        _rewards.setRewardToken(_vaultIdFor(key.toId()), token);
    }

    /// @notice Set the reward period length for a pool. Only permitted between periods.
    /// @param key      The pool to configure.
    /// @param duration Period length in seconds.
    function setRewardsDuration(PoolKey calldata key, uint256 duration) external onlyOwner whenJITNotInProgress {
        _rewards.setRewardsDuration(_vaultIdFor(key.toId()), duration);
    }

    /// @notice Fund a reward period for a pool (or top up the active one). Pulls `reward` of the
    ///         configured reward token from the caller, then recomputes the per-second rate.
    /// @param key    The pool to fund.
    /// @param reward Reward tokens to add to the period.
    function notifyRewardAmount(PoolKey calldata key, uint256 reward)
        external
        onlyOwner
        nonReentrant
        whenJITNotInProgress
    {
        VaultId id = _vaultIdFor(key.toId());
        IERC20 token = _rewards.rewardTokenOf(id);
        if (address(token) == address(0)) revert RewardTokenNotConfigured();
        token.safeTransferFrom(msg.sender, address(this), reward);
        _rewards.notifyRewardAmount(id, reward, _totalShares[id], token.balanceOf(address(this)));
    }

    // ═══════════════════════════════════════════════════════════════════════════
    //                        USER: CLAIM + VIEW
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Claim accrued reward tokens for the caller on a pool.
    /// @param key The pool to claim from.
    /// @return amount Reward tokens transferred to the caller.
    function claimRewards(PoolKey calldata key) external nonReentrant whenJITNotInProgress returns (uint256 amount) {
        VaultId id = _vaultIdFor(key.toId());
        amount = _rewards.claim(id, msg.sender, _totalShares[id], _userShares[id][msg.sender]);
    }

    /// @notice Reward tokens `user` could claim right now on a pool.
    /// @param key  The pool to read.
    /// @param user The account to query.
    /// @return The claimable reward amount.
    function earned(PoolKey calldata key, address user) external view returns (uint256) {
        VaultId id = _vaultIdFor(key.toId());
        return _rewards.earned(id, user, _userShares[id][user], _totalShares[id]);
    }
}
