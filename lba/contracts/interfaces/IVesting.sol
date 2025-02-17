// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

interface IVesting {
    function registerVesting(
        address account,
        uint256 amount,
        uint64 period
    ) external;

    function getVested(
        uint64 vestingScheduleId
    ) external view returns (uint256);

    function getVestable(
        uint64 vestingScheduleId
    ) external view returns (uint256);

    function getClaimable(address account) external view returns (uint256);

    function claim() external;
}
