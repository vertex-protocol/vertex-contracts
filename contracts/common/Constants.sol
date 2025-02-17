// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

/// @dev Each clearinghouse has a unique quote product
uint32 constant QUOTE_PRODUCT_ID = 0;

/// @dev Fees account
bytes32 constant FEES_ACCOUNT = bytes32(0);

uint128 constant MINIMUM_LIQUIDITY = 10**3;

int128 constant ONE = 10**18;

uint8 constant MAX_DECIMALS = 18;

int128 constant TAKER_SEQUENCER_FEE = 25e15; // $0.025

int128 constant SLOW_MODE_FEE = 1000000; // $1

int128 constant LIQUIDATION_FEE = 25e16; // $0.25
int128 constant HEALTHCHECK_FEE = 1e17; // $0.10

uint64 constant VERSION = 6;
