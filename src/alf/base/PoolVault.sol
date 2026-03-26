// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IERC20Minimal} from "@uniswap/v4-core/src/interfaces/external/IERC20Minimal.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";

/// @title PoolVault
/// @notice Multi-asset vault for v4 pool hooks, inspired by ERC4626.
///
///         Manages proportional share accounting across a pool's two currencies,
///         with per-pool isolation of vault shares, ERC-6909 claims, and ERC-20 balances.
///         Designed as a reusable base for any rehypothecating hook that needs:
///
///           - LP deposit/withdraw with share-based accounting
///           - ERC4626 vault rehypothecation (assets earn yield between swaps)
///           - Per-pool ERC-6909 claim tracking (deferred settlement from JIT cycles)
///
///         Unlike ERC4626, shares are non-transferable internal accounting — each pool
///         has its own share supply tracked via mappings, not an ERC20 token.
///
/// @dev    Subclasses provide:
///           - `_poolManager()`: access to the v4 PoolManager (for claim ops)
///           - Authorization logic for deposits/withdrawals
///           - JIT lifecycle that calls _depositAllToVaults / _withdrawAllFromVaults
abstract contract PoolVault {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;

    // ──── Per-Pool State ────

    /// @notice ERC4626 vault per (pool, currency). address(0) = no vault (ERC-20 held directly).
    mapping(PoolId => mapping(Currency => IERC4626)) public vaults;

    /// @notice Total shares outstanding per pool.
    mapping(PoolId => uint256) public totalShares;

    /// @notice Share balance per (pool, user).
    mapping(PoolId => mapping(address => uint256)) public userShares;

    /// @dev Per-pool vault share tracking. Isolates multi-pool deployments sharing a vault.
    mapping(PoolId => mapping(Currency => uint256)) internal _vaultShares;

    /// @dev Per-pool ERC-6909 claim tracking. Accumulated in afterSwap, redeemed in beforeSwap.
    mapping(PoolId => mapping(Currency => uint256)) internal _claims;

    /// @dev Per-pool ERC-20 tracking for currencies without a vault.
    mapping(PoolId => mapping(Currency => uint256)) internal _erc20;

    // ──── Events ────

    event Deposit(PoolId indexed poolId, address indexed provider, uint256 shares, uint256 amount0, uint256 amount1);
    event Withdraw(PoolId indexed poolId, address indexed provider, uint256 shares, uint256 amount0, uint256 amount1);

    // ──── Errors ────

    error InsufficientShares();

    // ═══════════════════════════════════════════════════════════════════════════
    //                          VIEW: ASSET ACCOUNTING
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Total managed assets for a pool (both currencies).
    function totalAssets(PoolKey calldata key) external view returns (uint256 amount0, uint256 amount1) {
        return _totalAssets(key);
    }

    /// @notice Preview the token amounts required to mint `shares`.
    /// @dev    Rounds up to prevent share dilution.
    function previewDeposit(PoolKey calldata key, uint256 shares)
        external
        view
        returns (uint256 amount0, uint256 amount1)
    {
        return _convertToAmounts(key, shares, true);
    }

    /// @notice Preview the token amounts returned for burning `shares`.
    /// @dev    Rounds down to prevent over-withdrawal.
    function previewWithdraw(PoolKey calldata key, uint256 shares)
        external
        view
        returns (uint256 amount0, uint256 amount1)
    {
        return _convertToAmounts(key, shares, false);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    //                          INTERNAL: DEPOSIT / WITHDRAW
    // ═══════════════════════════════════════════════════════════════════════════

    /// @dev Mint shares to `to` by pulling proportional tokens from `from`.
    ///      Tokens are deposited to vaults (or tracked as ERC-20 if no vault).
    function _deposit(PoolKey calldata key, address from, address to, uint256 shares)
        internal
        returns (uint256 amount0, uint256 amount1)
    {
        (amount0, amount1) = _convertToAmounts(key, shares, true);
        PoolId poolId = key.toId();

        if (amount0 > 0) IERC20Minimal(Currency.unwrap(key.currency0)).transferFrom(from, address(this), amount0);
        if (amount1 > 0) IERC20Minimal(Currency.unwrap(key.currency1)).transferFrom(from, address(this), amount1);

        _depositToVault(poolId, key.currency0, amount0);
        _depositToVault(poolId, key.currency1, amount1);

        totalShares[poolId] += shares;
        userShares[poolId][to] += shares;

        emit Deposit(poolId, to, shares, amount0, amount1);
    }

    /// @dev Burn shares from `from` and send proportional tokens to `to`.
    function _withdraw(PoolKey calldata key, address from, address to, uint256 shares)
        internal
        returns (uint256 amount0, uint256 amount1)
    {
        PoolId poolId = key.toId();
        if (userShares[poolId][from] < shares) revert InsufficientShares();

        (amount0, amount1) = _convertToAmounts(key, shares, false);

        totalShares[poolId] -= shares;
        userShares[poolId][from] -= shares;

        _ensureERC20(poolId, key.currency0, amount0);
        _ensureERC20(poolId, key.currency1, amount1);

        if (amount0 > 0) IERC20Minimal(Currency.unwrap(key.currency0)).transfer(to, amount0);
        if (amount1 > 0) IERC20Minimal(Currency.unwrap(key.currency1)).transfer(to, amount1);

        emit Withdraw(poolId, from, shares, amount0, amount1);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    //                          INTERNAL: SHARE MATH
    // ═══════════════════════════════════════════════════════════════════════════

    /// @dev Convert shares to proportional token amounts.
    ///      First deposit (totalShares == 0): 1 share = 1 unit of each token.
    ///      `roundUp`: true for deposits (prevents dilution), false for withdrawals.
    function _convertToAmounts(PoolKey memory key, uint256 shares, bool roundUp)
        internal
        view
        returns (uint256 amount0, uint256 amount1)
    {
        PoolId poolId = key.toId();
        uint256 supply = totalShares[poolId];
        if (supply == 0) return (shares, shares);

        (uint256 total0, uint256 total1) = _totalAssets(key);
        if (roundUp) {
            amount0 = FixedPointMathLib.fullMulDivUp(shares, total0, supply);
            amount1 = FixedPointMathLib.fullMulDivUp(shares, total1, supply);
        } else {
            amount0 = FixedPointMathLib.fullMulDiv(shares, total0, supply);
            amount1 = FixedPointMathLib.fullMulDiv(shares, total1, supply);
        }
    }

    // ═══════════════════════════════════════════════════════════════════════════
    //                          INTERNAL: ASSET TRACKING
    // ═══════════════════════════════════════════════════════════════════════════

    /// @dev Total managed assets across both currencies for a pool.
    function _totalAssets(PoolKey memory key) internal view returns (uint256 amount0, uint256 amount1) {
        PoolId poolId = key.toId();
        amount0 = _assetBalance(poolId, key.currency0);
        amount1 = _assetBalance(poolId, key.currency1);
    }

    /// @dev Per-pool balance for a single currency: vault assets + claims + ERC-20.
    function _assetBalance(PoolId poolId, Currency currency) internal view returns (uint256 bal) {
        bal = _claims[poolId][currency] + _erc20[poolId][currency];
        IERC4626 vault = vaults[poolId][currency];
        if (address(vault) != address(0)) {
            uint256 shares = _vaultShares[poolId][currency];
            if (shares > 0) bal += vault.convertToAssets(shares);
        }
    }

    // ═══════════════════════════════════════════════════════════════════════════
    //                          INTERNAL: VAULT OPERATIONS
    // ═══════════════════════════════════════════════════════════════════════════

    /// @dev Deposit amount into the pool's vault. If no vault, track as per-pool ERC-20.
    function _depositToVault(PoolId poolId, Currency currency, uint256 amount) internal {
        if (amount == 0) return;
        IERC4626 vault = vaults[poolId][currency];
        if (address(vault) == address(0)) {
            _erc20[poolId][currency] += amount;
            return;
        }
        IERC20Minimal(Currency.unwrap(currency)).approve(address(vault), amount);
        uint256 shares = vault.deposit(amount, address(this));
        _vaultShares[poolId][currency] += shares;
    }

    /// @dev Withdraw all redeemable vault shares for both currencies. Caps at maxRedeem.
    function _withdrawAllFromVaults(PoolId poolId, PoolKey calldata key) internal {
        _withdrawAllFromVault(poolId, key.currency0);
        _withdrawAllFromVault(poolId, key.currency1);
    }

    /// @dev Withdraw all redeemable shares for a single (pool, currency).
    function _withdrawAllFromVault(PoolId poolId, Currency currency) internal {
        IERC4626 vault = vaults[poolId][currency];
        if (address(vault) == address(0)) return;
        uint256 shares = _vaultShares[poolId][currency];
        if (shares == 0) return;

        uint256 maxRedeemable = vault.maxRedeem(address(this));
        uint256 toRedeem = shares > maxRedeemable ? maxRedeemable : shares;
        if (toRedeem == 0) return;

        vault.redeem(toRedeem, address(this), address(this));
        _vaultShares[poolId][currency] -= toRedeem;
    }

    /// @dev Deposit all hook ERC-20 for both currencies into their vaults.
    function _depositAllToVaults(PoolId poolId, PoolKey calldata key) internal {
        _depositAllToVault(poolId, key.currency0);
        _depositAllToVault(poolId, key.currency1);
    }

    /// @dev Deposit hook's ERC-20 balance into vault, or track per-pool.
    function _depositAllToVault(PoolId poolId, Currency currency) internal {
        uint256 bal = IERC20Minimal(Currency.unwrap(currency)).balanceOf(address(this));
        if (bal == 0) return;
        IERC4626 vault = vaults[poolId][currency];
        if (address(vault) == address(0)) {
            _erc20[poolId][currency] += bal;
            return;
        }
        IERC20Minimal(Currency.unwrap(currency)).approve(address(vault), bal);
        uint256 shares = vault.deposit(bal, address(this));
        _vaultShares[poolId][currency] += shares;
    }

    /// @dev Ensure hook holds enough ERC-20 for a transfer. Pulls from vault if needed.
    function _ensureERC20(PoolId poolId, Currency currency, uint256 amount) internal {
        IERC4626 vault = vaults[poolId][currency];
        if (address(vault) == address(0)) {
            _erc20[poolId][currency] -= amount;
            return;
        }
        uint256 bal = IERC20Minimal(Currency.unwrap(currency)).balanceOf(address(this));
        if (bal >= amount) return;

        uint256 shares = vault.previewWithdraw(amount - bal);
        uint256 poolShares = _vaultShares[poolId][currency];
        if (shares > poolShares) shares = poolShares;
        vault.redeem(shares, address(this), address(this));
        _vaultShares[poolId][currency] -= shares;
    }

    // ═══════════════════════════════════════════════════════════════════════════
    //                          INTERNAL: CLAIM MANAGEMENT
    // ═══════════════════════════════════════════════════════════════════════════

    /// @dev Redeem this pool's ERC-6909 claims to ERC-20 via the PoolManager.
    ///      Only callable within an unlock context (swap callbacks).
    function _redeemPoolClaims(PoolId poolId, Currency currency) internal {
        uint256 claimBal = _claims[poolId][currency];
        if (claimBal > 0) {
            _poolManager().burn(address(this), currency.toId(), claimBal);
            _poolManager().take(currency, address(this), claimBal);
            _claims[poolId][currency] = 0;
        }
    }

    /// @dev Record pool claims after minting ERC-6909 on the PoolManager.
    function _recordClaims(PoolId poolId, Currency currency, uint256 amount) internal {
        _claims[poolId][currency] += amount;
    }

    /// @dev Clear per-pool ERC-20 tracking (e.g., when deploying all assets as LP).
    function _clearERC20Tracking(PoolId poolId, Currency currency) internal {
        _erc20[poolId][currency] = 0;
    }

    // ═══════════════════════════════════════════════════════════════════════════
    //                          ABSTRACT: POOL MANAGER ACCESS
    // ═══════════════════════════════════════════════════════════════════════════

    /// @dev Subclasses must provide access to the PoolManager for claim operations.
    function _poolManager() internal view virtual returns (IPoolManager);
}
