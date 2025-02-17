// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

interface IStakingV2 {
    event ModifyStake(
        address indexed account,
        int128 vrtxDelta,
        int128 liquidDelta
    );

    event ConnectTradingWallet(address indexed account, address indexed wallet);

    struct ReleaseSchedule {
        uint64 releaseTime;
        uint128 amount;
    }

    struct LastActionTimes {
        uint64 lastStakeTime;
        uint64 lastWithdrawTime;
    }

    struct GlobalYieldsBreakdown {
        uint64 distributionTime;
        uint128 baseYieldAmount;
        uint128 feesYieldAmount;
        uint128 totalVrtxBalance;
        uint128 usdcAmount;
    }

    struct Config {
        uint64 withdrawLockingTime;
        uint64 minimumStakingPeriod;
        uint128 toDistributeRatio;
        uint128 toTreasuryRatio;
    }

    struct State {
        uint128 cumulativeStakedAmount;
        uint128 cumulativeWithdrawnAmount;
        uint128 cumulativeBurnedAmount;
        uint128 currentStakedAmount;
    }

    function migrate(address staker, uint128 amount, uint128 bonus) external;

    function stake(uint128 amount) external;

    function stakeAs(address staker, uint128 amount) external;

    function withdraw() external;

    function withdrawSlow() external;

    function claimWithdraw() external;

    function connectTradingWallet(address wallet) external;

    function getTradingWallet(address account) external view returns (address);

    function getVrtxBalance(address account) external view returns (uint128);

    function getTotalVrtxBalance() external view returns (uint128);

    function getLastActionTimes(
        address account
    ) external view returns (LastActionTimes memory);

    function getConfig(address account) external view returns (Config memory);

    function getDefaultConfig() external view returns (Config memory);

    function getState(address account) external view returns (State memory);

    function getWithdrawableTime(
        address account
    ) external view returns (uint64);

    function getReleaseSchedule(
        address account
    ) external view returns (ReleaseSchedule memory);

    function getGlobalYieldsBreakdown()
        external
        view
        returns (GlobalYieldsBreakdown[] memory);

    function getMigrationBonusPool() external view returns (uint128);
}
