// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

import "./SpotEngineState.sol";
import "./libraries/Logger.sol";

abstract contract SpotEngineLP is SpotEngineState {
    using MathSD21x18 for int128;

    function mintLp(
        uint32 productId,
        bytes32 subaccount,
        int128 amountBase,
        int128 quoteAmountLow,
        int128 quoteAmountHigh
    ) external {
        _assertInternal();
        require(
            amountBase > 0 && quoteAmountLow > 0 && quoteAmountHigh > 0,
            ERR_INVALID_LP_AMOUNT
        );

        require(
            _exchange().getMarketInfo(productId).quoteId == QUOTE_PRODUCT_ID,
            ERR_INVALID_PRODUCT
        );

        LpState memory lpState = lpStates[productId];
        State memory base = states[productId];
        State memory quote = states[QUOTE_PRODUCT_ID];

        int128 amountQuote = (lpState.base.amount == 0)
            ? amountBase.mul(_risk(productId).priceX18)
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

        balances[productId][subaccount].lpBalance.amount += toMint;

        lpStates[productId] = lpState;

        BalanceNormalized memory baseBalance = balances[productId][subaccount]
            .balance;
        BalanceNormalized memory quoteBalance = balances[QUOTE_PRODUCT_ID][
            subaccount
        ].balance;

        _updateBalanceNormalized(base, baseBalance, -amountBase);
        _updateBalanceNormalized(quote, quoteBalance, -amountQuote);

        balances[productId][subaccount].balance = baseBalance;
        balances[QUOTE_PRODUCT_ID][subaccount].balance = quoteBalance;
        states[productId] = base;
        states[QUOTE_PRODUCT_ID] = quote;

        _balanceUpdate(productId, subaccount);
        _balanceUpdate(QUOTE_PRODUCT_ID, subaccount);
    }

    function burnLp(
        uint32 productId,
        bytes32 subaccount,
        int128 amountLp
    ) public returns (int128 amountBase, int128 amountQuote) {
        _assertInternal();
        require(amountLp > 0, ERR_INVALID_LP_AMOUNT);

        LpState memory lpState = lpStates[productId];
        LpBalance memory lpBalance = balances[productId][subaccount].lpBalance;
        State memory base = states[productId];
        State memory quote = states[QUOTE_PRODUCT_ID];

        if (amountLp == type(int128).max) {
            amountLp = lpBalance.amount;
        }
        if (amountLp == 0) {
            return (0, 0);
        }

        require(lpBalance.amount >= amountLp, ERR_INSUFFICIENT_LP);
        lpBalance.amount -= amountLp;

        amountBase = int128(
            (int256(amountLp) * lpState.base.amount) / lpState.supply
        );
        amountQuote = int128(
            (int256(amountLp) * lpState.quote.amount) / lpState.supply
        );

        _updateBalance(base, lpState.base, -amountBase);
        _updateBalance(quote, lpState.quote, -amountQuote);
        lpState.supply -= amountLp;

        lpStates[productId] = lpState;
        balances[productId][subaccount].lpBalance = lpBalance;

        BalanceNormalized memory baseBalance = balances[productId][subaccount]
            .balance;
        BalanceNormalized memory quoteBalance = balances[QUOTE_PRODUCT_ID][
            subaccount
        ].balance;

        _updateBalanceNormalized(base, baseBalance, amountBase);
        _updateBalanceNormalized(quote, quoteBalance, amountQuote);

        balances[productId][subaccount].balance = baseBalance;
        balances[QUOTE_PRODUCT_ID][subaccount].balance = quoteBalance;
        states[productId] = base;
        states[QUOTE_PRODUCT_ID] = quote;

        _balanceUpdate(productId, subaccount);
        _balanceUpdate(QUOTE_PRODUCT_ID, subaccount);
    }

    function swapLp(
        uint32 productId,
        int128 baseDelta,
        int128 quoteDelta
    ) external returns (int128, int128) {
        _assertInternal();
        LpState memory lpState = lpStates[productId];
        require(
            MathHelper.isSwapValid(
                baseDelta,
                quoteDelta,
                lpState.base.amount,
                lpState.quote.amount
            ),
            ERR_INVALID_MAKER
        );

        int128 baseDepositsMultiplierX18 = states[productId]
            .cumulativeDepositsMultiplierX18;
        int128 quoteDepositsMultiplierX18 = states[QUOTE_PRODUCT_ID]
            .cumulativeDepositsMultiplierX18;

        lpState.base.amount += baseDelta;
        lpState.quote.amount += quoteDelta;
        lpStates[productId] = lpState;

        states[productId].totalDepositsNormalized += baseDelta.div(
            baseDepositsMultiplierX18
        );
        states[QUOTE_PRODUCT_ID].totalDepositsNormalized += quoteDelta.div(
            quoteDepositsMultiplierX18
        );
        _productUpdate(productId);
        return (baseDelta, quoteDelta);
    }

    function decomposeLps(bytes32 liquidatee, bytes32 liquidator)
        external
        returns (int128 liquidationFees)
    {
        uint32[] memory _productIds = getProductIds();
        for (uint128 i = 0; i < _productIds.length; ++i) {
            uint32 productId = _productIds[i];
            (, int128 amountQuote) = burnLp(
                productId,
                liquidatee,
                type(int128).max
            );
            if (amountQuote != 0) {
                int128 rewards = amountQuote.mul(
                    (ONE -
                        RiskHelper._getWeightX18(
                            _risk(productId),
                            amountQuote,
                            IProductEngine.HealthType.MAINTENANCE
                        )) / 50
                );
                int128 fees = rewards.mul(LIQUIDATION_FEE_FRACTION);
                rewards -= fees;
                liquidationFees += fees;

                State memory quote = states[QUOTE_PRODUCT_ID];
                BalanceNormalized memory liquidateeQuote = balances[
                    QUOTE_PRODUCT_ID
                ][liquidatee].balance;
                BalanceNormalized memory liquidatorQuote = balances[
                    QUOTE_PRODUCT_ID
                ][liquidator].balance;

                _updateBalanceNormalized(
                    quote,
                    liquidateeQuote,
                    -rewards - fees
                );
                _updateBalanceNormalized(quote, liquidatorQuote, rewards);

                balances[QUOTE_PRODUCT_ID][liquidatee]
                    .balance = liquidateeQuote;
                balances[QUOTE_PRODUCT_ID][liquidator]
                    .balance = liquidatorQuote;
                states[QUOTE_PRODUCT_ID] = quote;
                _balanceUpdate(QUOTE_PRODUCT_ID, liquidator);
                _balanceUpdate(QUOTE_PRODUCT_ID, liquidatee);
            }
        }
    }
}
