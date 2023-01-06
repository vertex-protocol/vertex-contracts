// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "./interfaces/IEndpoint.sol";
import "./interfaces/IEndpointGated.sol";
import "prb-math/contracts/PRBMathSD59x18.sol";
import "./common/Constants.sol";
import "hardhat/console.sol";

abstract contract EndpointGated is OwnableUpgradeable, IEndpointGated {
    address private endpoint;

    function setEndpoint(address _endpoint) public onlyOwner {
        endpoint = _endpoint;
    }

    function getEndpoint() public view returns (address) {
        return endpoint;
    }

    function getOraclePriceX18(uint32 productId) public view returns (int256) {
        if (productId == QUOTE_PRODUCT_ID) {
            return PRBMathSD59x18.fromInt(1);
        }
        return IEndpoint(endpoint).getPriceX18(productId);
    }

    function getOracleTime() internal view returns (uint256) {
        return IEndpoint(endpoint).getTime();
    }

    modifier onlyEndpoint() {
        require(
            msg.sender == endpoint,
            "SequencerGated: caller is not the endpoint"
        );
        _;
    }
}
