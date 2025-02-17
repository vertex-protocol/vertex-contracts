// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

import "./IProductEngine.sol";
import "../../libraries/RiskHelper.sol";

interface ISpotEngine is IProductEngine {
    event SpotBalance(
        bytes32 indexed subaccount,
        uint32 indexed productId,
        int128 amount,
        int128 lastCumulativeMultiplierX18
    );

    event InterestPayment(
        uint32 productId,
        uint128 dt,
        int128 depositRateMultiplierX18,
        int128 borrowRateMultiplierX18,
        int128 feeAmount
    );

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

    struct BalanceNormalized {
        int128 amountNormalized;
    }

    struct LpState {
        int128 supply;
        Balance quote;
        Balance base;
    }

    struct LpBalance {
        int128 amount;
    }

    struct Balances {
        BalanceNormalized balance;
        LpBalance lpBalance;
    }

    struct UpdateProductTx {
        uint32 productId;
        int128 sizeIncrement;
        int128 minSize;
        int128 lpSpreadX18;
        Config config;
        RiskHelper.RiskStore riskStore;
    }

    function getStateAndBalance(uint32 productId, bytes32 subaccount)
        external
        view
        returns (State memory, Balance memory);

    function getBalance(uint32 productId, bytes32 subaccount)
        external
        view
        returns (Balance memory);

    function getStatesAndBalances(uint32 productId, bytes32 subaccount)
        external
        view
        returns (
            LpState memory,
            LpBalance memory,
            State memory,
            Balance memory
        );

    function getConfig(uint32 productId) external view returns (Config memory);

    function getToken(uint32 productId) external view returns (address);

    function updateBalance(
        uint32 productId,
        bytes32 subaccount,
        int128 amountDelta
    ) external;

    function updateBalance(
        uint32 productId,
        bytes32 subaccount,
        int128 amountDelta,
        int128 quoteDelta
    ) external;

    function updateQuoteFromInsurance(bytes32 subaccount, int128 insurance)
        external
        returns (int128);

    function updateStates(uint128 dt) external;

    function updateMinDepositRate(uint32 productId, int128 minDepositRateX18)
        external;

    function manualAssert(
        int128[] calldata totalDeposits,
        int128[] calldata totalBorrows
    ) external view;

    function socializeSubaccount(bytes32 subaccount) external;

    function assertUtilization(uint32 productId) external view;
}
