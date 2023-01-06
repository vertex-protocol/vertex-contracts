// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.13;

interface IEndpointGated {
    // this is all that remains lol, everything else is private or a modifier etc.
    function getOraclePriceX18(uint32 productId) external view returns (int256);

    function getEndpoint() external view returns (address endpoint);
}
