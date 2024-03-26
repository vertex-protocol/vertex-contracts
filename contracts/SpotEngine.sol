// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

import "./common/Constants.sol";
import "./common/Errors.sol";
import "./interfaces/engine/ISpotEngine.sol";
import "./interfaces/clearinghouse/IClearinghouse.sol";
import "./libraries/MathHelper.sol";
import "./libraries/MathSD21x18.sol";
import "./libraries/RiskHelper.sol";
import "./BaseEngine.sol";
import "./SpotEngineState.sol";
import "./SpotEngineLP.sol";
import "./Version.sol";

contract SpotEngine is SpotEngineLP, Version {
    using MathSD21x18 for int128;

    function initialize(
        address _clearinghouse,
        address _offchainExchange,
        address _quote,
        address _endpoint,
        address _admin
    ) external {
        _initialize(_clearinghouse, _offchainExchange, _endpoint, _admin);

        configs[QUOTE_PRODUCT_ID] = Config({
            token: _quote,
            interestInflectionUtilX18: 8e17, // .8
            interestFloorX18: 1e16, // .01
            interestSmallCapX18: 4e16, // .04
            interestLargeCapX18: ONE // 1
        });
        _risk().value[QUOTE_PRODUCT_ID] = RiskHelper.RiskStore({
            longWeightInitial: 1e9,
            shortWeightInitial: 1e9,
            longWeightMaintenance: 1e9,
            shortWeightMaintenance: 1e9,
            priceX18: ONE
        });
        states[QUOTE_PRODUCT_ID] = State({
            cumulativeDepositsMultiplierX18: ONE,
            cumulativeBorrowsMultiplierX18: ONE,
            totalDepositsNormalized: 0,
            totalBorrowsNormalized: 0
        });
        productIds.push(QUOTE_PRODUCT_ID);
        _crossMask().value |= 1; // 1 << 0
        emit AddProduct(QUOTE_PRODUCT_ID);
    }

    /**
     * View
     */

    function getEngineType() external pure returns (EngineType) {
        return EngineType.SPOT;
    }

    function getConfig(uint32 productId) external view returns (Config memory) {
        return configs[productId];
    }

    function getWithdrawFee(uint32 productId) external pure returns (int128) {
        // TODO: use the map the store withdraw fees
        // return withdrawFees[productId];
        if (productId == QUOTE_PRODUCT_ID) {
            return 1e18;
        } else if (productId == 1) {
            // BTC
            return 4e13;
        } else if (productId == 3 || productId == 91) {
            // ETH
            return 6e14;
        } else if (productId == 5) {
            // ARB
            return 1e18;
        } else if (productId == 31) {
            // USDT
            return 1e18;
        } else if (productId == 41) {
            // VRTX
            return 1e18;
        }
        return 0;
    }

    /**
     * Actions
     */

    /// @notice adds a new product with default parameters
    function addProduct(
        uint32 productId,
        address book,
        int128 sizeIncrement,
        int128 minSize,
        int128 lpSpreadX18,
        Config calldata config,
        RiskHelper.RiskStore calldata riskStore
    ) public onlyOwner {
        require(productId != QUOTE_PRODUCT_ID);
        _addProductForId(
            productId,
            riskStore,
            book,
            sizeIncrement,
            minSize,
            lpSpreadX18
        );

        configs[productId] = config;
        states[productId] = State({
            cumulativeDepositsMultiplierX18: ONE,
            cumulativeBorrowsMultiplierX18: ONE,
            totalDepositsNormalized: 0,
            totalBorrowsNormalized: 0
        });

        lpStates[productId] = LpState({
            supply: 0,
            quote: Balance({amount: 0, lastCumulativeMultiplierX18: ONE}),
            base: Balance({amount: 0, lastCumulativeMultiplierX18: ONE})
        });
    }

    function updateProduct(bytes calldata rawTxn) external onlyEndpoint {
        UpdateProductTx memory txn = abi.decode(rawTxn, (UpdateProductTx));
        RiskHelper.RiskStore memory riskStore = txn.riskStore;

        if (txn.productId != QUOTE_PRODUCT_ID) {
            require(
                riskStore.longWeightInitial <=
                    riskStore.longWeightMaintenance &&
                    riskStore.shortWeightInitial >=
                    riskStore.shortWeightMaintenance &&
                    // we messed up placeholder's token address so we have to find
                    // a new way to check whether a product is a placeholder.
                    (states[txn.productId].totalDepositsNormalized == 0 ||
                        configs[txn.productId].token == txn.config.token),
                ERR_BAD_PRODUCT_CONFIG
            );

            RiskHelper.RiskStore memory r = _risk().value[txn.productId];
            r.longWeightInitial = riskStore.longWeightInitial;
            r.shortWeightInitial = riskStore.shortWeightInitial;
            r.longWeightMaintenance = riskStore.longWeightMaintenance;
            r.shortWeightMaintenance = riskStore.shortWeightMaintenance;
            _risk().value[txn.productId] = r;

            _exchange().updateMarket(
                txn.productId,
                address(0),
                txn.sizeIncrement,
                txn.minSize,
                txn.lpSpreadX18
            );
        }

        configs[txn.productId] = txn.config;
    }

    function updateQuoteFromInsurance(bytes32 subaccount, int128 insurance)
        external
        returns (int128)
    {
        _assertInternal();
        //        uint32 isoGroup = RiskHelper.isoGroup(subaccount);
        //        State memory state = _getQuoteState(isoGroup);
        State memory state = states[QUOTE_PRODUCT_ID];
        BalanceNormalized memory balanceNormalized = balances[QUOTE_PRODUCT_ID][
            subaccount
        ].balance;
        int128 balanceAmount = balanceNormalizedToBalance(
            state,
            balanceNormalized
        ).amount;
        if (balanceAmount < 0) {
            int128 topUpAmount = MathHelper.max(
                MathHelper.min(insurance, -balanceAmount),
                0
            );
            insurance -= topUpAmount;
            _updateBalanceNormalized(state, balanceNormalized, topUpAmount);
        }
        //        quoteStates[isoGroup] = state;
        states[QUOTE_PRODUCT_ID] = state;
        balances[QUOTE_PRODUCT_ID][subaccount].balance = balanceNormalized;
        return insurance;
    }

    function updateBalance(
        uint32 productId,
        bytes32 subaccount,
        int128 amountDelta,
        int128 quoteDelta
    ) external {
        require(productId != QUOTE_PRODUCT_ID, ERR_INVALID_PRODUCT);
        _assertInternal();
        State memory state = states[productId];
        State memory quoteState = states[QUOTE_PRODUCT_ID];

        BalanceNormalized memory balance = balances[productId][subaccount]
            .balance;

        BalanceNormalized memory quoteBalance = balances[QUOTE_PRODUCT_ID][
            subaccount
        ].balance;

        if (subaccount == X_ACCOUNT && migrationFlag == 0) {
            _updateBalanceNormalizedNoTotals(state, balance, amountDelta);
            _updateBalanceNormalizedNoTotals(
                quoteState,
                quoteBalance,
                quoteDelta
            );
        } else {
            _updateBalanceNormalized(state, balance, amountDelta);
            _updateBalanceNormalized(quoteState, quoteBalance, quoteDelta);
        }

        balances[productId][subaccount].balance = balance;
        balances[QUOTE_PRODUCT_ID][subaccount].balance = quoteBalance;

        //        if (productId == QUOTE_PRODUCT_ID) {
        //            quoteStates[RiskHelper.isoGroup(subaccount)] = state;
        //        } else {
        //            states[productId] = state;
        //        }
        states[productId] = state;
        states[QUOTE_PRODUCT_ID] = quoteState;

        _balanceUpdate(productId, subaccount);
        _balanceUpdate(QUOTE_PRODUCT_ID, subaccount);
    }

    function updateBalance(
        uint32 productId,
        bytes32 subaccount,
        int128 amountDelta
    ) external {
        _assertInternal();

        //        State memory state = productId == QUOTE_PRODUCT_ID
        //            ? _getQuoteState(RiskHelper.isoGroup(subaccount))
        //            : states[productId];
        State memory state = states[productId];

        BalanceNormalized memory balance = balances[productId][subaccount]
            .balance;
        if (subaccount == X_ACCOUNT && migrationFlag == 0) {
            _updateBalanceNormalizedNoTotals(state, balance, amountDelta);
        } else {
            _updateBalanceNormalized(state, balance, amountDelta);
        }
        balances[productId][subaccount].balance = balance;

        //        if (productId == QUOTE_PRODUCT_ID) {
        //            quoteStates[RiskHelper.isoGroup(subaccount)] = state;
        //        } else {
        //            states[productId] = state;
        //        }
        states[productId] = state;
        _balanceUpdate(productId, subaccount);
    }

    // only check on withdraw -- ensure that users can't withdraw
    // funds that are in the Vertex contract but not officially
    // 'deposited' into the Vertex system and counted in balances
    // (i.e. if a user transfers tokens to the clearinghouse
    // without going through the standard deposit)
    function assertUtilization(uint32 productId) external view {
        (State memory _state, Balance memory _balance) = getStateAndBalance(
            productId,
            X_ACCOUNT
        );
        int128 totalDeposits = _state.totalDepositsNormalized.mul(
            _state.cumulativeDepositsMultiplierX18
        );
        int128 totalBorrows = _state.totalBorrowsNormalized.mul(
            _state.cumulativeBorrowsMultiplierX18
        );
        if (_balance.amount < 0 && migrationFlag == 0) {
            totalDeposits += _balance.amount;
        }
        require(totalDeposits >= totalBorrows, ERR_MAX_UTILIZATION);
    }

    function socializeSubaccount(bytes32 subaccount) external {
        require(msg.sender == address(_clearinghouse), ERR_UNAUTHORIZED);

        uint32 isoGroup = RiskHelper.isoGroup(subaccount);
        uint32[] memory _productIds = getProductIds(isoGroup);
        for (uint128 i = 0; i < _productIds.length; ++i) {
            uint32 productId = _productIds[i];

            //            State memory state = productId == QUOTE_PRODUCT_ID
            //                ? _getQuoteState(isoGroup)
            //                : states[productId];
            State memory state = states[productId];
            Balance memory balance = balanceNormalizedToBalance(
                state,
                balances[productId][subaccount].balance
            );
            if (balance.amount < 0) {
                int128 totalDeposited = state.totalDepositsNormalized.mul(
                    state.cumulativeDepositsMultiplierX18
                );

                state.cumulativeDepositsMultiplierX18 = (totalDeposited +
                    balance.amount).div(state.totalDepositsNormalized);

                state.totalBorrowsNormalized += balance.amount.div(
                    state.cumulativeBorrowsMultiplierX18
                );

                balances[productId][subaccount].balance.amountNormalized = 0;

                if (productId == QUOTE_PRODUCT_ID) {
                    for (uint32 j = 0; j < _productIds.length; ++j) {
                        uint32 baseProductId = _productIds[j];
                        if (baseProductId == QUOTE_PRODUCT_ID) {
                            continue;
                        }
                        LpState memory lpState = lpStates[baseProductId];
                        _updateBalanceWithoutDelta(state, lpState.quote);
                        lpStates[baseProductId] = lpState;
                        _productUpdate(baseProductId);
                    }
                } else {
                    LpState memory lpState = lpStates[productId];
                    _updateBalanceWithoutDelta(state, lpState.base);
                    lpStates[productId] = lpState;
                }
                //                if (productId == QUOTE_PRODUCT_ID) {
                //                    quoteStates[isoGroup] = state;
                //                } else {
                //                    states[productId] = state;
                //                }
                states[productId] = state;
                _balanceUpdate(productId, subaccount);
            }
        }
    }

    function manualAssert(
        int128[] calldata totalDeposits,
        int128[] calldata totalBorrows
    ) external view {
        for (uint128 i = 0; i < totalDeposits.length; ++i) {
            uint32 productId = productIds[i];
            //            State memory state = productId == QUOTE_PRODUCT_ID
            //                ? quoteStates[0]
            //                : states[productId];
            State memory state = states[productId];
            require(
                state.totalDepositsNormalized.mul(
                    state.cumulativeDepositsMultiplierX18
                ) == totalDeposits[i],
                ERR_DSYNC
            );
            require(
                state.totalBorrowsNormalized.mul(
                    state.cumulativeBorrowsMultiplierX18
                ) == totalBorrows[i],
                ERR_DSYNC
            );
        }
    }

    function getToken(uint32 productId) external view returns (address) {
        return address(configs[productId].token);
    }
}
