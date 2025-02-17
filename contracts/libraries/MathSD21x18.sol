// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

import "prb-math/contracts/PRBMathSD59x18.sol";

library MathSD21x18 {
    using PRBMathSD59x18 for int256;

    int128 private constant ONE_X18 = 1000000000000000000;
    int128 private constant MIN_X18 = -0x80000000000000000000000000000000;
    int128 private constant MAX_X18 = 0x7FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF;
    string private constant ERR_OVERFLOW = "OF";
    string private constant ERR_DIV_BY_ZERO = "DBZ";

    function fromInt(int128 x) internal pure returns (int128) {
        unchecked {
            int256 result = int256(x) * ONE_X18;
            require(result >= MIN_X18 && result <= MAX_X18, ERR_OVERFLOW);
            return int128(result);
        }
    }

    function toInt(int128 x) internal pure returns (int128) {
        unchecked {
            return int128(x / ONE_X18);
        }
    }

    function add(int128 x, int128 y) internal pure returns (int128) {
        unchecked {
            int256 result = int256(x) + y;
            require(result >= MIN_X18 && result <= MAX_X18, ERR_OVERFLOW);
            return int128(result);
        }
    }

    function sub(int128 x, int128 y) internal pure returns (int128) {
        unchecked {
            int256 result = int256(x) - y;
            require(result >= MIN_X18 && result <= MAX_X18, ERR_OVERFLOW);
            return int128(result);
        }
    }

    function mul(int128 x, int128 y) internal pure returns (int128) {
        unchecked {
            int256 result = (int256(x) * y) / ONE_X18;
            require(result >= MIN_X18 && result <= MAX_X18, ERR_OVERFLOW);
            return int128(result);
        }
    }

    function div(int128 x, int128 y) internal pure returns (int128) {
        unchecked {
            require(y != 0, ERR_DIV_BY_ZERO);
            int256 result = (int256(x) * ONE_X18) / y;
            require(result >= MIN_X18 && result <= MAX_X18, ERR_OVERFLOW);
            return int128(result);
        }
    }

    function abs(int128 x) internal pure returns (int128) {
        unchecked {
            require(x != MIN_X18, ERR_OVERFLOW);
            return x < 0 ? -x : x;
        }
    }

    function sqrt(int128 x) internal pure returns (int128) {
        unchecked {
            int256 result = int256(x).sqrt();
            require(result >= MIN_X18 && result <= MAX_X18, ERR_OVERFLOW);
            return int128(result);
        }
    }

    function pow(int128 x, int128 y) internal pure returns (int128) {
        unchecked {
            int256 result = int256(x).pow(int256(y));
            require(result >= MIN_X18 && result <= MAX_X18, ERR_OVERFLOW);
            return int128(result);
        }
    }
}
