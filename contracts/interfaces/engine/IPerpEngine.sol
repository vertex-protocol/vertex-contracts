// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

import "./IProductEngine.sol";

interface IPerpEngine is IProductEngine {
    struct State {
        int256 cumulativeFundingLongX18;
        int256 cumulativeFundingShortX18;
        int256 availableSettleX18;
        int256 openInterestX18;
    }

    struct Balance {
        int256 amountX18;
        int256 vQuoteBalanceX18;
        int256 lastCumulativeFundingX18;
    }

    struct LpState {
        int256 supply;
        int256 lastCumulativeFundingX18;
        int256 cumulativeFundingPerLpX18;
        int256 base;
        int256 quote;
    }

    struct LpBalance {
        int256 amountX18;
        // NOTE: funding payments should be rolled
        // into Balance.vQuoteBalanceX18;
        int256 lastCumulativeFundingX18;
    }

    function getStateAndBalance(uint32 productId, uint64 subaccountId)
        external
        view
        returns (State memory, Balance memory);

    function getStatesAndBalances(uint32 productId, uint64 subaccountId)
        external
        view
        returns (
            LpState memory,
            LpBalance memory,
            State memory,
            Balance memory
        );

    /// @dev Returns amount settled in X18 and emits SettlePnl events for each product
    function settlePnl(uint64 subaccountId) external returns (int256);

    /// @notice Emitted during perp settlement
    event SettlePnl(uint64 indexed subaccount, uint32 productId, int256 amount);

    function getSettlementState(uint32 productId, uint64 subaccountId)
        external
        view
        returns (
            int256 availableSettleX18,
            LpState memory lpState,
            LpBalance memory lpBalance,
            State memory state,
            Balance memory balance
        );

    function getMarkPrice(uint32 productId) external view returns (int256);
}
