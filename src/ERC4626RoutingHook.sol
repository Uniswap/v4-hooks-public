// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {ERC4626WrapperHook, BaseTokenWrapperHook, Currency} from "./ERC4626WrapperHook.sol";

/// @title ERC4626RoutingHook
/// @notice A hook that allows simulating the ERC4626WrapperHook with the v4 Quoter
/// @dev The ERC4626WrapperHook takes the amount deposited by the swapper into the PoolManager and
/// deposits it into the vault. When simulating the ERC4626WrapperHook, no underlying is deposited
/// into the PoolManager and the ERC4626WrapperHook reverts. This hook acts as a replacement for the
/// ERC4626WrapperHook in the Quoter and calculates the amount of shares that would be minted by the
/// ERC4626WrapperHook, without executing the actual deposit.
/// @dev The withdraw function doesn't need to be overridden, as the PoolManager has a sufficient
/// balance of shares to cover the withdrawal in the simulation.
contract ERC4626RoutingHook is ERC4626WrapperHook {
    constructor(IPoolManager _poolManager, IERC4626 _vault) ERC4626WrapperHook(_poolManager, _vault) {}

    /// @inheritdoc BaseTokenWrapperHook
    function _deposit(uint256 underlyingAmount)
        internal
        view
        override
        returns (uint256 actualUnderlyingAmount, uint256 wrappedAmount)
    {
        // simulate the wrap without moving any tokens.
        // previewDeposit applies the vault's own rounding and returns the shares
        // that deposit() would mint for `underlyingAmount` of the underlying.
        actualUnderlyingAmount = underlyingAmount;
        wrappedAmount = vault.previewDeposit(underlyingAmount);
    }
}
