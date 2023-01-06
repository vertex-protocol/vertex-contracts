pragma solidity ^0.8.0;

import "./PerpEngineState.sol";

abstract contract PerpEngineLp is PerpEngineState {
    using PRBMathSD59x18 for int256;

    function mintLp(
        uint32 productId,
        uint64 subaccountId,
        int256 amountBaseX18,
        int256 quoteAmountLowX18,
        int256 quoteAmountHighX18
    ) external {
        checkCanApplyDeltas();

        (
            LpState memory lpState,
            LpBalance memory lpBalance,
            State memory state,
            Balance memory balance
        ) = getStatesAndBalances(productId, subaccountId);

        int256 amountQuoteX18 = (lpState.base == 0)
            ? quoteAmountLowX18
            : amountBaseX18
                .mul(lpState.quote.fromInt().div(lpState.base.fromInt()))
                .ceil();
        require(amountQuoteX18 >= quoteAmountLowX18, ERR_SLIPPAGE_TOO_HIGH);
        require(amountQuoteX18 <= quoteAmountHighX18, ERR_SLIPPAGE_TOO_HIGH);

        int256 toMint;
        if (lpState.supply == 0) {
            toMint = amountBaseX18.toInt() + amountQuoteX18.toInt();
        } else {
            toMint = amountBaseX18
                .div(lpState.base.fromInt())
                .mul(lpState.supply.fromInt())
                .toInt();
        }

        state.openInterestX18 += amountBaseX18;

        lpState.base += amountBaseX18.toInt();
        lpState.quote += amountQuoteX18.toInt();
        lpBalance.amountX18 += toMint.fromInt();
        _updateBalance(state, balance, -amountBaseX18, -amountQuoteX18);
        lpState.supply += toMint;

        lpBalances[productId][subaccountId] = lpBalance;
        states[productId] = state;
        lpStates[productId] = lpState;
        balances[productId][subaccountId] = balance;
    }

    function burnLp(
        uint32 productId,
        uint64 subaccountId,
        int256 amountLpX18
    ) public {
        checkCanApplyDeltas();

        (
            LpState memory lpState,
            LpBalance memory lpBalance,
            State memory state,
            Balance memory balance
        ) = getStatesAndBalances(productId, subaccountId);

        if (amountLpX18 == type(int256).max) {
            amountLpX18 = lpBalance.amountX18;
        }
        if (amountLpX18 == 0) {
            return;
        }

        require(lpBalance.amountX18 >= amountLpX18, ERR_INSUFFICIENT_LP);
        lpBalance.amountX18 -= amountLpX18;

        int256 amountLp = amountLpX18.toInt();

        int256 amountBase = (amountLp * lpState.base) / lpState.supply;
        int256 amountQuote = (amountLp * lpState.quote) / lpState.supply;

        state.openInterestX18 -= amountBase.fromInt();

        _updateBalance(
            state,
            balance,
            amountBase.fromInt(),
            amountQuote.fromInt()
        );
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
        uint64 subaccountId,
        // maximum to swap
        int256 amount,
        int256 priceX18,
        int256 sizeIncrement,
        int256 lpSpreadX18
    ) external returns (int256 baseSwappedX18, int256 quoteSwappedX18) {
        checkCanApplyDeltas();
        LpState memory lpState = lpStates[productId];
        State memory state = states[productId];

        int256 newMarkPriceX18 = computeNewMarkPrice(
            productId,
            lpState,
            // TODO: this is a temporary hack
            // need a better way to track mark price
            1
        );

        (baseSwappedX18, quoteSwappedX18) = MathHelper.swap(
            amount,
            lpState.base,
            lpState.quote,
            priceX18,
            sizeIncrement,
            lpSpreadX18
        );

        state.openInterestX18 += baseSwappedX18;

        lpState.base += baseSwappedX18.toInt();
        lpState.quote += quoteSwappedX18.toInt();
        states[productId] = state;
        lpStates[productId] = lpState;

        markPrices[productId] = newMarkPriceX18;
        // actual balance updates for the subaccountId happen in OffchainBook
    }

    function decomposeLps(uint64 liquidateeId, uint64) external {
        for (uint256 i = 0; i < productIds.length; ++i) {
            uint32 productId = productIds[i];
            burnLp(productId, liquidateeId, type(int256).max);
        }
        // TODO: transfer some of the burned proceeds to liquidator
    }

    function computeNewMarkPrice(
        uint32 productId,
        LpState memory lpState,
        uint256 dt
    ) internal view returns (int256) {
        // pedantic case:
        // just return the oracle price if there is no liquidity
        // in the LP
        if (lpState.base == 0) {
            return getOraclePriceX18(productId);
        }
        int256 lastMarkPriceX18 = markPrices[productId];
        int256 currentPriceX18 = lpState.quote.fromInt().div(
            lpState.base.fromInt()
        );
        if (lastMarkPriceX18 == 0) {
            return currentPriceX18;
        }
        int256 factorX18 = EMA_TIME_CONSTANT_X18.pow(int256(dt).fromInt());
        return
            lastMarkPriceX18.mul(factorX18) +
            currentPriceX18.mul(ONE - factorX18);
    }
}
