// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

import "hardhat/console.sol";

import "./common/Constants.sol";
import "./common/Errors.sol";
import "./interfaces/engine/IProductEngine.sol";
import "./interfaces/engine/IPerpEngine.sol";
import "./interfaces/clearinghouse/IClearinghouse.sol";
import "./libraries/MathHelper.sol";
import "./libraries/MathSD21x18.sol";
import "./BaseEngine.sol";
import "./PerpEngineLp.sol";

contract PerpEngine is PerpEngineLp {
    using MathSD21x18 for int128;

    function initialize(
        address _clearinghouse,
        address _quote,
        address _endpoint,
        address _admin,
        address _fees
    ) external {
        _initialize(_clearinghouse, _quote, _endpoint, _admin, _fees);
    }

    function getEngineType() external pure returns (EngineType) {
        return EngineType.PERP;
    }

    /**
     * Actions
     */

    /// @notice adds a new product with default parameters
    function addProduct(
        uint32 healthGroup,
        address book,
        int128 sizeIncrement,
        int128 priceIncrementX18,
        int128 lpSpreadX18,
        IClearinghouseState.RiskStore calldata riskStore
    ) public onlyOwner {
        require(
            riskStore.longWeightInitial < riskStore.longWeightMaintenance &&
                riskStore.shortWeightInitial > riskStore.shortWeightMaintenance,
            ERR_BAD_PRODUCT_CONFIG
        );
        uint32 productId = _addProductForId(
            healthGroup,
            riskStore,
            book,
            sizeIncrement,
            priceIncrementX18,
            lpSpreadX18
        );

        states[productId] = State({
            cumulativeFundingLongX18: ONE,
            cumulativeFundingShortX18: ONE,
            availableSettle: 0,
            openInterest: 0
        });

        lpStates[productId] = LpState({
            supply: 0,
            lastCumulativeFundingX18: 0,
            cumulativeFundingPerLpX18: 0,
            base: 0,
            quote: 0
        });
    }

    /// @notice changes the configs of a product, if a new book is provided
    /// also clears the book
    //    function changeProductConfigs(
    //        uint32 productId,
    //        int128 sizeIncrement,
    //        int128 priceIncrementX18,
    //        address book,
    //        Config calldata config
    //    ) public onlyOwner {
    //        require(
    //            config.longWeightInitialX18 < config.longWeightMaintenanceX18 &&
    //                config.shortWeightInitialX18 > config.shortWeightMaintenanceX18,
    //            ERR_BAD_PRODUCT_CONFIG
    //        );
    //        if (book != address(0)) {
    //            // full wipe
    //            delete markets[productId];
    //
    //            markets[productId] = IOffchainBook(book);
    //            markets[productId].initialize(
    //                _clearinghouse,
    //                this,
    //                owner(),
    //                getEndpoint(),
    //                _fees,
    //                productId,
    //                sizeIncrement,
    //                priceIncrementX18
    //            );
    //
    //            products[productId].config = config;
    //        } else {
    //            // we don't update sizeincrement and priceincrement if we aren't also wiping book
    //            products[productId].config = config;
    //        }
    //    }

    /// @notice updates internal balances; given tuples of (product, subaccount, delta)
    /// since tuples aren't a thing in solidity, params specify the transpose
    function applyDeltas(IProductEngine.ProductDelta[] calldata deltas)
        external
    {
        // Only a market book can apply deltas
        checkCanApplyDeltas();

        // May load the same product multiple times
        for (uint32 i = 0; i < deltas.length; i++) {
            uint32 productId = deltas[i].productId;
            // For perps, quote deltas are applied in `vQuoteDelta`
            if (
                productId == QUOTE_PRODUCT_ID ||
                (deltas[i].amountDelta == 0 && deltas[i].vQuoteDelta == 0)
            ) {
                continue;
            }

            uint64 subaccountId = deltas[i].subaccountId;
            int128 amountDelta = deltas[i].amountDelta;
            int128 vQuoteDelta = deltas[i].vQuoteDelta;

            State memory state = states[productId];
            Balance memory balance = balances[productId][subaccountId];

            _updateBalance(state, balance, amountDelta, vQuoteDelta);

            states[productId] = state;
            balances[productId][subaccountId] = balance;

            emit ProductUpdate(productId);
        }
    }

    function settlePnl(uint64 subaccountId) external returns (int128) {
        checkCanApplyDeltas();
        int128 totalSettled = 0;

        for (uint128 i = 0; i < productIds.length; ++i) {
            uint32 productId = productIds[i];
            (
                int128 canSettle,
                LpState memory lpState,
                LpBalance memory lpBalance,
                State memory state,
                Balance memory balance
            ) = getSettlementState(productId, subaccountId);

            if (canSettle != 0) {
                // Product and balance updates in getSettlementState
                state.availableSettle -= canSettle;
                balance.vQuoteBalance -= canSettle;

                totalSettled += canSettle;

                lpStates[productId] = lpState;
                states[productId] = state;
                lpBalances[productId][subaccountId] = lpBalance;
                balances[productId][subaccountId] = balance;
                emit SettlePnl(subaccountId, productId, canSettle);
            }
        }

        return totalSettled;
    }

    function getSettlementState(uint32 productId, uint64 subaccountId)
        public
        view
        returns (
            int128 availableSettle,
            LpState memory lpState,
            LpBalance memory lpBalance,
            State memory state,
            Balance memory balance
        )
    {
        int128 priceX18 = getOraclePriceX18(productId);
        (lpState, lpBalance, state, balance) = getStatesAndBalances(
            productId,
            subaccountId
        );

        (int128 ammBase, int128 ammQuote) = MathHelper.ammEquilibrium(
            lpState.base,
            lpState.quote,
            priceX18
        );

        int128 positionPnl;

        if (lpBalance.amount == 0) {
            positionPnl = priceX18.mul(balance.amount) + balance.vQuoteBalance;
        } else {
            positionPnl =
                priceX18.mul(
                    balance.amount +
                        ammBase.mul(lpBalance.amount).div(lpState.supply)
                ) +
                balance.vQuoteBalance +
                ammQuote.mul(lpBalance.amount).div(lpState.supply);
        }

        availableSettle = MathHelper.min(positionPnl, state.availableSettle);
    }

    function socializeSubaccount(uint64 subaccountId, int128 insurance)
        external
        returns (int128)
    {
        require(msg.sender == address(_clearinghouse), ERR_UNAUTHORIZED);

        for (uint128 i = 0; i < productIds.length; ++i) {
            uint32 productId = productIds[i];
            (State memory state, Balance memory balance) = getStateAndBalance(
                productId,
                subaccountId
            );
            if (balance.vQuoteBalance < 0) {
                int128 insuranceCover = MathHelper.min(
                    insurance,
                    -balance.vQuoteBalance
                );
                insurance -= insuranceCover;
                balance.vQuoteBalance += insuranceCover;

                // actually socialize if still not enough
                if (balance.vQuoteBalance < 0) {
                    // socialize across all other participants
                    int128 fundingPerShare = -balance.vQuoteBalance.div(
                        state.openInterest
                    ) / 2;
                    state.cumulativeFundingLongX18 += fundingPerShare;
                    state.cumulativeFundingShortX18 -= fundingPerShare;
                    states[productId] = state;
                    balance.vQuoteBalance = 0;
                    emit SocializeProduct(productId, -balance.vQuoteBalance);
                }
                balances[productId][subaccountId] = balance;
            }
        }
        return insurance;
    }
}
