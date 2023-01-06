// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

import "./IProductEngine.sol";

interface ISpotEngine is IProductEngine {
    struct Config {
        address token;
        int256 interestInflectionUtilX18;
        int256 interestFloorX18;
        int256 interestSmallCapX18;
        int256 interestLargeCapX18;
    }

    struct State {
        int256 cumulativeDepositsMultiplierX18;
        int256 cumulativeBorrowsMultiplierX18;
        int256 totalDepositsNormalizedX18;
        int256 totalBorrowsNormalizedX18;
    }

    struct Balance {
        int256 amountX18;
        int256 lastCumulativeMultiplierX18;
    }

    struct LpState {
        int256 supply;
        Balance quote;
        Balance base;
    }

    struct LpBalance {
        int256 amountX18;
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

    function getConfig(uint32 productId) external view returns (Config memory);
}
