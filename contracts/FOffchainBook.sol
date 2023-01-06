// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

import "./OffchainBook.sol";
import "prb-math/contracts/PRBMathSD59x18.sol";

contract FOffchainBook is OffchainBook {
    using PRBMathSD59x18 for int256;

    function setMarket(Market memory _market) public {
        market = _market;
    }

    function dropOrderChecked(IEndpoint.Order memory order) public {
        bytes32 digest = getDigest(order, false);
        if (
            filledAmounts[digest] == order.amount ||
            order.expiration < getOracleTime()
        ) {
            delete filledAmounts[digest];
        }
    }

    function dropOrder(IEndpoint.Order memory order) public {
        bytes32 digest = getDigest(order, false);
        delete filledAmounts[digest];
    }

    function getOrderFilledAmounts(
        IEndpoint.Order memory order1,
        IEndpoint.Order memory order2
    ) public view returns (int256, int256) {
        bytes32 digest1 = getDigest(order1, false);
        bytes32 digest2 = getDigest(order2, false);
        return (filledAmounts[digest1], filledAmounts[digest2]);
    }

    function getFeeRatesX18(address sender, string memory subaccountName)
        public
        view
        returns (int256 takerFeeRateX18, int256 makerFeeRateX18)
    {
        uint64 subaccountId = clearinghouse.getSubaccountId(
            sender,
            subaccountName
        );
        takerFeeRateX18 = fees.getFeeFractionX18(
            subaccountId,
            market.productId,
            true
        );
        makerFeeRateX18 = fees.getFeeFractionX18(
            subaccountId,
            market.productId,
            false
        );
    }

    function _checkSignature(
        address, /* subaccountOwner */
        bytes32, /* digest */
        bytes memory /* signature */
    ) internal pure override returns (bool) {
        return true;
    }
}
