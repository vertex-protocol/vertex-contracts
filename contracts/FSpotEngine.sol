// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

import "./SpotEngine.sol";

contract FSpotEngine is SpotEngine {
    function checkCanApplyDeltas() internal view override {}

    function setState(uint32 productId, State calldata state) public {
        states[productId] = state;
    }

    function setConfig(uint32 productId, Config calldata config) public {
        configs[productId] = config;
    }

    function setLpState(uint32 productId, LpState calldata lpState) public {
        lpStates[productId] = lpState;
    }

    function setLpBalance(
        uint32 productId,
        bytes32 subaccount,
        LpBalance calldata lpBalance
    ) public {
        balances[productId][subaccount].lpBalance = lpBalance;
    }
}
