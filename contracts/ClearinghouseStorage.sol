// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

import "./interfaces/engine/IProductEngine.sol";

abstract contract ClearinghouseStorage {
    using MathSD21x18 for int128;

    struct LegacyHealthGroup {
        uint32 spotId;
        uint32 perpId;
    }

    struct LegacyRiskStore {
        int32 longWeightInitial;
        int32 shortWeightInitial;
        int32 longWeightMaintenance;
        int32 shortWeightMaintenance;
        int32 largePositionPenalty;
    }

    uint32 internal maxHealthGroup; // deprecated
    mapping(uint32 => LegacyHealthGroup) internal healthGroups; // deprecated
    mapping(uint32 => LegacyRiskStore) internal risks; // deprecated

    // Each clearinghouse has a quote ERC20
    address internal quote;

    address internal clearinghouse;
    address internal clearinghouseLiq;

    // fee calculator
    address internal fees;

    // Number of products registered across all engines
    uint32 internal numProducts; // deprecated

    // product ID -> engine address
    mapping(uint32 => IProductEngine) internal productToEngine;
    // Type to engine address
    mapping(IProductEngine.EngineType => IProductEngine) internal engineByType;
    // Supported engine types
    IProductEngine.EngineType[] internal supportedEngines;

    // insurance stuff, consider making it its own subaccount later
    int128 internal insurance;

    int128 internal lastLiquidationFees;

    uint256 internal spreads;

    address internal withdrawPool;

    function getLiqPriceX18(uint32 productId, int128 amount)
        internal
        view
        returns (int128, int128)
    {
        RiskHelper.Risk memory risk = IProductEngine(productToEngine[productId])
            .getRisk(productId);
        return (
            risk.priceX18.mul(
                ONE +
                    (RiskHelper._getWeightX18(
                        risk,
                        amount,
                        IProductEngine.HealthType.MAINTENANCE
                    ) - ONE) /
                    5
            ),
            risk.priceX18
        );
    }

    function getSpreadLiqPriceX18(
        uint32 spotId,
        uint32 perpId,
        int128 amount
    )
        internal
        view
        returns (
            int128,
            int128,
            int128
        )
    {
        RiskHelper.Risk memory spotRisk = IProductEngine(
            productToEngine[spotId]
        ).getRisk(spotId);
        RiskHelper.Risk memory perpRisk = IProductEngine(
            productToEngine[perpId]
        ).getRisk(perpId);

        int128 spreadPenaltyX18;
        if (amount >= 0) {
            spreadPenaltyX18 =
                (ONE -
                    RiskHelper._getWeightX18(
                        perpRisk,
                        amount,
                        IProductEngine.HealthType.MAINTENANCE
                    )) /
                25;
        } else {
            spreadPenaltyX18 =
                (RiskHelper._getWeightX18(
                    spotRisk,
                    amount,
                    IProductEngine.HealthType.MAINTENANCE
                ) - ONE) /
                25;
        }

        if (amount > 0) {
            return (
                spotRisk.priceX18.mul(ONE - spreadPenaltyX18),
                spotRisk.priceX18,
                perpRisk.priceX18
            );
        } else {
            return (
                spotRisk.priceX18.mul(ONE + spreadPenaltyX18),
                spotRisk.priceX18,
                perpRisk.priceX18
            );
        }
    }
}
