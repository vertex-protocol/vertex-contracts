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
        uint64 subaccountId,
        Balance calldata balance
    ) public {
        balances[productId][subaccountId] = balance;
    }

    function setLpBalance(
        uint32 productId,
        uint64 subaccountId,
        LpBalance calldata lpBalance
    ) public {
        lpBalances[productId][subaccountId] = lpBalance;
    }

    function setMarkPrice(uint32 productId, int256 markPriceX18) public {
        markPrices[productId] = markPriceX18;
    }
}
