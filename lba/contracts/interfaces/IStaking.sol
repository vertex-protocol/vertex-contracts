// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

interface IStaking {
    struct Segment {
        uint64 startTime;
        int256 vrtxSize;
        address owner;
        uint32 version;
    }

    struct QueueIndex {
        uint64 count;
        uint64 upTo;
    }

    struct State {
        uint256 vrtxStaked;
        int256 sumSize;
        int256 sumSizeXTime;
    }

    struct ReleaseSchedule {
        uint64 releaseTime;
        uint256 amount;
    }

    struct Checkpoint {
        uint64 time;
        uint256 vrtxStaked;
        int256 sumSize;
        int256 sumSizeXTime;
        uint256 rewards;
    }

    struct LastActionTimes {
        uint64 lastStakeTime;
        uint64 lastWithdrawTime;
    }

    struct WithdrawnVrtxStates {
        uint256 vrtxClaimable;
        uint256 vrtxPendingUnlock;
    }

    function stake(uint256 amount) external;

    function withdraw(uint256 amount) external;

    function claimVrtx() external;

    function claimUsdc() external;

    function getWithdrawnVrtxStates(
        address account
    ) external view returns (WithdrawnVrtxStates memory);

    function getRewardsBreakdown(
        address account
    ) external view returns (uint256[] memory);

    function getUsdcClaimable(address account) external view returns (uint256);

    function getVrtxStaked(address account) external view returns (uint256);

    function getTotalVrtxStaked() external view returns (uint256);

    function getScore(address account) external view returns (uint256);

    function getTotalScore() external view returns (uint256);

    function getLastActionTimes(
        address account
    ) external view returns (LastActionTimes memory);
}
