// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

/// @dev Each clearinghouse has a unique quote product
uint32 constant QUOTE_PRODUCT_ID = 0;

/// @dev Fees account
uint64 constant FEES_SUBACCOUNT_ID = type(uint64).max;

uint256 constant MINIMUM_LIQUIDITY = 10 ** 3;

int256 constant ONE = 10 ** 18;
