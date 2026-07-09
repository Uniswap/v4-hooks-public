// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "solmate/src/tokens/ERC20.sol";
import {SafeTransferLib} from "solmate/src/utils/SafeTransferLib.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BaseTokenWrapperHook} from "./base/BaseTokenWrapperHook.sol";

/// @title ERC-4626 Wrapper Hook
/// @notice Hook for wrapping/unwrapping an ERC-4626 vault's asset into its shares in Uniswap V4 pools
/// @dev The vault's share token is the wrapper currency; vault.asset() is the underlying. The
/// @dev share/asset rate is dynamic and read live from the vault, exactly analogous to the
/// @dev stETH <-> wstETH exchange rate handled by WstETHHook.
/// @dev Safely handles rebasing / fee-on-transfer underlyings by measuring actual balances.
contract ERC4626WrapperHook is BaseTokenWrapperHook {
    using SafeTransferLib for ERC20;

    /// @notice The ERC-4626 vault. Its share token is the wrapper currency and its asset is the underlying.
    IERC4626 public immutable vault;

    /// @notice Creates a new ERC-4626 wrapper hook
    /// @param _manager The Uniswap V4 pool manager
    /// @param _vault The ERC-4626 vault whose asset <-> shares this hook wraps/unwraps
    /// @dev Initializes with the vault's shares as the wrapper token and vault.asset() as the underlying token
    constructor(IPoolManager _manager, IERC4626 _vault)
        BaseTokenWrapperHook(
            _manager,
            Currency.wrap(address(_vault)), // wrapper token: vault shares
            Currency.wrap(_vault.asset()) // underlying token: vault asset
        )
    {
        vault = _vault;
        // the vault pulls the underlying asset from this hook during deposit()
        ERC20(Currency.unwrap(underlyingCurrency)).safeApprove(address(_vault), type(uint256).max);
    }

    /// @inheritdoc BaseTokenWrapperHook
    function _deposit(uint256 underlyingAmount)
        internal
        virtual
        override
        returns (uint256 actualUnderlyingAmount, uint256 wrappedAmount)
    {
        // pull the underlying asset out of the PoolManager
        _take(underlyingCurrency, address(this), underlyingAmount);
        // a rebasing / fee-on-transfer underlying can deliver less than requested;
        // wrap exactly what we actually received
        actualUnderlyingAmount = ERC20(Currency.unwrap(underlyingCurrency)).balanceOf(address(this));
        // deposit into the vault; shares are minted to this hook
        wrappedAmount = vault.deposit(actualUnderlyingAmount, address(this));
        // pay the minted shares back to the PoolManager
        _settle(wrapperCurrency, address(this), wrappedAmount);
    }

    /// @inheritdoc BaseTokenWrapperHook
    function _withdraw(uint256 wrappedAmount)
        internal
        override
        returns (uint256 actualWrappedAmount, uint256 underlyingAmount)
    {
        // pull the wrapper (vault shares) out of the PoolManager
        _take(wrapperCurrency, address(this), wrappedAmount);
        actualWrappedAmount = wrappedAmount; // shares are non-rebasing: exact
        // redeem shares for the underlying asset, received by this hook
        uint256 redeemed = vault.redeem(wrappedAmount, address(this), address(this));

        // settle the underlying to the PoolManager, measuring the credited amount to
        // absorb any rebasing transfer rounding (mirrors WstETHHook)
        ERC20 underlying = ERC20(Currency.unwrap(underlyingCurrency));
        uint256 poolManagerBalanceBefore = underlying.balanceOf(address(poolManager));
        _settle(underlyingCurrency, address(this), redeemed);
        uint256 poolManagerBalanceAfter = underlying.balanceOf(address(poolManager));

        underlyingAmount = poolManagerBalanceAfter - poolManagerBalanceBefore;
    }

    /// @inheritdoc BaseTokenWrapperHook
    /// @notice Calculates how much underlying is needed to mint a specific amount of shares
    /// @param wrappedAmount Desired amount of vault shares
    /// @return Amount of underlying asset required
    /// @dev Dormant while exact-output is disabled; provided for completeness and future use
    function _getWrapInputRequired(uint256 wrappedAmount) internal view override returns (uint256) {
        return vault.previewMint(wrappedAmount);
    }

    /// @inheritdoc BaseTokenWrapperHook
    /// @notice Calculates how many shares are needed to withdraw a specific amount of underlying
    /// @param underlyingAmount Desired amount of underlying asset
    /// @return Amount of vault shares required
    function _getUnwrapInputRequired(uint256 underlyingAmount) internal view override returns (uint256) {
        return vault.previewWithdraw(underlyingAmount);
    }

    /// @inheritdoc BaseTokenWrapperHook
    /// @dev Exact-output is unsafe under the base's _deposit-only path: ERC-4626 deposit() rounds
    /// @dev shares down, and a rebasing underlying can round the take/settle, either of which can
    /// @dev leave the hook a wei short of the exact requested output and break settlement.
    function _supportsExactOutput() internal pure override returns (bool) {
        return false;
    }
}
