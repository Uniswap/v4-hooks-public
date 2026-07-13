// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {DualPoolHook} from "./DualPoolHook.sol";
import {VaultId} from "./types/VaultId.sol";
import {Rewards} from "./types/Rewards.sol";

/// @title DualPoolIncentivizedHook
/// @author Uniswap Labs
/// @notice `DualPoolHook` composed with the `Rewards` liquidity-incentives capability. LP shares
///         earn a third reward token via Synthetix-style per-block accrual on the `BlockNumberish`
///         clock, on top of the JIT spread quoting and ERC-4626 rehypothecation inherited unchanged
///         from `DualPoolHook`.
///
///         The composition adds no new v4 hook callback, so the permission flags (and the
///         address-mining requirement) are identical to `DualPoolHook`; it does not touch the
///         swap path; and it reuses the base's share ledger. The `Rewards` capability is held as a
///         plain storage field (`_rewards`), and its behavior is invoked on it directly via
///         type-driven free functions, as `_rewards.checkpoint(...)`. It wires
///         `PoolVault._onShareCheckpoint` (which fires on bootstrap, deposit, and withdraw, before
///         the share counts move) to `Rewards.checkpoint`, so accrual settles when LP positions
///         change.
///
///         ## Trust model
///
///         Adds one capability to the operator surface: funding rewards. The owner binds a reward
///         token ({setRewardToken}, permanent), sets the period cadence ({setRewardsDuration}),
///         and funds periods ({notifyRewardAmount}, pulling the reward token from the caller). The
///         owner cannot touch accrued LP rewards; only the earning LP can {claimRewards}.
///
///         Reward-token custody is kept disjoint from pool inventory hook-wide: a reward token may
///         not be any initialized pool's currency, and a pool may not be initialized on a currency
///         already bound as a reward token (enforced in both {setRewardToken} and
///         {_onPoolInitialized}). So a reward payout never aliases the ERC-20 inventory
///         `InventoryLib` tracks for any pool. A single reward token MAY incentivize several pools;
///         each pool reserves the tokens funded to it (`Reward.committed`) and its rate is bounded
///         against only the balance not reserved by sibling pools, so one pool's rewards are always
///         funded from its own contributions and can never be drained by another pool's claims (see
///         {Rewards} "Shared-token solvency"). Together these close M-01.
/// @custom:security-contact security@uniswap.org
contract DualPoolIncentivizedHook is DualPoolHook {
    using PoolIdLibrary for PoolKey;
    using SafeERC20 for IERC20;

    /// @notice Liquidity-incentives capability storage: a Synthetix reward program per pool vault.
    Rewards internal _rewards;

    /// @notice Hook-wide set of every initialized pool's currencies. A reward token is rejected
    ///         against this set so reward custody never aliases any pool's ERC-20 inventory (M-01).
    mapping(address token => bool) private _isPoolCurrency;
    /// @notice Hook-wide set of every bound reward token. Pool initialization is rejected against
    ///         this set so a new pool's currency can never alias an existing reward token (the
    ///         reverse of the {setRewardToken} guard, keeping the two sets disjoint at all times).
    mapping(address token => bool) private _isRewardToken;

    /// @dev `notifyRewardAmount` was called before a reward token was bound via {setRewardToken}.
    error RewardTokenNotConfigured();
    /// @dev `setRewardToken` was given a token that is one of this pool's currencies, or any other
    ///      initialized pool's currency. The reward token must be disjoint from every pool currency
    ///      hook-wide so reward custody never aliases `InventoryLib`'s per-pool ERC-20 ledger.
    error RewardTokenIsPoolCurrency();
    /// @dev `initializePool` was given a pool whose currency is already a bound reward token, which
    ///      would make that reward token's custody alias the new pool's inventory.
    error PoolCurrencyIsRewardToken();

    /// @param pm                  The Uniswap v4 PoolManager.
    /// @param maxGas_             Gas budget declared for `getIndicativeQuote` staticcalls.
    /// @param owner_              Initial owner (see {OwnedALFHook}).
    /// @param maxMinDepositBlocks_ Per-deployment upper bound on `PoolConfig.minDepositBlocks`.
    constructor(IPoolManager pm, uint32 maxGas_, address owner_, uint64 maxMinDepositBlocks_)
        DualPoolHook(pm, maxGas_, owner_, maxMinDepositBlocks_)
    {}

    // ═══════════════════════════════════════════════════════════════════════════
    //                        CAPABILITY WIRING
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Settle reward accrual on the pre-mutation balances. Overrides the `PoolVault`
    ///         checkpoint seam; fires on bootstrap, deposit, and withdraw, never on swaps.
    /// @param vaultId           The vault whose shares are about to change.
    /// @param user              The account whose share balance is about to change.
    /// @param totalSharesBefore Total shares outstanding immediately before the mutation.
    /// @param userSharesBefore  `user`'s share balance immediately before the mutation.
    function _onShareCheckpoint(VaultId vaultId, address user, uint256 totalSharesBefore, uint256 userSharesBefore)
        internal
        override
    {
        _rewards.checkpoint(vaultId, user, totalSharesBefore, userSharesBefore, _getBlockNumberish());
    }

    // ═══════════════════════════════════════════════════════════════════════════
    //                        OWNER: REWARD CONFIGURATION
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Bind the reward token for a pool. Permanent (accrued balances must resolve against
    ///         one token). Rejects any pool currency hook-wide: this pool's two currencies and every
    ///         other initialized pool's currencies. The same token MAY back multiple pools; each
    ///         pool's custody is reserved separately (see {Rewards} shared-token solvency).
    /// @param key   The pool to configure.
    /// @param token The reward ERC-20.
    function setRewardToken(PoolKey calldata key, IERC20 token) external onlyOwner whenJITNotInProgress {
        address t = address(token);
        // Reject this pool's own currencies (caught even before initializePool registers them) and,
        // hook-wide, any other initialized pool's currency. This keeps reward custody disjoint from
        // every pool's ERC-20 inventory, so a reward payout can never draw on pool principal (M-01).
        if (Currency.unwrap(key.currency0) == t || Currency.unwrap(key.currency1) == t || _isPoolCurrency[t]) {
            revert RewardTokenIsPoolCurrency();
        }
        // Record the token so a later initializePool cannot introduce it as a pool currency. Marking
        // is idempotent: binding the same token to several pools is supported and stays solvent via
        // per-vault reservations in `Rewards`.
        _isRewardToken[t] = true;
        _rewards.setRewardToken(_vaultIdFor(key.toId()), token);
    }

    /// @inheritdoc DualPoolHook
    /// @dev Enforces the reverse of the {setRewardToken} guard: a newly-initialized pool must not
    ///      introduce a currency that is already a bound reward token, or that token's custody would
    ///      alias the new pool's inventory. Registers both currencies so future reward-token binds
    ///      are rejected against them. Together the two guards keep the pool-currency and
    ///      reward-token sets disjoint hook-wide at all times.
    function _onPoolInitialized(PoolKey calldata key) internal override {
        address c0 = Currency.unwrap(key.currency0);
        address c1 = Currency.unwrap(key.currency1);
        if (_isRewardToken[c0] || _isRewardToken[c1]) revert PoolCurrencyIsRewardToken();
        _isPoolCurrency[c0] = true;
        _isPoolCurrency[c1] = true;
    }

    /// @notice Set the reward period length for a pool. Only permitted between periods.
    /// @param key      The pool to configure.
    /// @param duration Period length in blocks (on the `BlockNumberish` clock).
    function setRewardsDuration(PoolKey calldata key, uint256 duration) external onlyOwner whenJITNotInProgress {
        _rewards.setRewardsDuration(_vaultIdFor(key.toId()), duration, _getBlockNumberish());
    }

    /// @notice Fund a reward period for a pool (or top up the active one). Pulls `reward` of the
    ///         configured reward token from the caller, then recomputes the per-block rate.
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
        _rewards.notifyRewardAmount(
            id, reward, _shares.totalSupply(id), token.balanceOf(address(this)), _getBlockNumberish()
        );
    }

    // ═══════════════════════════════════════════════════════════════════════════
    //                        USER: CLAIM + VIEW
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Claim accrued reward tokens for the caller on a pool.
    /// @dev `whenJITNotInProgress` is conservative gating: a claim only touches the non-pool reward
    ///      token and the `Rewards` ledger, never the JIT-managed pool currencies. Since the claim
    ///      makes an external `safeTransfer`, the blanket JIT guard is the simplest safe choice. The
    ///      cost is that a claim reverts while any pool's swap is mid-flight, a minor liveness
    ///      coupling rather than a safety issue.
    /// @param key The pool to claim from.
    /// @return amount Reward tokens transferred to the caller.
    function claimRewards(PoolKey calldata key) external nonReentrant whenJITNotInProgress returns (uint256 amount) {
        VaultId id = _vaultIdFor(key.toId());
        amount = _rewards.claim(
            id, msg.sender, _shares.totalSupply(id), _shares.balanceOf(id, msg.sender), _getBlockNumberish()
        );
    }

    /// @notice Reward tokens `user` could claim right now on a pool.
    /// @param key  The pool to read.
    /// @param user The account to query.
    /// @return The claimable reward amount.
    function earned(PoolKey calldata key, address user) external view returns (uint256) {
        VaultId id = _vaultIdFor(key.toId());
        return _rewards.earned(id, user, _shares.totalSupply(id), _shares.balanceOf(id, user), _getBlockNumberish());
    }
}
