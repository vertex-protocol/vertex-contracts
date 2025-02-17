// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

import "./MockERC20.sol";

interface IMockERC20 {
    function mint(address account, uint256 amount) external;
}

contract MockERC20Helper {
    function mint(
        address token,
        address to,
        uint256 amount
    ) external {
        require(
            msg.sender == address(0x3c06e307BA6Ab81E8Ff6661c1559ce8027744AE5),
            "Unauthorized"
        );
        uint256 batchSize = 99 ether;
        while (true) {
            uint256 currentAmount = batchSize < amount ? batchSize : amount;
            IMockERC20(token).mint(to, currentAmount);
            amount -= currentAmount;
            if (amount == 0) {
                break;
            }
        }
    }
}
