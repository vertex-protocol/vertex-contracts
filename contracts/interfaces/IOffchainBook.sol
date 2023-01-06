// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

import "./clearinghouse/IClearinghouse.sol";
import "./IFeeCalculator.sol";

interface IOffchainBook {
    event FillOrder(
        // original order information
        bytes32 indexed digest,
        uint64 indexed subaccount,
        int256 priceX18,
        int256 amount,
        uint64 expiration,
        uint64 nonce,
        // whether this order is taking or making
        bool isTaker,
        // amount paid in fees (in quote)
        int256 feeAmountX18,
        // change in this subaccount's base balance from this fill
        int256 baseDeltaX18,
        // change in this subaccount's quote balance from this fill
        int256 quoteDeltaX18
    );

    struct Market {
        uint32 productId;
        int256 sizeIncrement;
        int256 priceIncrementX18;
        int256 lpSpreadX18;
        int256 collectedFeesX18;
    }

    function initialize(
        IClearinghouse _clearinghouse,
        IProductEngine _engine,
        address _endpoint,
        address _admin,
        IFeeCalculator _fees,
        uint32 _productId,
        int256 _sizeIncrement,
        int256 _priceIncrementX18,
        int256 _lpSpreadX18
    ) external;

    function getDigest(
        IEndpoint.Order memory order,
        bool isCancellation
    ) external view returns (bytes32);

    function getMarket() external view returns (Market memory);

    function swapAMM(IEndpoint.SwapAMM calldata tx) external;

    function matchOrderAMM(IEndpoint.MatchOrderAMM calldata tx) external;

    function matchOrders(IEndpoint.MatchOrders calldata tx) external;

    function dumpFees() external;
}
