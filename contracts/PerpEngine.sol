// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

import "prb-math/contracts/PRBMathSD59x18.sol";
import "hardhat/console.sol";

import "./common/Constants.sol";
import "./common/Errors.sol";
import "./interfaces/engine/IProductEngine.sol";
import "./interfaces/engine/IPerpEngine.sol";
import "./interfaces/clearinghouse/IClearinghouse.sol";
import "./libraries/MathHelper.sol";
import "./BaseEngine.sol";
import "./PerpEngineLp.sol";

contract PerpEngine is PerpEngineLp {
    using PRBMathSD59x18 for int256;

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
        int256 sizeIncrement,
        int256 priceIncrementX18,
        int256 lpSpreadX18,
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
            availableSettleX18: 0,
            openInterestX18: 0
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
    //        int256 sizeIncrement,
    //        int256 priceIncrementX18,
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
            // For perps, quote deltas are applied in `vQuoteDeltaX18`
            if (
                productId == QUOTE_PRODUCT_ID ||
                (deltas[i].amountDeltaX18 == 0 && deltas[i].vQuoteDeltaX18 == 0)
            ) {
                continue;
            }

            uint64 subaccountId = deltas[i].subaccountId;
            int256 amountDeltaX18 = deltas[i].amountDeltaX18;
            int256 vQuoteDeltaX18 = deltas[i].vQuoteDeltaX18;

            State memory state = states[productId];
            Balance memory balance = balances[productId][subaccountId];

            _updateBalance(state, balance, amountDeltaX18, vQuoteDeltaX18);

            states[productId] = state;
            balances[productId][subaccountId] = balance;

            emit ProductUpdate(productId);
        }
    }

    function settlePnl(uint64 subaccountId) external returns (int256) {
        require(msg.sender == address(_clearinghouse), ERR_UNAUTHORIZED);
        int256 totalSettledX18 = 0;

        for (uint256 i = 0; i < productIds.length; ++i) {
            uint32 productId = productIds[i];
            (
                int256 canSettleX18,
                LpState memory lpState,
                LpBalance memory lpBalance,
                State memory state,
                Balance memory balance
            ) = getSettlementState(productId, subaccountId);

            if (canSettleX18 != 0) {
                // Product and balance updates in getSettlementState
                state.availableSettleX18 -= canSettleX18;
                balance.vQuoteBalanceX18 -= canSettleX18;

                totalSettledX18 += canSettleX18;

                lpStates[productId] = lpState;
                states[productId] = state;
                lpBalances[productId][subaccountId] = lpBalance;
                balances[productId][subaccountId] = balance;
                emit SettlePnl(subaccountId, productId, canSettleX18.toInt());
            }
        }

        return totalSettledX18;
    }

    function getSettlementState(uint32 productId, uint64 subaccountId)
        public
        view
        returns (
            int256 availableSettleX18,
            LpState memory lpState,
            LpBalance memory lpBalance,
            State memory state,
            Balance memory balance
        )
    {
        int256 priceX18 = getOraclePriceX18(productId);
        (lpState, lpBalance, state, balance) = getStatesAndBalances(
            productId,
            subaccountId
        );

        (int256 ammBaseX18, int256 ammQuoteX18) = MathHelper.ammEquilibrium(
            lpState.base.fromInt(),
            lpState.quote.fromInt(),
            priceX18
        );

        int256 ratioX18 = lpBalance.amountX18 == 0
            ? int256(0)
            : lpBalance.amountX18.div(lpState.supply.fromInt());

        int256 positionPnlX18 = priceX18.mul(balance.amountX18 + ammBaseX18) +
            balance.vQuoteBalanceX18 +
            ammQuoteX18.mul(ratioX18);

        availableSettleX18 = MathHelper.min(
            positionPnlX18,
            state.availableSettleX18
        );
    }

    function socializeSubaccount(uint64 subaccountId, int256 insuranceX18)
        external
        returns (int256)
    {
        require(msg.sender == address(_clearinghouse), ERR_UNAUTHORIZED);

        for (uint256 i = 0; i < productIds.length; ++i) {
            uint32 productId = productIds[i];
            (State memory state, Balance memory balance) = getStateAndBalance(
                productId,
                subaccountId
            );
            if (balance.vQuoteBalanceX18 < 0) {
                int256 insuranceCoverX18 = MathHelper.min(
                    insuranceX18,
                    -balance.vQuoteBalanceX18
                );
                insuranceX18 -= insuranceCoverX18;
                balance.vQuoteBalanceX18 += insuranceCoverX18;

                // actually socialize if still not enough
                if (balance.vQuoteBalanceX18 < 0) {
                    // socialize across all other participants
                    int256 fundingPerShareX18 = -balance.vQuoteBalanceX18.div(
                        state.openInterestX18
                    ) / 2;
                    state.cumulativeFundingLongX18 += fundingPerShareX18;
                    state.cumulativeFundingShortX18 -= fundingPerShareX18;
                    states[productId] = state;
                    balance.vQuoteBalanceX18 = 0;
                    emit SocializeProduct(productId, -balance.vQuoteBalanceX18);
                }
                balances[productId][subaccountId] = balance;
            }
        }
        return insuranceX18;
    }
}
