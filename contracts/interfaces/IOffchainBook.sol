// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

// for migration only
interface IOffchainBook {
    struct Market {
        uint32 productId;
        int128 sizeIncrement;
        int128 priceIncrementX18;
        int128 lpSpreadX18;
        int128 collectedFees;
        int128 sequencerFees;
    }

    function getMarket() external view returns (Market memory);

    function getMinSize() external view returns (int128);
}
