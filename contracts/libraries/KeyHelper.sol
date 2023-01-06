// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

/// @title KeyHelper
/// @dev Provides functionality to retrieve market ids from product ids and vice versa
library KeyHelper {
    /// @notice Returns market id for two given product ids
    function productsToMarket(
        uint32 a,
        uint32 b
    ) internal pure returns (uint32) {
        require(a > 0 && b > 0 && a != b);
        return (a << 16) | b;
    }

    /// @notice Returns product ids for a given market id
    function marketToProducts(uint32 m) internal pure returns (uint32, uint32) {
        require(m > 0);
        return (m >> 16, m & ((1 << 16) - 1));
    }
}
