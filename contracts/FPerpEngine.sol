// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

import "./PerpEngine.sol";

contract FPerpEngine is PerpEngine {
    function checkCanApplyDeltas() internal view override {}

    function setState(uint32 productId, State calldata state) public {
        states[productId] = state;
    }

    function setLpState(uint32 productId, LpState calldata lpState) public {
        lpStates[productId] = lpState;
    }

    function setBalance(
        uint32 productId,
        bytes32 subaccount,
        Balance calldata balance
    ) public {
        balances[productId][subaccount] = balance;
    }

    function setLpBalance(
        uint32 productId,
        bytes32 subaccount,
        LpBalance calldata lpBalance
    ) public {
        lpBalances[productId][subaccount] = lpBalance;
    }

    function perpPositionClosed(uint32 productId, bytes32 subaccount)
        external
        view
        returns (bool)
    {
        return
            lpBalances[productId][subaccount].amount == 0 &&
            balances[productId][subaccount].amount == 0 &&
            balances[productId][subaccount].vQuoteBalance != 0;
    }
}
