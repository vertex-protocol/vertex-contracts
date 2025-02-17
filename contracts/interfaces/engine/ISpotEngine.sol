// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

import "./IProductEngine.sol";

interface ISpotEngine is IProductEngine {
    struct Config {
        address token;
        int128 interestInflectionUtilX18;
        int128 interestFloorX18;
        int128 interestSmallCapX18;
        int128 interestLargeCapX18;
    }

    struct State {
        int128 cumulativeDepositsMultiplierX18;
        int128 cumulativeBorrowsMultiplierX18;
        int128 totalDepositsNormalized;
        int128 totalBorrowsNormalized;
    }

    struct Balance {
        int128 amount;
        int128 lastCumulativeMultiplierX18;
    }

    struct LpState {
        int128 supply;
        Balance quote;
        Balance base;
    }

    struct LpBalance {
        int128 amount;
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

    function getConfig(uint32 productId) external view returns (Config memory);

    function getWithdrawTransferAmount(uint32 productId, uint128 amount)
        external
        view
        returns (uint128);

    // TODO: could move utilization ratio tracking off chain and save some gas
    function updateStates(uint128 dt) external;
}
