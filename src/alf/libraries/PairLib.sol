// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";

/// @title PairLib
/// @author Uniswap Labs
/// @notice Utility for canonicalizing currency pairs to ensure consistent storage ordering.
/// @custom:security-contact security@uniswap.org
library PairLib {
    /// @notice Returns the canonical ordering of a currency pair (c0 < c1).
    /// @dev    Sorts by the unwrapped address numeric value. Matches v4-core's `PoolKey`
    ///         ordering invariant.
    /// @param a One currency.
    /// @param b The other currency.
    /// @return c0 The currency with the smaller address.
    /// @return c1 The currency with the larger address.
    function canonical(Currency a, Currency b) internal pure returns (Currency c0, Currency c1) {
        (c0, c1) = Currency.unwrap(a) < Currency.unwrap(b) ? (a, b) : (b, a);
    }
}
