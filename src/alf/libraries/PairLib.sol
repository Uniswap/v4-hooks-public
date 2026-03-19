// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";

/// @title PairLib
/// @notice Utility for canonicalizing currency pairs to ensure consistent storage ordering.
library PairLib {
    /// @notice Returns the canonical ordering of a currency pair (c0 < c1).
    function canonical(Currency a, Currency b) internal pure returns (Currency c0, Currency c1) {
        (c0, c1) = Currency.unwrap(a) < Currency.unwrap(b) ? (a, b) : (b, a);
    }
}
