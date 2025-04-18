// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

import "./interfaces/engine/IPerpEngine.sol";
import "./BaseEngine.sol";

int128 constant EMA_TIME_CONSTANT_X18 = 998334721450938752;
int128 constant ONE_DAY_X18 = 86400_000000000000000000; // 24 hours

// we will want to config this later, but for now this is global and a percentage
int128 constant MAX_DAILY_FUNDING_RATE = 20000000000000000; // 0.02

abstract contract PerpEngineState is IPerpEngine, BaseEngine {
    using MathSD21x18 for int128;

    mapping(uint32 => State) public states;
    mapping(uint32 => mapping(bytes32 => Balance)) public balances;

    mapping(uint32 => LpState) public lpStates;
    mapping(uint32 => mapping(bytes32 => LpBalance)) public lpBalances;

    function _updateBalance(
        State memory state,
        Balance memory balance,
        int128 balanceDelta,
        int128 vQuoteDelta
    ) internal pure {
        // pre update
        state.openInterest -= (balance.amount > 0) ? balance.amount : int128(0);
        int128 cumulativeFundingAmountX18 = (balance.amount > 0)
            ? state.cumulativeFundingLongX18
            : state.cumulativeFundingShortX18;
        int128 diffX18 = cumulativeFundingAmountX18 -
            balance.lastCumulativeFundingX18;
        int128 deltaQuote = vQuoteDelta - diffX18.mul(balance.amount);

        // apply delta
        balance.amount += balanceDelta;

        // apply vquote
        balance.vQuoteBalance += deltaQuote;

        // post update
        if (balance.amount > 0) {
            state.openInterest += balance.amount;
            balance.lastCumulativeFundingX18 = state.cumulativeFundingLongX18;
        } else {
            balance.lastCumulativeFundingX18 = state.cumulativeFundingShortX18;
        }
    }

    function _applyLpBalanceFunding(
        LpState memory lpState,
        LpBalance memory lpBalance,
        Balance memory balance
    ) internal pure {
        int128 vQuoteDelta = (lpState.cumulativeFundingPerLpX18 -
            lpBalance.lastCumulativeFundingX18).mul(lpBalance.amount);
        balance.vQuoteBalance += vQuoteDelta;
        lpBalance.lastCumulativeFundingX18 = lpState.cumulativeFundingPerLpX18;
    }

    function getStateAndBalance(uint32 productId, bytes32 subaccount)
        public
        view
        returns (State memory, Balance memory)
    {
        State memory state = states[productId];
        Balance memory balance = balances[productId][subaccount];
        _updateBalance(state, balance, 0, 0);
        return (state, balance);
    }

    function getBalance(uint32 productId, bytes32 subaccount)
        public
        view
        returns (Balance memory)
    {
        State memory state = states[productId];
        Balance memory balance = balances[productId][subaccount];
        _updateBalance(state, balance, 0, 0);
        return balance;
    }

    function _getBalance(uint32 productId, bytes32 subaccount)
        internal
        view
        virtual
        override
        returns (int128, int128)
    {
        State memory state = states[productId];
        Balance memory balance = balances[productId][subaccount];
        _updateBalance(state, balance, 0, 0);
        return (balance.amount, balance.vQuoteBalance);
    }

    function _getInLpBalance(uint32 productId, bytes32 subaccount)
        internal
        view
        virtual
        override
        returns (
            // baseAmount, quoteAmount, deltaQuoteAmount (funding)
            int128,
            int128,
            int128
        )
    {
        LpBalance memory lpBalance = lpBalances[productId][subaccount];
        if (lpBalance.amount == 0) {
            return (0, 0, 0);
        }
        LpState memory lpState = lpStates[productId];
        int128 ratio = lpBalance.amount.div(lpState.supply);
        int128 baseAmount = lpState.base.mul(ratio);
        int128 quoteAmount = lpState.quote.mul(ratio);

        int128 quoteDeltaAmount = lpState
            .cumulativeFundingPerLpX18
            .sub(lpBalance.lastCumulativeFundingX18)
            .mul(lpBalance.amount);
        return (baseAmount, quoteAmount, quoteDeltaAmount);
    }

    function getStatesAndBalances(uint32 productId, bytes32 subaccount)
        public
        view
        returns (
            LpState memory,
            LpBalance memory,
            State memory,
            Balance memory
        )
    {
        LpState memory lpState = lpStates[productId];
        State memory state = states[productId];
        LpBalance memory lpBalance = lpBalances[productId][subaccount];
        Balance memory balance = balances[productId][subaccount];

        _updateBalance(state, balance, 0, 0);
        _applyLpBalanceFunding(lpState, lpBalance, balance);
        return (lpState, lpBalance, state, balance);
    }

    function updateStates(uint128 dt, int128[] calldata avgPriceDiffs)
        external
        onlyEndpoint
    {
        int128 dtX18 = int128(dt).fromInt();
        for (uint32 i = 0; i < avgPriceDiffs.length; i++) {
            uint32 productId = productIds[i];
            State memory state = states[productId];
            if (state.openInterest == 0) {
                continue;
            }
            require(dt < 7 * SECONDS_PER_DAY, ERR_INVALID_TIME);

            LpState memory lpState = lpStates[productId];

            {
                int128 indexPriceX18 = _risk(productId).priceX18;

                // cap this price diff
                int128 priceDiffX18 = avgPriceDiffs[i];

                int128 maxPriceDiff = MAX_DAILY_FUNDING_RATE.mul(indexPriceX18);

                if (priceDiffX18.abs() > maxPriceDiff) {
                    // Proper sign
                    priceDiffX18 = (priceDiffX18 > 0)
                        ? maxPriceDiff
                        : -maxPriceDiff;
                }

                int128 paymentAmount = priceDiffX18.mul(dtX18).div(ONE_DAY_X18);
                state.cumulativeFundingLongX18 += paymentAmount;
                state.cumulativeFundingShortX18 += paymentAmount;

                emit FundingPayment(
                    productId,
                    dt,
                    state.openInterest,
                    paymentAmount
                );
            }

            {
                Balance memory balance = Balance({
                    amount: lpState.base,
                    vQuoteBalance: 0,
                    lastCumulativeFundingX18: lpState.lastCumulativeFundingX18
                });
                _updateBalance(state, balance, 0, 0);
                if (lpState.supply != 0) {
                    lpState.cumulativeFundingPerLpX18 += balance
                        .vQuoteBalance
                        .div(lpState.supply);
                }
                lpState.lastCumulativeFundingX18 = state
                    .cumulativeFundingLongX18;
            }
            lpStates[productId] = lpState;
            states[productId] = state;
            _productUpdate(productId);
        }
    }
}
