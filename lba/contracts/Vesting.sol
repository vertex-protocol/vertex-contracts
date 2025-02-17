// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

import "./interfaces/IVesting.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";

contract Vesting is IVesting, OwnableUpgradeable {
    struct VestingSchedule {
        address beneficiary;
        uint64 startTime;
        uint64 endTime;
        uint256 amount;
    }

    address token;
    uint64 totalVestingSchedules;
    mapping(uint64 => VestingSchedule) vestingSchedules;
    mapping(uint64 => uint256) vestedAmounts;
    mapping(address => uint64[]) vestingScheduleIds;

    function initialize(address _token) external initializer {
        __Ownable_init();
        token = _token;
    }

    function _pruneExpiredVestingSchedules(address account) internal {
        uint64 currentTime = uint64(block.timestamp);
        for (uint32 i = 0; i < vestingScheduleIds[account].length; i++) {
            if (
                vestingSchedules[vestingScheduleIds[account][i]].endTime <=
                currentTime
            ) {
                vestingScheduleIds[account][i] = vestingScheduleIds[account][
                    vestingScheduleIds[account].length - 1
                ];
                vestingScheduleIds[account].pop();
            }
        }
    }

    function registerVesting(
        address account,
        uint256 amount,
        uint64 period
    ) external onlyOwner {
        SafeERC20.safeTransferFrom(
            IERC20(token),
            msg.sender,
            address(this),
            amount
        );
        uint64 currentTime = uint64(block.timestamp);
        uint64 vestingScheduleId = totalVestingSchedules++;
        vestingScheduleIds[account].push(vestingScheduleId);
        vestingSchedules[vestingScheduleId] = VestingSchedule({
            beneficiary: account,
            startTime: currentTime,
            endTime: currentTime + period,
            amount: amount
        });
    }

    function getVestable(
        uint64 vestingScheduleId
    ) external view returns (uint256 vestable) {
        uint64 currentTime = uint64(block.timestamp);
        VestingSchedule memory vestingSchedule = vestingSchedules[
            vestingScheduleId
        ];
        if (currentTime < vestingSchedule.startTime) {
            vestable = 0;
        } else if (currentTime >= vestingSchedule.endTime) {
            vestable = vestingSchedule.amount;
        } else {
            uint64 elpased = currentTime - vestingSchedule.startTime;
            uint64 total = vestingSchedule.endTime - vestingSchedule.startTime;
            vestable = (vestingSchedule.amount * elpased) / total;
        }
    }

    function getVested(
        uint64 vestingScheduleId
    ) external view returns (uint256) {
        return vestedAmounts[vestingScheduleId];
    }

    function getClaimable(
        address account
    ) external view returns (uint256 claimable) {
        for (uint32 i = 0; i < vestingScheduleIds[account].length; i++) {
            uint64 vestingScheduleId = vestingScheduleIds[account][i];
            claimable +=
                this.getVestable(vestingScheduleId) -
                this.getVested(vestingScheduleId);
        }
    }

    function claim() external {
        uint256 totalClaimable = 0;
        for (uint32 i = 0; i < vestingScheduleIds[msg.sender].length; i++) {
            uint64 vestingScheduleId = vestingScheduleIds[msg.sender][i];
            uint256 claimable = this.getVestable(vestingScheduleId) -
                this.getVested(vestingScheduleId);
            vestedAmounts[vestingScheduleId] += claimable;
            totalClaimable += claimable;
        }
        if (totalClaimable != 0) {
            SafeERC20.safeTransfer(IERC20(token), msg.sender, totalClaimable);
        }
        _pruneExpiredVestingSchedules(msg.sender);
    }

    function getVestingSchedule(
        uint64 vestingScheduleId
    ) external view returns (VestingSchedule memory) {
        return vestingSchedules[vestingScheduleId];
    }
}
