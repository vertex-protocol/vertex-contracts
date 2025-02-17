// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;
import "prb-math/contracts/PRBMathSD59x18.sol";

/// @title MathHelper
/// @dev Provides basic math functions
library MathHelper {
    using PRBMathSD59x18 for int256;

    /// @notice Returns market id for two given product ids
    function max(int256 a, int256 b) internal pure returns (int256) {
        return a > b ? a : b;
    }

    function min(int256 a, int256 b) internal pure returns (int256) {
        return a < b ? a : b;
    }

    function abs(int256 val) internal pure returns (int256) {
        return val < 0 ? -val : val;
    }

    // babylonian method (https://en.wikipedia.org/wiki/Methods_of_computing_square_roots#Babylonian_method)
    function sqrt(int256 y) internal pure returns (int256 z) {
        require(y >= 0, "ds-math-sqrt-non-positive");
        if (y > 3) {
            z = y;
            int256 x = y / 2 + 1;
            while (x < z) {
                z = x;
                x = (y / x + x) / 2;
            }
        } else if (y != 0) {
            z = 1;
        }
    }

    function int2str(int256 value) internal pure returns (string memory) {
        if (value == 0) {
            return "0";
        }

        bool negative = value < 0;
        uint256 absval = uint256(negative ? -value : value);
        string memory out = uint2str(absval);
        if (negative) {
            out = string.concat("-", out);
        }
        return out;
    }

    function uint2str(uint256 value) internal pure returns (string memory) {
        if (value == 0) {
            return "0";
        }
        uint256 temp = value;
        uint256 digits;
        while (temp != 0) {
            digits++;
            temp /= 10;
        }
        bytes memory buffer = new bytes(digits);
        while (value != 0) {
            digits -= 1;
            buffer[digits] = bytes1(uint8(48 + uint256(value % 10)));
            value /= 10;
        }
        return string(buffer);
    }

    // https://github.com/OpenZeppelin/openzeppelin-contracts/blob/v3.1.0/contracts/math/SignedSafeMath.sol#L86
    function add(int256 x, int256 y) internal pure returns (int256) {
        int256 z = x + y;
        require((y >= 0 && z >= x) || (y < 0 && z < x), "ds-math-add-overflow");
        return z;
    }

    // https://github.com/OpenZeppelin/openzeppelin-contracts/blob/v3.1.0/contracts/math/SignedSafeMath.sol#L69
    function sub(int256 x, int256 y) internal pure returns (int256) {
        int256 z = x - y;
        require(
            (y >= 0 && z <= x) || (y < 0 && z > x),
            "ds-math-sub-underflow"
        );
        return z;
    }

    function mul(int256 x, int256 y) internal pure returns (int256 z) {
        require(y == 0 || (z = x * y) / y == x, "ds-math-mul-overflow");
    }

    function ammEquilibrium(
        int256 baseX18,
        int256 quoteX18,
        int256 priceX18
    ) internal pure returns (int256, int256) {
        if (baseX18 == 0 && quoteX18 == 0) {
            return (0, 0);
        }
        int256 k = baseX18.toInt() * quoteX18.toInt();
        // base * price * base == k
        // base = sqrt(k / price);
        int256 base = (MathHelper.sqrt(k) * 1e9) / MathHelper.sqrt(priceX18);
        // TODO: this can cause a divide by zero
        int256 quote = k / base;
        return (base.fromInt(), quote.toInt());
    }

    function swap(
        int256 amountSwap,
        int256 base,
        int256 quote,
        int256 priceX18,
        int256 sizeIncrement,
        int256 lpSpreadX18
    ) internal pure returns (int256, int256) {
        if (base == 0 || quote == 0) {
            return (0, 0);
        }
        int256 currentPriceX18 = quote.fromInt().div(base.fromInt());

        int256 keepRateX18 = 1e18 - lpSpreadX18;

        // selling
        if (amountSwap > 0) {
            priceX18 = priceX18.div(keepRateX18);
            if (priceX18 >= currentPriceX18) {
                return (0, 0);
            }
        } else {
            priceX18 = priceX18.mul(keepRateX18);
            if (priceX18 <= currentPriceX18) {
                return (0, 0);
            }
        }

        int256 k = MathHelper.mul(base, quote);
        int256 baseAtPrice = (MathHelper.sqrt(k) * 1e9) /
            MathHelper.sqrt(priceX18);
        // base -> base + amountSwap

        int256 baseSwapped;

        if (
            (amountSwap > 0 && base + amountSwap > baseAtPrice) ||
            (amountSwap < 0 && base + amountSwap < baseAtPrice)
        ) {
            // we hit price limits before we exhaust amountSwap
            baseSwapped = baseAtPrice - base;
            baseSwapped -= baseSwapped % sizeIncrement;
        } else {
            // just swap it all
            // amountSwap is already guaranteed to adhere to sizeIncrement
            baseSwapped = amountSwap;
        }

        int256 quoteSwappedX18 = (k / (base + baseSwapped) - quote).fromInt();
        if (amountSwap > 0) {
            quoteSwappedX18 = quoteSwappedX18.mul(keepRateX18).toInt();
        } else {
            quoteSwappedX18 = quoteSwappedX18.div(keepRateX18).toInt();
        }
        return (baseSwapped.fromInt(), quoteSwappedX18.fromInt());
    }
}
