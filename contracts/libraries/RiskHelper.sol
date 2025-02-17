// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;
import "./MathSD21x18.sol";
import "../interfaces/engine/IProductEngine.sol";
import "../common/Constants.sol";
import "./MathHelper.sol";

/// @title RiskHelper
/// @dev Provides basic math functions
library RiskHelper {
    using MathSD21x18 for int128;

    struct Risk {
        int128 longWeightInitialX18;
        int128 shortWeightInitialX18;
        int128 longWeightMaintenanceX18;
        int128 shortWeightMaintenanceX18;
        int128 largePositionPenaltyX18;
    }

    function _getSpreadPenaltyX18(
        Risk memory spotRisk,
        Risk memory perpRisk,
        int128 amount,
        IProductEngine.HealthType healthType
    ) internal pure returns (int128) {
        return
            (ONE - _getWeightX18(spotRisk, amount, healthType)).mul(
                ONE - _getWeightX18(perpRisk, amount, healthType)
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

        // TODO: skip if possible; sqrt is expensive
        int128 tempX18 = (ONE +
            risk.largePositionPenaltyX18.mul(amount.abs().sqrt()));
        if (amount > 0) {
            // 1.1 / (1 + imf * sqrt(amount))
            int128 imfWeightLongX18 = int128(11e17).div(tempX18);
            return
                MathHelper.min(
                    imfWeightLongX18,
                    healthType == IProductEngine.HealthType.INITIAL
                        ? risk.longWeightInitialX18
                        : risk.longWeightMaintenanceX18
                );
        } else {
            // 0.9 * (1 + imf * sqrt(amount))
            int128 imfWeightShortX18 = int128(9e17).mul(tempX18);
            return
                MathHelper.max(
                    imfWeightShortX18,
                    healthType == IProductEngine.HealthType.INITIAL
                        ? risk.shortWeightInitialX18
                        : risk.shortWeightMaintenanceX18
                );
        }
    }
}
