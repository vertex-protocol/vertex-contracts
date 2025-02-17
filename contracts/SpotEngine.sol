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
import "./Version.sol";

contract SpotEngine is SpotEngineLP, Version {
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
        withdrawFees[QUOTE_PRODUCT_ID] = 1e16;
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

    function getWithdrawFee(uint32 productId) external view returns (int128) {
        return withdrawFees[productId];
    }

    function setWithdrawFee(uint32 productId, int128 withdrawFee)
        public
        onlyOwner
    {
        if (productId == QUOTE_PRODUCT_ID) {
            withdrawFees[QUOTE_PRODUCT_ID] = 1e16;
        } else {
            withdrawFees[productId] = withdrawFee;
        }
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
        int128 minSize,
        int128 lpSpreadX18,
        int128 withdrawFee,
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

        withdrawFees[productId] = withdrawFee;

        lpStates[productId] = LpState({
            supply: 0,
            quote: Balance({amount: 0, lastCumulativeMultiplierX18: ONE}),
            base: Balance({amount: 0, lastCumulativeMultiplierX18: ONE})
        });
    }

    function updateProduct(
        uint32 productId,
        int128 sizeIncrement,
        int128 priceIncrementX18,
        int128 minSize,
        int128 lpSpreadX18,
        int128 withdrawFee,
        Config calldata config,
        IClearinghouseState.RiskStore calldata riskStore
    ) public onlyOwner {
        require(
            riskStore.longWeightInitial < riskStore.longWeightMaintenance &&
                riskStore.shortWeightInitial > riskStore.shortWeightMaintenance,
            ERR_BAD_PRODUCT_CONFIG
        );
        markets[productId].modifyConfig(
            sizeIncrement,
            priceIncrementX18,
            minSize,
            lpSpreadX18
        );

        withdrawFees[productId] = withdrawFee;
        configs[productId] = config;
        _clearinghouse.modifyProductConfig(productId, riskStore);
    }

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
            bytes32 subaccount = deltas[i].subaccount;
            int128 amountDelta = deltas[i].amountDelta;
            State memory state = states[productId];
            BalanceNormalized memory balance = balances[productId][subaccount]
                .balance;

            _updateBalanceNormalized(state, balance, amountDelta);

            states[productId].totalDepositsNormalized = state
                .totalDepositsNormalized;
            states[productId].totalBorrowsNormalized = state
                .totalBorrowsNormalized;

            balances[productId][subaccount].balance = balance;

            emit ProductUpdate(productId);
        }
    }

    function socializeSubaccount(bytes32 subaccount) external {
        require(msg.sender == address(_clearinghouse), ERR_UNAUTHORIZED);

        for (uint128 i = 0; i < productIds.length; ++i) {
            uint32 productId = productIds[i];
            (State memory state, Balance memory balance) = getStateAndBalance(
                productId,
                subaccount
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

                balances[productId][subaccount].balance.amountNormalized = 0;
                states[productId] = state;
            }
        }
    }

    function manualAssert(
        int128[] calldata totalDeposits,
        int128[] calldata totalBorrows
    ) external view {
        for (uint128 i = 0; i < productIds.length; ++i) {
            uint32 productId = productIds[i];
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
}
