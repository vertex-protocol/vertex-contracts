// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "./Version.sol";
import "./interfaces/IFeeCalculator.sol";
import "./common/Errors.sol";

// Playground for volume tracking: https://github.com/vertex-protocol/vertex-evm/commit/b52ea07a6b40ab8b0d8198886bc4ac6e60c61233
contract FeeCalculator is Initializable, IFeeCalculator, Version {
    address private clearinghouse;
    mapping(address => mapping(uint32 => FeeRates)) feeRates;

    function initialize() external initializer {}

    function migrate(address _clearinghouse) external {
        require(clearinghouse == address(0), "already migrated");
        clearinghouse = _clearinghouse;
    }

    function getClearinghouse() external view returns (address) {
        return clearinghouse;
    }

    function recordVolume(bytes32 subaccount, uint128 quoteVolume) external {}

    function getFeeFractionX18(
        bytes32 subaccount,
        uint32 productId,
        bool taker
    ) external view returns (int128) {
        FeeRates memory userFeeRates = feeRates[
            address(uint160(bytes20(subaccount)))
        ][productId];
        if (userFeeRates.isNonDefault == 0) {
            // use the default fee rates.
            userFeeRates = FeeRates(0, 200_000_000_000_000, 1);
        }
        return taker ? userFeeRates.takerRateX18 : userFeeRates.makerRateX18;
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
        return 500_000_000_000_000_000; // 50%
    }

    function updateFeeRates(
        address user,
        uint32 productId,
        int64 makerRateX18,
        int64 takerRateX18
    ) external {
        require(msg.sender == clearinghouse, ERR_UNAUTHORIZED);
        feeRates[user][productId] = FeeRates(makerRateX18, takerRateX18, 1);
    }
}
