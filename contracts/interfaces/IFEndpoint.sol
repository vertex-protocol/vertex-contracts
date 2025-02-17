pragma solidity ^0.8.0;

import "../Endpoint.sol";

interface IFEndpoint {
    function setPriceX18(uint32 productId, int256 priceX18) external;
}
