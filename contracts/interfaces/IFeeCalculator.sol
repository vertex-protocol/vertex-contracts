// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

interface IFeeCalculator {
    function recordVolume(uint64 subaccount, uint128 quoteVolume) external;

    function getFeeFractionX18(
        uint64 subaccountId,
        uint32 productId,
        bool taker
    ) external view returns (int128);

    function getInterestFeeFractionX18(uint32 productId)
        external
        view
        returns (int128);

    function getLiquidationFeeFractionX18(uint64 subaccountId, uint32 productId)
        external
        view
        returns (int128);
}
