// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";

import "./interfaces/IFeeCalculator.sol";

// Playground for volume tracking: https://github.com/vertex-protocol/vertex-evm/commit/b52ea07a6b40ab8b0d8198886bc4ac6e60c61233
contract FeeCalculator is Initializable, IFeeCalculator {
    function initialize() external initializer {}

    function recordVolume(uint64 subaccount, uint256 quoteVolume) external {}

    function getFeeFractionX18(
        uint64 /* subaccountId */,
        uint32 /* productId */,
        bool taker
    ) external pure returns (int256) {
        if (taker) {
            return 2_000_000_000_000_000; // 0.2%
        } else {
            return 0;
        }
        // feecalc needs more state to look up fractions for various products, if that was the plan
    }

    function getInterestFeeFractionX18(
        uint32 /* productId */
    ) external pure returns (int256) {
        return 200_000_000_000_000_000; // 20%
    }
}
