// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

import "./common/Constants.sol";
import "./common/Errors.sol";
import "./interfaces/IOffchainBook.sol";
import "./interfaces/engine/ISpotEngine.sol";
import "./interfaces/clearinghouse/IClearinghouse.sol";
import "./libraries/MathHelper.sol";
import "./libraries/MathSD21x18.sol";
import "./BaseEngine.sol";
import "./SpotEngineState.sol";
import "./SpotEngineLP.sol";

contract SpotEngine is SpotEngineLP {
    using MathSD21x18 for int128;

    function initialize(
        address _clearinghouse,
        address _quote,
        address _endpoint,
        address _admin,
        address _fees
    ) external {
        _initialize(_clearinghouse, _quote, _endpoint, _admin, _fees);

        configs[QUOTE_PRODUCT_ID] = Config({
            token: _quote,
            interestInflectionUtilX18: 8e17, // .8
            interestFloorX18: 1e16, // .01
            interestSmallCapX18: 4e16, // .04
            interestLargeCapX18: ONE // 1
        });
        states[QUOTE_PRODUCT_ID] = State({
            cumulativeDepositsMultiplierX18: ONE,
            cumulativeBorrowsMultiplierX18: ONE,
            totalDepositsNormalized: 0,
            totalBorrowsNormalized: 0
        });
        productIds.push(QUOTE_PRODUCT_ID);
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
        Config calldata config,
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
    function applyDeltas(ProductDelta[] calldata deltas) external {
        checkCanApplyDeltas();

        // May load the same product multiple times
        for (uint32 i = 0; i < deltas.length; i++) {
            if (deltas[i].amountDelta == 0) {
                continue;
            }

            uint32 productId = deltas[i].productId;
            uint64 subaccountId = deltas[i].subaccountId;
            int128 amountDelta = deltas[i].amountDelta;
            State memory state = states[productId];
            Balance memory balance = balances[productId][subaccountId];

            _updateBalance(state, balance, amountDelta);

            states[productId].totalDepositsNormalized = state
                .totalDepositsNormalized;
            states[productId].totalBorrowsNormalized = state
                .totalBorrowsNormalized;

            balances[productId][subaccountId] = balance;

            emit ProductUpdate(productId);
        }
    }

    function socializeSubaccount(uint64 subaccountId, int128 insurance)
        external
        returns (int128)
    {
        require(msg.sender == address(_clearinghouse), ERR_UNAUTHORIZED);

        // if the insurance fund still has value we shouldn't socialize
        // instead whatever remaining spot should be liquidated
        if (insurance > 0) {
            return insurance;
        }

        for (uint128 i = 0; i < productIds.length; ++i) {
            uint32 productId = productIds[i];
            (State memory state, Balance memory balance) = getStateAndBalance(
                productId,
                subaccountId
            );
            if (balance.amount < 0) {
                int128 totalDeposited = state.totalDepositsNormalized.mul(
                    state.cumulativeDepositsMultiplierX18
                );

                state.cumulativeDepositsMultiplierX18 = (totalDeposited +
                    balance.amount).div(state.totalDepositsNormalized);

                emit SocializeProduct(productId, -balance.amount);

                state.totalBorrowsNormalized += balance.amount.div(
                    state.cumulativeBorrowsMultiplierX18
                );
                balance.amount = 0;

                balances[productId][subaccountId] = balance;
                states[productId] = state;
            }
        }

        return insurance;
    }
}
