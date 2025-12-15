// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

/// @author Modified from Solady (https://github.com/vectorized/solady/blob/main/src/utils/FixedPointMathLib.sol)
library GuidestarLibrary {
    /// @dev Returns the minimum of `x` and `y`.
    function min(uint256 x, uint256 y) internal pure returns (uint256 z) {
        assembly {
            z := xor(x, mul(xor(x, y), lt(y, x)))
        }
    }

    /// @dev Returns the maximum of `x` and `y`.
    function max(int256 x, int256 y) internal pure returns (int256 z) {
        assembly {
            z := xor(x, mul(xor(x, y), sgt(y, x)))
        }
    }

    // @dev the split in two with this special case saves 110 gas, see factor() in (Stable)HookParams
    function fastPow(uint256 k, uint256 blocksPassed) internal pure returns (uint256 z) {
        assembly {
            switch blocksPassed
            case 1 { z := k }
            case 2 { z := shr(24, mul(k, k)) }
            case 3 {
                let zz := mul(k, k)
                z := shr(48, mul(k, zz))
            }
            case 4 {
                let zz := mul(k, k)
                z := shr(72, mul(zz, zz))
            }
            case 0 { z := shl(24, 1) }
        }
    }
}
