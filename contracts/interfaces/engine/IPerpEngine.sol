// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

import "./IProductEngine.sol";

interface IPerpEngine is IProductEngine {
    struct State {
        int128 cumulativeFundingLongX18;
        int128 cumulativeFundingShortX18;
        int128 availableSettle;
        int128 openInterest;
    }

    struct Balance {
        int128 amount;
        int128 vQuoteBalance;
        int128 lastCumulativeFundingX18;
    }

    struct LpState {
        int128 supply;
        int128 lastCumulativeFundingX18;
        int128 cumulativeFundingPerLpX18;
        int128 base;
        int128 quote;
    }

    struct LpBalance {
        int128 amount;
        // NOTE: funding payments should be rolled
        // into Balance.vQuoteBalance;
        int128 lastCumulativeFundingX18;
    }

    function getStateAndBalance(uint32 productId, uint64 subaccountId)
        external
        view
        returns (State memory, Balance memory);

    function hasBalance(uint32 productId, uint64 subaccountId)
        external
        view
        returns (bool);

    function getStatesAndBalances(uint32 productId, uint64 subaccountId)
        external
        view
        returns (
            LpState memory,
            LpBalance memory,
            State memory,
            Balance memory
        );

    /// @dev Returns amount settled and emits SettlePnl events for each product
    function settlePnl(uint64 subaccountId) external returns (int128);

    /// @notice Emitted during perp settlement
    event SettlePnl(uint64 indexed subaccount, uint32 productId, int128 amount);

    function getSettlementState(uint32 productId, uint64 subaccountId)
        external
        view
        returns (
            int128 availableSettle,
            LpState memory lpState,
            LpBalance memory lpBalance,
            State memory state,
            Balance memory balance
        );

    function updateStates(uint128 dt, int128[] calldata avgPriceDiffs) external;
}
