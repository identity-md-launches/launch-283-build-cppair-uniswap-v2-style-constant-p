// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @notice 512-bit multiply-then-divide, floor(a * b / denominator), for test comparisons
///         whose intermediate product does not fit in 256 bits (k * supply^2 is up to 2^448).
/// @dev Standard Remco Bloemen / Uniswap v3 / OpenZeppelin construction.
library FullMath {
    error MulDivOverflow();
    error DivisionByZero();

    function mulDiv(uint256 a, uint256 b, uint256 denominator) internal pure returns (uint256 result) {
        (bool fits, uint256 r) = tryMulDiv(a, b, denominator);
        if (!fits) revert MulDivOverflow();
        return r;
    }

    /// @notice True iff floor(a * b / denominator) >= threshold, without ever overflowing: a quotient
    ///         that does not fit in 256 bits is larger than any possible threshold.
    function mulDivGe(uint256 a, uint256 b, uint256 denominator, uint256 threshold) internal pure returns (bool) {
        (bool fits, uint256 r) = tryMulDiv(a, b, denominator);
        return !fits || r >= threshold;
    }

    /// @notice floor(a * b / denominator) with a 512-bit intermediate; `fits` is false when the
    ///         quotient itself does not fit in 256 bits.
    function tryMulDiv(uint256 a, uint256 b, uint256 denominator) internal pure returns (bool fits, uint256 result) {
        unchecked {
            // 512-bit product [prod1 prod0] = a * b.
            uint256 prod0;
            uint256 prod1;
            assembly {
                let mm := mulmod(a, b, not(0))
                prod0 := mul(a, b)
                prod1 := sub(sub(mm, prod0), lt(mm, prod0))
            }

            if (prod1 == 0) {
                if (denominator == 0) revert DivisionByZero();
                return (true, prod0 / denominator);
            }
            if (denominator <= prod1) return (false, 0);

            // Subtract the remainder from [prod1 prod0] so the numerator is divisible.
            uint256 remainder;
            assembly {
                remainder := mulmod(a, b, denominator)
                prod1 := sub(prod1, gt(remainder, prod0))
                prod0 := sub(prod0, remainder)
            }

            // Factor powers of two out of the denominator.
            uint256 twos = denominator & (0 - denominator);
            assembly {
                denominator := div(denominator, twos)
                prod0 := div(prod0, twos)
                twos := add(div(sub(0, twos), twos), 1)
            }
            prod0 |= prod1 * twos;

            // Modular inverse of the (now odd) denominator via Newton iteration.
            uint256 inverse = (3 * denominator) ^ 2;
            inverse *= 2 - denominator * inverse; // 2^8
            inverse *= 2 - denominator * inverse; // 2^16
            inverse *= 2 - denominator * inverse; // 2^32
            inverse *= 2 - denominator * inverse; // 2^64
            inverse *= 2 - denominator * inverse; // 2^128
            inverse *= 2 - denominator * inverse; // 2^256

            result = prod0 * inverse;
            fits = true;
        }
    }
}
