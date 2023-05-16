// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "./Version.sol";
import "./interfaces/IFeeCalculator.sol";

// Playground for volume tracking: https://github.com/vertex-protocol/vertex-evm/commit/b52ea07a6b40ab8b0d8198886bc4ac6e60c61233
contract FeeCalculator is Initializable, IFeeCalculator, Version {
    function initialize() external initializer {}

    function recordVolume(bytes32 subaccount, uint128 quoteVolume) external {}

    function getFeeFractionX18(
        bytes32, /* subaccount */
        uint32 productId,
        bool taker
    ) external pure returns (int128) {
        require(productId != 0 && productId <= 6, "invalid productId");
        if (taker) {
            if (productId % 2 == 1) {
                return 300_000_000_000_000;
            } else {
                return 200_000_000_000_000;
            }
        } else {
            return 0;
        }
        // feecalc needs more state to look up fractions for various products, if that was the plan
    }

    function getInterestFeeFractionX18(
        uint32 /* productId */
    ) external pure returns (int128) {
        return 200_000_000_000_000_000; // 20%
    }

    function getLiquidationFeeFractionX18(
        bytes32, /* subaccount */
        uint32 /* productId */
    ) external pure returns (int128) {
        return 250_000_000_000_000_000; // 25%
    }
}
