// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;
import "./MathSD21x18.sol";
import "../interfaces/engine/IProductEngine.sol";
import "../common/Constants.sol";
import "../common/Errors.sol";
import "./MathHelper.sol";

/// @title RiskHelper
/// @dev Provides basic math functions
library RiskHelper {
    using MathSD21x18 for int128;

    struct RiskStore {
        // these weights are all
        // between 0 and 2
        // these integers are the real
        // weights times 1e9
        int32 longWeightInitial;
        int32 shortWeightInitial;
        int32 longWeightMaintenance;
        int32 shortWeightMaintenance;
        int128 priceX18;
    }

    struct Risk {
        int128 longWeightInitialX18;
        int128 shortWeightInitialX18;
        int128 longWeightMaintenanceX18;
        int128 shortWeightMaintenanceX18;
        int128 priceX18;
    }

    function _getSpreadHealthRebateAmount(
        Risk memory perpRisk,
        int128 basisAmount,
        int128 priceSumX18,
        IProductEngine.HealthType healthType
    ) internal pure returns (int128) {
        // 5x more leverage than the standard perp
        // by refunding 4/5 of the health penalty
        int128 rebateRateX18 = ((ONE - _getWeightX18(perpRisk, 1, healthType)) *
            4) / 5;
        return rebateRateX18.mul(priceSumX18).mul(basisAmount);
    }

    function _getLpRawValue(
        int128 baseAmount,
        int128 quoteAmount,
        int128 priceX18
    ) internal pure returns (int128) {
        // naive way: value an LP token by value of the raw components 2 * arithmetic mean of base value and quote value
        // price manipulation proof way: use the geometric mean
        return
            2 *
            int128(
                MathHelper.sqrt256(
                    int256(baseAmount.mul(priceX18)) * quoteAmount
                )
            );
    }

    function _getWeightX18(
        Risk memory risk,
        int128 amount,
        IProductEngine.HealthType healthType
    ) internal pure returns (int128) {
        // (1 + imf * sqrt(amount))
        if (healthType == IProductEngine.HealthType.PNL) {
            return ONE;
        }

        int128 weight;
        if (amount >= 0) {
            weight = healthType == IProductEngine.HealthType.INITIAL
                ? risk.longWeightInitialX18
                : risk.longWeightMaintenanceX18;
        } else {
            weight = healthType == IProductEngine.HealthType.INITIAL
                ? risk.shortWeightInitialX18
                : risk.shortWeightMaintenanceX18;
        }

        return weight;
    }

    function isIsolatedSubaccount(bytes32 subaccount)
        internal
        pure
        returns (bool)
    {
        return uint256(subaccount) & 0xFFFFFF == 6910831;
    }

    function getIsolatedProductId(bytes32 subaccount)
        internal
        pure
        returns (uint32)
    {
        if (!isIsolatedSubaccount(subaccount)) {
            return 0;
        }
        return uint32((uint256(subaccount) >> 32) & 0xFFFF);
    }

    function getIsolatedId(bytes32 subaccount) internal pure returns (uint8) {
        if (!isIsolatedSubaccount(subaccount)) {
            return 0;
        }
        return uint8((uint256(subaccount) >> 24) & 0xFF);
    }
}
