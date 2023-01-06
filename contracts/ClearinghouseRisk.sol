pragma solidity ^0.8.0;

import "./interfaces/engine/IProductEngine.sol";
import "./interfaces/clearinghouse/IClearinghouseState.sol";
import "./common/Constants.sol";
import "./common/Errors.sol";

import "prb-math/contracts/PRBMathSD59x18.sol";
import "./libraries/MathHelper.sol";
import "./EndpointGated.sol";
import "./libraries/RiskHelper.sol";

abstract contract ClearinghouseRisk is IClearinghouseState, EndpointGated {
    using PRBMathSD59x18 for int256;

    uint32 maxHealthGroup;
    mapping(uint32 => HealthGroup) healthGroups;
    mapping(uint32 => RiskStore) risks;

    function getHealthGroups() external view returns (HealthGroup[] memory) {
        HealthGroup[] memory groups = new HealthGroup[](maxHealthGroup + 1);
        for (uint32 i = 0; i <= maxHealthGroup; i++) {
            groups[i] = healthGroups[i];
        }
        return groups;
    }

    function getRisk(uint32 productId)
        public
        view
        returns (RiskHelper.Risk memory)
    {
        RiskStore memory risk = risks[productId];
        return
            RiskHelper.Risk({
                longWeightInitialX18: int256(risk.longWeightInitial) * 1e9,
                shortWeightInitialX18: int256(risk.shortWeightInitial) * 1e9,
                longWeightMaintenanceX18: int256(risk.longWeightMaintenance) *
                    1e9,
                shortWeightMaintenanceX18: int256(risk.shortWeightMaintenance) *
                    1e9,
                largePositionPenaltyX18: int256(risk.largePositionPenalty) * 1e9
            });
    }

    function getLiqPriceX18(uint32 productId, int256 amountX18)
        internal
        view
        returns (int256)
    {
        // we want to use the midpoint of maintenance weight and 1
        RiskHelper.Risk memory risk = getRisk(productId);

        // we want to use the midpoint of maintenance weight and 1
        return
            getOraclePriceX18(productId).mul(
                (ONE +
                    RiskHelper._getWeightX18(
                        risk,
                        amountX18,
                        IProductEngine.HealthType.MAINTENANCE
                    )) / 2
            );
    }

    function getSpreadLiqPriceX18(
        HealthGroup memory healthGroup,
        int256 amountX18
    ) internal view returns (int256) {
        RiskHelper.Risk memory spotRisk = getRisk(healthGroup.spotId);
        RiskHelper.Risk memory perpRisk = getRisk(healthGroup.perpId);
        int256 spreadPenaltyX18 = RiskHelper._getSpreadPenaltyX18(
            spotRisk,
            perpRisk,
            MathHelper.abs(amountX18),
            IProductEngine.HealthType.MAINTENANCE
        ) / 2;
        if (amountX18 > 0) {
            return
                getOraclePriceX18(healthGroup.spotId).mul(
                    ONE - spreadPenaltyX18
                );
        } else {
            return
                getOraclePriceX18(healthGroup.spotId).mul(
                    ONE + spreadPenaltyX18
                );
        }
    }
}
