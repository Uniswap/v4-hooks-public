// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "solmate/src/tokens/ERC20.sol";
import {SafeTransferLib} from "solmate/src/utils/SafeTransferLib.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BaseTokenWrapperHook} from "./base/BaseTokenWrapperHook.sol";

/// @title ERC-4626 Wrapper Hook
/// @notice Hook for wrapping/unwrapping generic ERC-4626 vault assets into their shares in Uniswap V4 pools
/// @dev The vault share token is the wrapper currency, and vault.asset() is the underlying currency.
///      The vault determines the exchange rate between them.
contract ERC4626WrapperHook is BaseTokenWrapperHook {
    using SafeTransferLib for ERC20;

    IERC4626 public immutable vault;

    /// @notice Creates a new ERC-4626 wrapper hook
    /// @param _manager The Uniswap V4 pool manager
    /// @param _vault The ERC-4626 vault whose asset this hook wraps/unwraps
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
        // Rebasing and fee-on-transfer assets may deliver less than the amount taken.
        _take(underlyingCurrency, address(this), underlyingAmount);
        actualUnderlyingAmount = ERC20(Currency.unwrap(underlyingCurrency)).balanceOf(address(this));
        wrappedAmount = vault.deposit(actualUnderlyingAmount, address(this));
        _settle(wrapperCurrency, address(this), wrappedAmount);
    }

    /// @inheritdoc BaseTokenWrapperHook
    function _withdraw(uint256 wrappedAmount)
        internal
        override
        returns (uint256 actualWrappedAmount, uint256 underlyingAmount)
    {
        _take(wrapperCurrency, address(this), wrappedAmount);
        actualWrappedAmount = wrappedAmount; // shares do not rebase
        uint256 redeemed = vault.redeem(wrappedAmount, address(this), address(this));

        // Measure the manager's balance delta because rebasing assets can round transfers down.
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
    /// @dev Exact-output is disabled because the hook cannot mint an exact number of shares, and
    /// @dev the PoolManager reverts unless every delta is settled. Using `deposit` does not
    /// @dev guarantee the exact requested shares are received.
    function _supportsExactOutput() internal pure override returns (bool) {
        return false;
    }
}
