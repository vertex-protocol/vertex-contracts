// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

interface ILBA {
    enum Stage {
        NotStarted,
        DepositingTokens,
        WithdrawingUsdc,
        LBAFinished,
        DepositedToVertex,
        LpMinted,
        LpVesting,
        LpVested
    }

    struct Config {
        uint64 depositStartTime;
        uint64 depositEndTime;
        uint64 withdrawEndTime;
        uint64 lpVestStartTime;
        uint64 lpVestEndTime;
    }

    struct State {
        uint256 totalVrtxDeposited;
        uint256 totalUsdcDeposited;
        uint256 totalLpMinted;
        uint256 totalLpWithdrawn;
        uint256 cumulativeRewardsPerShareX18;
    }

    function getStage() external view returns (Stage stage);

    function depositVrtx(address account, uint256 amount) external;

    function depositUsdc(uint256 amount) external;

    function getDepositedVrtx(address account) external view returns (uint256);

    function getDepositedUsdc(address account) external view returns (uint256);

    function getMaxWithdrawableUsdc(
        address account
    ) external view returns (uint256);

    function withdrawUsdc(uint256 amount) external;

    function getVrtxInitialPriceX18() external view returns (uint256);

    function getLpBalance(address account) external view returns (uint256);

    function getLockedLpBalance(
        address account
    ) external view returns (uint256 lockedLpBalance);

    function getWithdrawableLpBalance(
        address account
    ) external view returns (uint256);

    function withdrawLiquidity(uint256 lpAmount) external;

    function getConfig() external view returns (Config memory);

    function getState() external view returns (State memory);

    function getClaimedRewards(address account) external view returns (uint256);

    function getClaimableRewards(
        address account
    ) external view returns (uint256);

    function claimRewards() external;

    function distributeRewards(uint256 amount) external;
}
