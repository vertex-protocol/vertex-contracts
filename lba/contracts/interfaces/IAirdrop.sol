// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

interface IAirdrop {
    function claimToLBA(
        uint256 amount,
        uint256 totalAmount,
        bytes32[] calldata proof
    ) external;

    function claim(
        uint32 epoch,
        uint256 amount,
        uint256 totalAmount,
        bytes32[] calldata proof
    ) external;

    function getClaimed(
        address account
    ) external view returns (uint256[] memory);

    function getClaimingDeadlines() external view returns (uint64[] memory);
}
