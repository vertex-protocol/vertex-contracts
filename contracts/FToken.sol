// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

contract FToken {
    uint8 _decimals;

    function initialize(uint8 decimals_) external {
        _decimals = decimals_;
    }

    function decimals() external view virtual returns (uint8) {
        return _decimals;
    }
}
