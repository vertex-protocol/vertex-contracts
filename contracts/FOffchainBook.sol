// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

import "./OffchainBook.sol";
import "./libraries/MathSD21x18.sol";

contract FOffchainBook is OffchainBook {
    using MathSD21x18 for int128;

    function setMarket(Market memory _market) public {
        market = _market;
    }

    function dropOrderChecked(IEndpoint.Order memory order) public {
        bytes32 digest = getDigest(order);
        if (
            filledAmounts[digest] == order.amount ||
            order.expiration < getOracleTime()
        ) {
            delete filledAmounts[digest];
        }
    }

    function dropDigest(bytes32 digest) public {
        delete filledAmounts[digest];
    }

    function dropOrder(IEndpoint.Order memory order) public {
        bytes32 digest = getDigest(order);
        delete filledAmounts[digest];
    }

    function getOrderFilledAmounts(
        IEndpoint.Order memory order1,
        IEndpoint.Order memory order2
    ) public view returns (int128, int128) {
        bytes32 digest1 = getDigest(order1);
        bytes32 digest2 = getDigest(order2);
        return (filledAmounts[digest1], filledAmounts[digest2]);
    }

    function getFeeRatesX18(bytes32 subaccount)
        public
        view
        returns (int128 takerFeeRateX18, int128 makerFeeRateX18)
    {
        takerFeeRateX18 = fees.getFeeFractionX18(
            subaccount,
            market.productId,
            true
        );
        makerFeeRateX18 = fees.getFeeFractionX18(
            subaccount,
            market.productId,
            false
        );
    }

    function validateOrder(IEndpoint.SignedOrder memory signedOrder)
        external
        view
    {
        Market memory _market = market;
        IEndpoint.Order memory order = signedOrder.order;

        require(
            order.priceX18 % _market.priceIncrementX18 == 0,
            "invalid price: not divisible by increment"
        );
        require(
            order.amount % _market.sizeIncrement == 0,
            "invalid amount: not divisible by increment"
        );

        // only require minSize if the order may end up on the book
        if (order.expiration >> 62 != 1) {
            require(
                MathHelper.abs(order.amount) >= minSize,
                "invalid amount: too small"
            );
        }

        require(order.amount != 0, "invalid amount: zero");
        require(
            order.expiration > getOracleTime(),
            "invalid expiration: already expired"
        );
    }

    function isHealthy(bytes32 subaccount)
        internal
        view
        override
        returns (bool)
    {
        return
            clearinghouse.getHealth(
                subaccount,
                IProductEngine.HealthType.INITIAL
            ) >= 0;
    }

    function _checkSignature(
        bytes32, /* subaccount */
        bytes32, /* digest */
        bytes memory /* signature */
    ) internal pure override returns (bool) {
        return true;
    }
}
