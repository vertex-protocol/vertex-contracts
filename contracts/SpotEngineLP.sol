// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

import "./SpotEngineState.sol";
import "./OffchainBook.sol";

abstract contract SpotEngineLP is SpotEngineState {
    using MathSD21x18 for int128;

    function mintLp(
        uint32 productId,
        uint64 subaccountId,
        int128 amountBase,
        int128 quoteAmountLow,
        int128 quoteAmountHigh
    ) external {
        checkCanApplyDeltas();
        require(
            amountBase > 0 && quoteAmountLow > 0 && quoteAmountHigh > 0,
            ERR_INVALID_LP_AMOUNT
        );

        LpState memory lpState = lpStates[productId];
        State memory base = states[productId];
        State memory quote = states[QUOTE_PRODUCT_ID];

        int128 amountQuote = (lpState.base.amount == 0)
            ? amountBase.mul(getOraclePriceX18(productId))
            : amountBase.mul(lpState.quote.amount.div(lpState.base.amount));
        require(amountQuote >= quoteAmountLow, ERR_SLIPPAGE_TOO_HIGH);
        require(amountQuote <= quoteAmountHigh, ERR_SLIPPAGE_TOO_HIGH);

        int128 toMint;
        if (lpState.supply == 0) {
            toMint = amountBase + amountQuote;
        } else {
            toMint = amountBase.div(lpState.base.amount).mul(lpState.supply);
        }

        _updateBalance(base, lpState.base, amountBase);
        _updateBalance(quote, lpState.quote, amountQuote);
        lpState.supply += toMint;

        lpBalances[productId][subaccountId].amount += toMint;

        // dont actually need to update these states
        // as the total deposits / borrows won't change
        //  states[productId] = base;
        //  states[QUOTE_PRODUCT_ID] = quote;

        lpStates[productId] = lpState;

        Balance memory baseBalance = balances[productId][subaccountId];
        Balance memory quoteBalance = balances[QUOTE_PRODUCT_ID][subaccountId];

        _updateBalance(base, baseBalance, -amountBase);
        _updateBalance(quote, quoteBalance, -amountQuote);

        balances[productId][subaccountId] = baseBalance;
        balances[QUOTE_PRODUCT_ID][subaccountId] = quoteBalance;
    }

    function burnLp(
        uint32 productId,
        uint64 subaccountId,
        int128 amountLp
    ) public {
        checkCanApplyDeltas();
        require(amountLp > 0, ERR_INVALID_LP_AMOUNT);

        LpState memory lpState = lpStates[productId];
        LpBalance memory lpBalance = lpBalances[productId][subaccountId];
        State memory base = states[productId];
        State memory quote = states[QUOTE_PRODUCT_ID];

        if (amountLp == type(int128).max) {
            amountLp = lpBalance.amount;
        }
        if (amountLp == 0) {
            return;
        }

        require(lpBalance.amount >= amountLp, ERR_INSUFFICIENT_LP);
        lpBalance.amount -= amountLp;

        int128 amountBase = int128(
            (int256(amountLp) * lpState.base.amount) / lpState.supply
        );
        int128 amountQuote = int128(
            (int256(amountLp) * lpState.quote.amount) / lpState.supply
        );

        _updateBalance(base, lpState.base, -amountBase);
        _updateBalance(quote, lpState.quote, -amountQuote);
        lpState.supply -= amountLp;

        lpStates[productId] = lpState;
        lpBalances[productId][subaccountId] = lpBalance;

        Balance memory baseBalance = balances[productId][subaccountId];
        Balance memory quoteBalance = balances[QUOTE_PRODUCT_ID][subaccountId];

        _updateBalance(base, baseBalance, amountBase);
        _updateBalance(quote, quoteBalance, amountQuote);

        balances[productId][subaccountId] = baseBalance;
        balances[QUOTE_PRODUCT_ID][subaccountId] = quoteBalance;
    }

    function swapLp(
        uint32 productId,
        uint64, /* subaccountId */
        // maximum to swap
        int128 amount,
        int128 priceX18,
        int128 sizeIncrement,
        int128 lpSpreadX18
    ) external returns (int128 baseSwapped, int128 quoteSwapped) {
        checkCanApplyDeltas();
        LpState memory lpState = lpStates[productId];

        if (lpState.base.amount == 0 || lpState.quote.amount == 0) {
            return (0, 0);
        }

        (baseSwapped, quoteSwapped) = MathHelper.swap(
            amount,
            lpState.base.amount,
            lpState.quote.amount,
            priceX18,
            sizeIncrement,
            lpSpreadX18
        );

        lpState.base.amount += baseSwapped;
        lpState.quote.amount += quoteSwapped;
        lpStates[productId] = lpState;

        // actual balance updates for the subaccountId happen in OffchainBook
    }

    function decomposeLps(uint64 liquidateeId, uint64) external {
        for (uint128 i = 0; i < productIds.length; ++i) {
            uint32 productId = productIds[i];
            burnLp(productId, liquidateeId, type(int128).max);
        }
        // TODO: transfer some of the burned proceeds to liquidator
    }
}
