pragma solidity ^0.8.0;

import "./interfaces/engine/ISpotEngine.sol";
import "./BaseEngine.sol";

abstract contract SpotEngineState is ISpotEngine, BaseEngine {
    using PRBMathSD59x18 for int256;

    mapping(uint32 => Config) internal configs;
    mapping(uint32 => State) public states;
    mapping(uint32 => mapping(uint64 => Balance)) public balances;

    mapping(uint32 => LpState) public lpStates;
    mapping(uint32 => mapping(uint64 => LpBalance)) public lpBalances;

    function _updateBalance(
        State memory state,
        Balance memory balance,
        int256 balanceDeltaX18
    ) internal pure {
        if (
            balance.amountX18 == 0 && balance.lastCumulativeMultiplierX18 == 0
        ) {
            balance.lastCumulativeMultiplierX18 = ONE;
        }

        if (balance.amountX18 > 0) {
            state.totalDepositsNormalizedX18 -= balance.amountX18.div(
                balance.lastCumulativeMultiplierX18
            );
        } else {
            state.totalBorrowsNormalizedX18 += balance.amountX18.div(
                balance.lastCumulativeMultiplierX18
            );
        }

        // Current cumulative multiplier associated with product
        int256 cumulativeMultiplierX18;
        if (balance.amountX18 > 0) {
            cumulativeMultiplierX18 = state.cumulativeDepositsMultiplierX18;
        } else {
            cumulativeMultiplierX18 = state.cumulativeBorrowsMultiplierX18;
        }

        // Apply balance delta and interest rate
        // console.log("paying out interest");
        // console.logInt(balance.amountX18 - balance.amountX18.mul(
        //         cumulativeMultiplierX18.div(balance.lastCumulativeMultiplierX18)
        //     ));
        balance.amountX18 =
            balance.amountX18.mul(
                cumulativeMultiplierX18.div(balance.lastCumulativeMultiplierX18)
            ) +
            balanceDeltaX18;

        if (balance.amountX18 > 0) {
            cumulativeMultiplierX18 = state.cumulativeDepositsMultiplierX18;
        } else {
            cumulativeMultiplierX18 = state.cumulativeBorrowsMultiplierX18;
        }

        balance.lastCumulativeMultiplierX18 = cumulativeMultiplierX18;

        // Update the product given balanceDelta
        if (balance.amountX18 > 0) {
            state.totalDepositsNormalizedX18 += balance.amountX18.div(
                balance.lastCumulativeMultiplierX18
            );
        } else {
            state.totalBorrowsNormalizedX18 -= balance.amountX18.div(
                balance.lastCumulativeMultiplierX18
            );
        }
    }

    function _updateState(
        uint32 productId,
        State memory state,
        uint256 dt
    ) internal {
        int256 utilizationRatioX18;
        int256 totalDepositsX18 = state.totalDepositsNormalizedX18.mul(
            state.cumulativeDepositsMultiplierX18
        );

        {
            int256 totalBorrowsX18 = state.totalBorrowsNormalizedX18.mul(
                state.cumulativeBorrowsMultiplierX18
            );
            utilizationRatioX18 = totalDepositsX18 == 0
                ? int256(0)
                : totalBorrowsX18.div(totalDepositsX18);
        }

        int256 borrowRateMultiplierX18;
        {
            Config memory config = configs[productId];

            // annualized borrower rate
            int256 borrowerRateX18 = config.interestFloorX18;
            if (utilizationRatioX18 == 0) {
                // setting borrowerRateX18 to 0 here has the property that
                // adding a product at the beginning of time and not using it until time T
                // results in the same state as adding the product at time T
                borrowerRateX18 = 0;
            } else if (utilizationRatioX18 < config.interestInflectionUtilX18) {
                borrowerRateX18 += config
                    .interestSmallCapX18
                    .mul(utilizationRatioX18)
                    .div(config.interestInflectionUtilX18);
            } else {
                borrowerRateX18 +=
                    config.interestSmallCapX18 +
                    config.interestLargeCapX18.mul(
                        (
                            (utilizationRatioX18 -
                                config.interestInflectionUtilX18).div(
                                    ONE - config.interestInflectionUtilX18
                                )
                        )
                    );
            }

            // convert to per second
            borrowerRateX18 = borrowerRateX18.div(
                PRBMathSD59x18.fromInt(31536000)
            );
            borrowRateMultiplierX18 = (ONE + borrowerRateX18).pow(
                int256(dt).fromInt()
            );
        }

        // if we don't take fees into account, the liquidity, which is
        // (deposits - borrows) should remain the same after updating state.

        // For simplicity, we use `tb`, `cbm`, `td`, and `cdm` for
        // `totalBorrowsNormalized`, `cumulativeBorrowsMultiplier`,
        // `totalDepositsNormalized`, and `cumulativeDepositsMultiplier`

        // before the updating, the liquidity is (td * cdm - tb * cbm)
        // after the updating, the liquidity is
        // (td * cdm * depositRateMultiplier - tb * cbm * borrowRateMultiplier)
        // so we can get
        // depositRateMultiplier = utilization * (borrowRateMultiplier - 1) + 1
        int256 totalDepositRateX18 = utilizationRatioX18.mul(
            borrowRateMultiplierX18 - ONE
        );

        // deduct protocol fees
        int256 realizedDepositRateX18 = totalDepositRateX18.mul(
            ONE - _fees.getInterestFeeFractionX18(productId)
        );

        // pass fees balance change
        int256 feesAmtX18 = totalDepositsX18.mul(
            totalDepositRateX18 - realizedDepositRateX18
        );

        state.cumulativeBorrowsMultiplierX18 = state
            .cumulativeBorrowsMultiplierX18
            .mul(borrowRateMultiplierX18);

        state.cumulativeDepositsMultiplierX18 = state
            .cumulativeDepositsMultiplierX18
            .mul(ONE + realizedDepositRateX18);

        if (feesAmtX18 != 0) {
            Balance memory feesAccBalance = balances[productId][
                FEES_SUBACCOUNT_ID
            ];
            _updateBalance(state, feesAccBalance, feesAmtX18);
            balances[productId][FEES_SUBACCOUNT_ID] = feesAccBalance;
        }
    }

    function getStateAndBalance(
        uint32 productId,
        uint64 subaccountId
    ) public view returns (State memory, Balance memory) {
        State memory state = states[productId];
        Balance memory balance = balances[productId][subaccountId];
        _updateBalance(state, balance, 0);
        return (state, balance);
    }

    function getStatesAndBalances(
        uint32 productId,
        uint64 subaccountId
    )
        external
        view
        returns (LpState memory, LpBalance memory, State memory, Balance memory)
    {
        LpState memory lpState = lpStates[productId];
        State memory state = states[productId];
        LpBalance memory lpBalance = lpBalances[productId][subaccountId];
        Balance memory balance = balances[productId][subaccountId];
        _updateBalance(state, balance, 0);
        return (lpState, lpBalance, state, balance);
    }

    function updateStates(uint256 dt) external {
        State memory quoteState = states[QUOTE_PRODUCT_ID];
        _updateState(QUOTE_PRODUCT_ID, quoteState, dt);

        for (uint32 i = 0; i < productIds.length; i++) {
            uint32 productId = productIds[i];
            if (productId == QUOTE_PRODUCT_ID) {
                continue;
            }
            State memory state = states[productId];
            LpState memory lpState = lpStates[productId];
            _updateState(productId, state, dt);
            _updateBalance(state, lpState.base, 0);
            _updateBalance(quoteState, lpState.quote, 0);
            lpStates[productId] = lpState;
            states[productId] = state;
        }
        states[QUOTE_PRODUCT_ID] = quoteState;
    }
}
