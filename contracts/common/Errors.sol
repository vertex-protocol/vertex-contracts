// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

// ERC20 Transfer failed
string constant ERR_TRANSFER_FAILED = "TF";

// Unauthorized
string constant ERR_UNAUTHORIZED = "U";

// Invalid product
string constant ERR_INVALID_PRODUCT = "IP";

// Subaccount health too low
string constant ERR_SUBACCT_HEALTH = "SH";

// Not liquidatable
string constant ERR_NOT_LIQUIDATABLE = "NL";

// Liquidator health too low
string constant ERR_NOT_LIQUIDATABLE_INITIAL = "NLI";

// Liquidatee has positive initial health
string constant ERR_LIQUIDATED_TOO_MUCH = "LTM";

// Trying to liquidate quote, or
string constant ERR_INVALID_LIQUIDATION_PARAMS = "NILP";

// Tried to liquidate too little, too much or signs are different
string constant ERR_NOT_LIQUIDATABLE_AMT = "NLA";

// Tried to liquidate liabilities before assets
string constant ERR_NOT_LIQUIDATABLE_LIABILITIES = "NLL";

// Not enough quote to settle
string constant ERR_CANNOT_SETTLE = "CS";

// Not enough insurance to settle
string constant ERR_NO_INSURANCE = "NI";

// Above reserve ratio
string constant ERR_RESERVE_RATIO = "RR";

// Invalid socialize amount
string constant ERR_INVALID_SOCIALIZE_AMT = "ISA";

// Socializing product with no open interest
string constant ERR_NO_OPEN_INTEREST = "NOI";

// FOK not filled, this isn't rly an error so this is jank
string constant ERR_FOK_NOT_FILLED = "ENF";

// bad product config via weights
string constant ERR_BAD_PRODUCT_CONFIG = "BPC";

// subacct name too long
string constant ERR_LONG_NAME = "LN";

// already registered in health group
string constant ERR_ALREADY_REGISTERED = "AR";

// trying to burn more LP than owned
string constant ERR_INSUFFICIENT_LP = "ILP";

// taker order subaccount fails risk or is invalid
string constant ERR_INVALID_TAKER = "IT";

// maker order subaccount fails risk or is invalid
string constant ERR_INVALID_MAKER = "IM";

string constant ERR_INVALID_SIGNATURE = "IS";

string constant ERR_ORDERS_CANNOT_BE_MATCHED = "OCBM";

string constant ERR_SLIPPAGE_TOO_HIGH = "STH";

string constant ERR_SUBACCOUNT_NOT_FOUND = "SNF";
