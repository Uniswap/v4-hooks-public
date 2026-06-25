// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {TransientStateLibrary} from "@uniswap/v4-core/src/libraries/TransientStateLibrary.sol";
import {InventoryLib} from "./InventoryLib.sol";

/// @title SettlementLib
/// @author Uniswap Labs
/// @notice The single net-delta settlement authority for ALF hooks that custody inventory via
///         `InventoryLib`. Under v4 flash accounting every currency delta must net to zero
///         before an `unlock` finalizes, so exactly one actor may call
///         `settle` / `take` / `mint` / `burn` for delta resolution — that actor is this
///         library. Composed capabilities never settle on their own; they mutate their
///         `InventoryLib` bucket (deposit, withdraw, fee skim, ...) and let the net delta flow
///         through {resolveCurrency}, which settles or parks it ONCE per currency.
///
///         This is the keystone that lets multiple fund-touching capabilities coexist in one
///         hook: each expresses its effect as a bucket adjustment, and a single resolve nets the
///         combined position so the capabilities cannot fight over the shared `currencyDelta`.
///
///         ## Resolution
///
///         For each currency, after all in-cycle operations have run:
///           - **negative delta** (hook owes the PoolManager): settle from the hook's raw balance
///             (sync → transfer → settle, or `settle{value}` for native ETH) and debit the
///             bucket's raw ledger.
///           - **positive delta** (PoolManager owes the hook): the swapper has not settled yet, so
///             mint ERC-6909 claims instead of `take`-ing, and record them on the bucket. The
///             claims redeem to raw on the next cycle via `InventoryLib.redeemClaims`.
///
///         Internal library functions are inlined into the consumer, so `address(this)` and token
///         custody refer to the consuming hook.
/// @custom:security-contact security@uniswap.org
library SettlementLib {
    using CurrencyLibrary for Currency;
    using TransientStateLibrary for IPoolManager;
    using InventoryLib for InventoryLib.Inventory;

    /// @notice Resolve the hook's net delta for a single `currency` against an `InventoryLib`
    ///         bucket: settle a debit from the bucket's raw balance, or mint claims for a credit.
    /// @dev MUST be called inside the v4 unlock once the cycle's operations are complete, and is
    ///      the ONLY delta-resolution path that touches `settle` / `mint`. A negative delta
    ///      settles `owed` of the hook's raw balance and debits the bucket (reverts
    ///      `InventoryLib.InsufficientPoolBalance` if the bucket's raw ledger is short). A
    ///      positive delta mints ERC-6909 claims (rather than `take`, since the swapper's input
    ///      is not yet settled) and records them on the bucket.
    /// @param poolManager The v4 PoolManager to settle against.
    /// @param bucket      The `InventoryLib` accounting partition backing this (pool, currency).
    /// @param currency    The currency whose net delta to resolve.
    function resolveCurrency(IPoolManager poolManager, bytes32 bucket, Currency currency) internal {
        int256 delta = poolManager.currencyDelta(address(this), currency);
        if (delta < 0) {
            uint256 owed = uint256(-delta);
            if (currency.isAddressZero()) {
                poolManager.settle{value: owed}();
            } else {
                poolManager.sync(currency);
                currency.transfer(address(poolManager), owed);
                poolManager.settle();
            }
            InventoryLib.load().debitERC20(bucket, owed);
        } else if (delta > 0) {
            uint256 amount = uint256(delta);
            poolManager.mint(address(this), currency.toId(), amount);
            InventoryLib.load().recordClaims(bucket, amount);
        }
    }
}
