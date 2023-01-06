pragma solidity ^0.8.0;

import "./interfaces/engine/IPerpEngine.sol";
import "./BaseEngine.sol";

int256 constant EMA_TIME_CONSTANT_X18 = 998334721450938752;
int256 constant FUNDING_PERIOD_X18 = 86000_000000000000000000;

// we will want to config this later, but for now this is global and a percentage
int256 constant MAX_PRICE_DIFF_PERCENT_X18 = 100000000000000000; // 0.1

abstract contract PerpEngineState is IPerpEngine, BaseEngine {
    using PRBMathSD59x18 for int256;

    mapping(uint32 => State) public states;
    mapping(uint32 => mapping(uint64 => Balance)) public balances;

    mapping(uint32 => LpState) public lpStates;
    mapping(uint32 => mapping(uint64 => LpBalance)) public lpBalances;

    mapping(uint32 => int256) markPrices;

    function _updateBalance(
        State memory state,
        Balance memory balance,
        int256 balanceDeltaX18,
        int256 vQuoteDeltaX18
    ) internal pure {
        // pre update
        state.openInterestX18 -= (balance.amountX18 > 0)
            ? balance.amountX18
            : int256(0);
        int256 cumulativeFundingAmountX18 = (balance.amountX18 > 0)
            ? state.cumulativeFundingLongX18
            : state.cumulativeFundingShortX18;
        int256 diffX18 = cumulativeFundingAmountX18 -
            balance.lastCumulativeFundingX18;
        int256 deltaQuoteX18 = vQuoteDeltaX18 - diffX18.mul(balance.amountX18);

        // apply delta
        balance.amountX18 += balanceDeltaX18;

        // apply vquote
        balance.vQuoteBalanceX18 += deltaQuoteX18;

        // post update
        if (balance.amountX18 > 0) {
            state.openInterestX18 += balance.amountX18;
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
        int256 vQuoteDeltaX18 = (lpState.cumulativeFundingPerLpX18 -
            lpBalance.lastCumulativeFundingX18).mul(lpBalance.amountX18);
        balance.vQuoteBalanceX18 += vQuoteDeltaX18;
        lpBalance.lastCumulativeFundingX18 = lpState.cumulativeFundingPerLpX18;
    }

    function getStateAndBalance(
        uint32 productId,
        uint64 subaccountId
    ) public view returns (State memory, Balance memory) {
        State memory state = states[productId];
        Balance memory balance = balances[productId][subaccountId];
        _updateBalance(state, balance, 0, 0);
        return (state, balance);
    }

    function getStatesAndBalances(
        uint32 productId,
        uint64 subaccountId
    )
        public
        view
        returns (LpState memory, LpBalance memory, State memory, Balance memory)
    {
        LpState memory lpState = lpStates[productId];
        State memory state = states[productId];
        LpBalance memory lpBalance = lpBalances[productId][subaccountId];
        Balance memory balance = balances[productId][subaccountId];

        _updateBalance(state, balance, 0, 0);
        _applyLpBalanceFunding(lpState, lpBalance, balance);
        return (lpState, lpBalance, state, balance);
    }

    function updateStates(uint256 dt) external {
        for (uint32 i = 0; i < productIds.length; i++) {
            uint32 productId = productIds[i];
            LpState memory lpState = lpStates[productId];
            State memory state = states[productId];

            {
                int256 priceX18 = getOraclePriceX18(productId);
                int256 markPriceX18 = markPrices[productId];
                if (markPriceX18 == 0) {
                    markPriceX18 = priceX18;
                }
                // cap this price diff
                int256 priceDiffX18 = markPriceX18 - priceX18;
                if (
                    priceDiffX18.abs() >
                    MAX_PRICE_DIFF_PERCENT_X18.mul(priceX18)
                ) {
                    // Proper sign
                    priceDiffX18 = (priceDiffX18 > 0)
                        ? MAX_PRICE_DIFF_PERCENT_X18.mul(priceX18)
                        : -MAX_PRICE_DIFF_PERCENT_X18.mul(priceX18);
                }

                int256 paymentAmountX18 = priceDiffX18
                    .mul(int256(dt).fromInt())
                    .div(FUNDING_PERIOD_X18);
                state.cumulativeFundingLongX18 += paymentAmountX18;
                state.cumulativeFundingShortX18 += paymentAmountX18;
            }

            {
                Balance memory balance = Balance({
                    amountX18: lpState.base.fromInt(),
                    vQuoteBalanceX18: 0,
                    lastCumulativeFundingX18: state.cumulativeFundingLongX18
                });
                _updateBalance(state, balance, 0, 0);
                if (lpState.supply != 0) {
                    lpState.cumulativeFundingPerLpX18 += balance
                        .vQuoteBalanceX18
                        .div(lpState.supply.fromInt());
                }
                lpState.lastCumulativeFundingX18 = state
                    .cumulativeFundingLongX18;
            }
            lpStates[productId] = lpState;
            states[productId] = state;
        }
    }

    function getMarkPrice(uint32 productId) external view returns (int256) {
        return markPrices[productId];
    }
}
