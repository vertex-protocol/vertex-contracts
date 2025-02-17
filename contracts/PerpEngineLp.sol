// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

import "./PerpEngineState.sol";

abstract contract PerpEngineLp is PerpEngineState {
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

        (
            LpState memory lpState,
            LpBalance memory lpBalance,
            State memory state,
            Balance memory balance
        ) = getStatesAndBalances(productId, subaccountId);

        int128 amountQuote = (lpState.base == 0)
            ? amountBase.mul(getOraclePriceX18(productId))
            : amountBase.mul(lpState.quote.div(lpState.base));
        require(amountQuote >= quoteAmountLow, ERR_SLIPPAGE_TOO_HIGH);
        require(amountQuote <= quoteAmountHigh, ERR_SLIPPAGE_TOO_HIGH);

        int128 toMint;
        if (lpState.supply == 0) {
            toMint = amountBase + amountQuote;
        } else {
            toMint = amountBase.div(lpState.base).mul(lpState.supply);
        }

        state.openInterest += amountBase;

        lpState.base += amountBase;
        lpState.quote += amountQuote;
        lpBalance.amount += toMint;
        _updateBalance(state, balance, -amountBase, -amountQuote);
        lpState.supply += toMint;

        lpBalances[productId][subaccountId] = lpBalance;
        states[productId] = state;
        lpStates[productId] = lpState;
        balances[productId][subaccountId] = balance;
    }

    function burnLp(
        uint32 productId,
        uint64 subaccountId,
        int128 amountLp
    ) public {
        checkCanApplyDeltas();
        require(amountLp > 0, ERR_INVALID_LP_AMOUNT);

        (
            LpState memory lpState,
            LpBalance memory lpBalance,
            State memory state,
            Balance memory balance
        ) = getStatesAndBalances(productId, subaccountId);

        if (amountLp == type(int128).max) {
            amountLp = lpBalance.amount;
        }
        if (amountLp == 0) {
            return;
        }

        require(lpBalance.amount >= amountLp, ERR_INSUFFICIENT_LP);
        lpBalance.amount -= amountLp;

        int128 amountBase = MathHelper.mul(amountLp, lpState.base) /
            lpState.supply;
        int128 amountQuote = MathHelper.mul(amountLp, lpState.quote) /
            lpState.supply;

        state.openInterest -= amountBase;

        _updateBalance(state, balance, amountBase, amountQuote);
        lpState.base -= amountBase;
        lpState.quote -= amountQuote;
        lpState.supply -= amountLp;

        lpStates[productId] = lpState;
        lpBalances[productId][subaccountId] = lpBalance;
        states[productId] = state;
        balances[productId][subaccountId] = balance;
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
        if (lpState.base == 0 || lpState.quote == 0) {
            return (0, 0);
        }

        State memory state = states[productId];

        (baseSwapped, quoteSwapped) = MathHelper.swap(
            amount,
            lpState.base,
            lpState.quote,
            priceX18,
            sizeIncrement,
            lpSpreadX18
        );

        state.openInterest += baseSwapped;

        lpState.base += baseSwapped;
        lpState.quote += quoteSwapped;
        states[productId] = state;
        lpStates[productId] = lpState;
    }

    function decomposeLps(uint64 liquidateeId, uint64) external {
        for (uint128 i = 0; i < productIds.length; ++i) {
            uint32 productId = productIds[i];
            burnLp(productId, liquidateeId, type(int128).max);
        }
        // TODO: transfer some of the burned proceeds to liquidator
    }
}
