pragma solidity ^0.8.0;

import "./SpotEngineState.sol";
import "./OffchainBook.sol";

abstract contract SpotEngineLP is SpotEngineState {
    using PRBMathSD59x18 for int256;

    function mintLp(
        uint32 productId,
        uint64 subaccountId,
        int256 amountBaseX18,
        int256 quoteAmountLowX18,
        int256 quoteAmountHighX18
    ) external {
        checkCanApplyDeltas();
        LpState memory lpState = lpStates[productId];
        State memory base = states[productId];
        State memory quote = states[QUOTE_PRODUCT_ID];

        int256 amountQuoteX18 = (lpState.base.amountX18 == 0)
            ? quoteAmountLowX18
            : amountBaseX18
                .mul(lpState.quote.amountX18.div(lpState.base.amountX18))
                .ceil();
        require(amountQuoteX18 >= quoteAmountLowX18, ERR_SLIPPAGE_TOO_HIGH);
        require(amountQuoteX18 <= quoteAmountHighX18, ERR_SLIPPAGE_TOO_HIGH);

        int256 toMint;
        if (lpState.supply == 0) {
            toMint = amountBaseX18.toInt() + amountQuoteX18.toInt();
        } else {
            toMint = amountBaseX18
                .div(lpState.base.amountX18)
                .mul(lpState.supply.fromInt())
                .toInt();
        }

        _updateBalance(base, lpState.base, amountBaseX18);
        _updateBalance(quote, lpState.quote, amountQuoteX18);
        lpState.supply += toMint;

        lpBalances[productId][subaccountId].amountX18 += toMint.fromInt();

        // dont actually need to update these states
        // as the total deposits / borrows won't change
        //  states[productId] = base;
        //  states[QUOTE_PRODUCT_ID] = quote;

        lpStates[productId] = lpState;

        Balance memory baseBalance = balances[productId][subaccountId];
        Balance memory quoteBalance = balances[QUOTE_PRODUCT_ID][subaccountId];

        _updateBalance(base, baseBalance, -amountBaseX18);
        _updateBalance(quote, quoteBalance, -amountQuoteX18);

        balances[productId][subaccountId] = baseBalance;
        balances[QUOTE_PRODUCT_ID][subaccountId] = quoteBalance;
    }

    function burnLp(
        uint32 productId,
        uint64 subaccountId,
        int256 amountLpX18
    ) public {
        checkCanApplyDeltas();

        LpState memory lpState = lpStates[productId];
        LpBalance memory lpBalance = lpBalances[productId][subaccountId];
        State memory base = states[productId];
        State memory quote = states[QUOTE_PRODUCT_ID];

        int256 amountLpX18 = int256(amountLpX18);
        if (amountLpX18 == type(int256).max) {
            amountLpX18 = lpBalance.amountX18;
        }
        if (amountLpX18 == 0) {
            return;
        }

        require(lpBalance.amountX18 >= amountLpX18, ERR_INSUFFICIENT_LP);
        lpBalance.amountX18 -= amountLpX18;

        int256 amountLp = amountLpX18.toInt();

        int256 amountBaseX18 = (
            MathHelper.mul(amountLp, lpState.base.amountX18 / lpState.supply)
        );
        int256 amountQuoteX18 = (
            MathHelper.mul(amountLp, lpState.quote.amountX18 / lpState.supply)
        );

        _updateBalance(base, lpState.base, -amountBaseX18);
        _updateBalance(quote, lpState.quote, -amountQuoteX18);
        lpState.supply -= amountLp;

        lpStates[productId] = lpState;
        lpBalances[productId][subaccountId] = lpBalance;

        Balance memory baseBalance = balances[productId][subaccountId];
        Balance memory quoteBalance = balances[QUOTE_PRODUCT_ID][subaccountId];

        _updateBalance(base, baseBalance, amountBaseX18);
        _updateBalance(quote, quoteBalance, amountQuoteX18);

        balances[productId][subaccountId] = baseBalance;
        balances[QUOTE_PRODUCT_ID][subaccountId] = quoteBalance;
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

        (baseSwappedX18, quoteSwappedX18) = MathHelper.swap(
            amount,
            lpState.base.amountX18.toInt(),
            lpState.quote.amountX18.toInt(),
            priceX18,
            sizeIncrement,
            lpSpreadX18
        );

        lpState.base.amountX18 += baseSwappedX18;
        lpState.quote.amountX18 += quoteSwappedX18;
        lpStates[productId] = lpState;

        // actual balance updates for the subaccountId happen in OffchainBook
    }

    function decomposeLps(uint64 liquidateeId, uint64) external {
        for (uint256 i = 0; i < productIds.length; ++i) {
            uint32 productId = productIds[i];
            burnLp(productId, liquidateeId, type(int256).max);
        }
        // TODO: transfer some of the burned proceeds to liquidator
    }
}
