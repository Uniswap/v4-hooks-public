// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "solmate/src/tokens/ERC20.sol";
import {SafeTransferLib} from "solmate/src/utils/SafeTransferLib.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BaseTokenWrapperHook} from "./base/BaseTokenWrapperHook.sol";

/// @title ERC-4626 Wrapper Hook
/// @notice Hook for wrapping/unwrapping ERC-4626 vault assets/shares in Uniswap V4 pools
/// @dev The vault share token is the wrapper currency, vault.asset() is the underlying currency,
///      and the vault determines the exchange rate between them
/// @dev Fee-on-transfer underlying assets are not supported
contract ERC4626WrapperHook is BaseTokenWrapperHook {
    using SafeTransferLib for ERC20;

    IERC4626 public immutable vault;

    /// @notice The contract that deployed this hook. Canonical deployments go through the
    ///         ERC-4626 wrapper family's `AllowlistedFactory`, so aggregators and third-party
    ///         routers can verify a hook's provenance by checking `factory()` against the known
    ///         factory address (or asking the factory via `isFromFactory`) and can discover new
    ///         hooks from the factory's `Deployed` events. A hook deployed outside the factory
    ///         reports whatever address created it.
    address public immutable factory;

    error SettlementMismatch(uint256 measured, uint256 settled);

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
        factory = msg.sender;
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
        // Rebasing assets may deliver less than the amount taken.
        uint256 underlyingBefore = underlyingCurrency.balanceOf(address(this));
        _take(underlyingCurrency, address(this), underlyingAmount);
        actualUnderlyingAmount = underlyingCurrency.balanceOf(address(this)) - underlyingBefore;

        // Mint shares directly to the pool manager to avoid an extra transfer.
        uint256 managerSharesBefore = wrapperCurrency.balanceOf(address(poolManager));
        poolManager.sync(wrapperCurrency);
        vault.deposit(actualUnderlyingAmount, address(poolManager));
        wrappedAmount = wrapperCurrency.balanceOf(address(poolManager)) - managerSharesBefore;

        uint256 settled = poolManager.settle();
        if (settled != wrappedAmount) revert SettlementMismatch(wrappedAmount, settled);
    }

    /// @inheritdoc BaseTokenWrapperHook
    function _withdraw(uint256 wrappedAmount)
        internal
        override
        returns (uint256 actualWrappedAmount, uint256 underlyingAmount)
    {
        _take(wrapperCurrency, address(this), wrappedAmount);
        actualWrappedAmount = wrappedAmount; // shares do not rebase

        uint256 underlyingBefore = underlyingCurrency.balanceOf(address(this));
        vault.redeem(wrappedAmount, address(this), address(this));
        uint256 received = underlyingCurrency.balanceOf(address(this)) - underlyingBefore;

        // Rebasing assets can round transfers down, so send the full balance and let
        // settle measure the amount the pool manager received.
        uint256 managerUnderlyingBefore = underlyingCurrency.balanceOf(address(poolManager));
        poolManager.sync(underlyingCurrency);
        ERC20(Currency.unwrap(underlyingCurrency)).safeTransfer(address(poolManager), received);
        underlyingAmount = underlyingCurrency.balanceOf(address(poolManager)) - managerUnderlyingBefore;

        uint256 settled = poolManager.settle();
        if (settled != underlyingAmount) revert SettlementMismatch(underlyingAmount, settled);
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
    /// @dev Exact output is not supported because deposit() cannot mint an exact number of shares
    function _supportsExactOutput() internal pure override returns (bool) {
        return false;
    }
}
