// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;
import "prb-math/contracts/PRBMathSD59x18.sol";
import "../interfaces/engine/IProductEngine.sol";
import "../common/Constants.sol";
import "./MathHelper.sol";

/// @title RiskHelper
/// @dev Provides basic math functions
library RiskHelper {
    using PRBMathSD59x18 for int256;

    struct Risk {
        int256 longWeightInitialX18;
        int256 shortWeightInitialX18;
        int256 longWeightMaintenanceX18;
        int256 shortWeightMaintenanceX18;
        int256 largePositionPenaltyX18;
    }

    function _getSpreadPenaltyX18(
        Risk memory spotRisk,
        Risk memory perpRisk,
        int256 amountX18,
        IProductEngine.HealthType healthType
    ) internal pure returns (int256) {
        return
            (ONE - _getWeightX18(spotRisk, amountX18, healthType)).mul(
                ONE - _getWeightX18(perpRisk, amountX18, healthType)
            );
    }

    function _getWeightX18(
        Risk memory risk,
        int256 amountX18,
        IProductEngine.HealthType healthType
    ) internal pure returns (int256) {
        // (1 + imf * sqrt(amount))
        if (healthType == IProductEngine.HealthType.PNL) {
            return ONE;
        }

        // TODO: skip if possible; sqrt is expensive
        int256 tempX18 = (ONE +
            risk.largePositionPenaltyX18.mul(amountX18.abs().sqrt()));
        if (amountX18 > 0) {
            // 1.1 / (1 + imf * sqrt(amount))
            int256 imfWeightLongX18 = int256(11e17).div(tempX18);
            return
                MathHelper.min(
                    imfWeightLongX18,
                    healthType == IProductEngine.HealthType.INITIAL
                        ? risk.longWeightInitialX18
                        : risk.longWeightMaintenanceX18
                );
        } else {
            // 0.9 * (1 + imf * sqrt(amount))
            int256 imfWeightShortX18 = int256(9e17).mul(tempX18);
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
