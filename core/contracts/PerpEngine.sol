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
        address _offchainExchange,
        address,
        address _endpoint,
        address _admin
    ) external {
        _initialize(_clearinghouse, _offchainExchange, _endpoint, _admin);
    }

    function getEngineType() external pure returns (EngineType) {
        return EngineType.PERP;
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
        RiskHelper.RiskStore calldata riskStore
    ) public onlyOwner {
        _addProductForId(
            productId,
            QUOTE_PRODUCT_ID,
            book,
            sizeIncrement,
            minSize,
            lpSpreadX18,
            riskStore
        );

        states[productId] = State({
            cumulativeFundingLongX18: 0,
            cumulativeFundingShortX18: 0,
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
    function updateProduct(bytes calldata rawTxn) external onlyEndpoint {
        UpdateProductTx memory txn = abi.decode(rawTxn, (UpdateProductTx));
        RiskHelper.RiskStore memory riskStore = txn.riskStore;

        require(
            riskStore.longWeightInitial <= riskStore.longWeightMaintenance &&
                riskStore.shortWeightInitial >=
                riskStore.shortWeightMaintenance,
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
            type(uint32).max,
            address(0),
            txn.sizeIncrement,
            txn.minSize,
            txn.lpSpreadX18
        );
    }

    function updateBalance(
        uint32 productId,
        bytes32 subaccount,
        int128 amountDelta,
        int128 vQuoteDelta
    ) external {
        // Only a market book can apply deltas
        _assertInternal();
        State memory state = states[productId];
        Balance memory balance = balances[productId][subaccount];

        _updateBalance(state, balance, amountDelta, vQuoteDelta);

        states[productId] = state;
        balances[productId][subaccount] = balance;
        _balanceUpdate(productId, subaccount);
    }

    function settlePnl(bytes32 subaccount, uint256 productIds)
        external
        returns (int128)
    {
        _assertInternal();
        int128 totalSettled = 0;

        while (productIds != 0) {
            uint32 productId = uint32(productIds & ((1 << 32) - 1));
            // otherwise it means the product is a spot.
            if (productId % 2 == 0) {
                (
                    int128 canSettle,
                    LpState memory lpState,
                    LpBalance memory lpBalance,
                    State memory state,
                    Balance memory balance
                ) = getSettlementState(productId, subaccount);

                state.availableSettle -= canSettle;
                balance.vQuoteBalance -= canSettle;

                totalSettled += canSettle;

                lpStates[productId] = lpState;
                states[productId] = state;
                lpBalances[productId][subaccount] = lpBalance;
                balances[productId][subaccount] = balance;
                _balanceUpdate(productId, subaccount);
            }
            productIds >>= 32;
        }
        return totalSettled;
    }

    function calculatePositionPnl(
        LpState memory lpState,
        LpBalance memory lpBalance,
        Balance memory balance,
        uint32 productId
    ) internal view returns (int128 positionPnl) {
        int128 priceX18 = _risk(productId).priceX18;

        (int128 ammBase, int128 ammQuote) = MathHelper.ammEquilibrium(
            lpState.base,
            lpState.quote,
            priceX18
        );

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
    }

    function getPositionPnl(uint32 productId, bytes32 subaccount)
        external
        view
        returns (int128)
    {
        (
            LpState memory lpState,
            LpBalance memory lpBalance,
            ,
            Balance memory balance
        ) = getStatesAndBalances(productId, subaccount);

        return calculatePositionPnl(lpState, lpBalance, balance, productId);
    }

    function getSettlementState(uint32 productId, bytes32 subaccount)
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
        (lpState, lpBalance, state, balance) = getStatesAndBalances(
            productId,
            subaccount
        );

        availableSettle = MathHelper.min(
            calculatePositionPnl(lpState, lpBalance, balance, productId),
            state.availableSettle
        );
    }

    function socializeSubaccount(bytes32 subaccount, int128 insurance)
        external
        returns (int128)
    {
        require(msg.sender == address(_clearinghouse), ERR_UNAUTHORIZED);

        uint32[] memory _productIds = getProductIds();
        for (uint128 i = 0; i < _productIds.length; ++i) {
            uint32 productId = _productIds[i];
            (State memory state, Balance memory balance) = getStateAndBalance(
                productId,
                subaccount
            );
            if (balance.vQuoteBalance < 0) {
                int128 insuranceCover = MathHelper.min(
                    insurance,
                    -balance.vQuoteBalance
                );
                insurance -= insuranceCover;
                balance.vQuoteBalance += insuranceCover;
                state.availableSettle += insuranceCover;

                // actually socialize if still not enough
                if (balance.vQuoteBalance < 0) {
                    // socialize across all other participants
                    int128 fundingPerShare = -balance.vQuoteBalance.div(
                        state.openInterest
                    ) / 2;
                    state.cumulativeFundingLongX18 += fundingPerShare;
                    state.cumulativeFundingShortX18 -= fundingPerShare;

                    LpState memory lpState = lpStates[productId];
                    Balance memory tmp = Balance({
                        amount: lpState.base,
                        vQuoteBalance: 0,
                        lastCumulativeFundingX18: lpState
                            .lastCumulativeFundingX18
                    });
                    _updateBalance(state, tmp, 0, 0);
                    if (lpState.supply != 0) {
                        lpState.cumulativeFundingPerLpX18 += tmp
                            .vQuoteBalance
                            .div(lpState.supply);
                    }
                    lpState.lastCumulativeFundingX18 = state
                        .cumulativeFundingLongX18;

                    lpStates[productId] = lpState;
                    balance.vQuoteBalance = 0;
                }
                states[productId] = state;
                balances[productId][subaccount] = balance;
                _balanceUpdate(productId, subaccount);
            }
        }
        return insurance;
    }

    function manualAssert(int128[] calldata openInterests) external view {
        for (uint128 i = 0; i < openInterests.length; ++i) {
            uint32 productId = productIds[i];
            require(
                states[productId].openInterest == openInterests[i],
                ERR_DSYNC
            );
        }
    }
}
