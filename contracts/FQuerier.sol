// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

import "./interfaces/clearinghouse/IClearinghouse.sol";
import "prb-math/contracts/PRBMathSD59x18.sol";
import "./interfaces/engine/ISpotEngine.sol";
import "./interfaces/engine/IPerpEngine.sol";
import "./interfaces/IOffchainBook.sol";
import "./common/Constants.sol";
import "./interfaces/engine/IProductEngine.sol";
import "@openzeppelin/contracts/utils/Base64.sol";

// NOTE: not related to VertexQuerier
// custom querier contract just for queries with FNode
// VertexQuerier has some issues with abi generation
contract FQuerier {
    using PRBMathSD59x18 for int256;
    IClearinghouse private clearinghouse;
    IEndpoint private endpoint;
    ISpotEngine private spotEngine;
    IPerpEngine private perpEngine;

    function initialize(address _clearinghouse) external {
        clearinghouse = IClearinghouse(_clearinghouse);
        endpoint = IEndpoint(clearinghouse.getEndpoint());

        spotEngine = ISpotEngine(
            clearinghouse.getEngineByType(IProductEngine.EngineType.SPOT)
        );

        perpEngine = IPerpEngine(
            clearinghouse.getEngineByType(IProductEngine.EngineType.PERP)
        );
    }

    struct SpotBalance {
        uint32 productId;
        ISpotEngine.LpBalance lpBalance;
        ISpotEngine.Balance balance;
    }

    struct PerpBalance {
        uint32 productId;
        IPerpEngine.LpBalance lpBalance;
        IPerpEngine.Balance balance;
    }

    // for config just go to the chain
    struct SpotProduct {
        uint32 productId;
        int256 oraclePriceX18;
        RiskHelper.Risk risk;
        ISpotEngine.Config config;
        ISpotEngine.State state;
        ISpotEngine.LpState lpState;
        BookInfo bookInfo;
    }

    struct PerpProduct {
        uint32 productId;
        int256 oraclePriceX18;
        int256 markPriceX18;
        RiskHelper.Risk risk;
        IPerpEngine.State state;
        IPerpEngine.LpState lpState;
        BookInfo bookInfo;
    }

    struct BookInfo {
        int256 sizeIncrement;
        int256 priceIncrementX18;
        int256 collectedFeesX18;
        int256 lpSpreadX18;
    }

    struct HealthInfo {
        int256 assetsX18;
        int256 liabilitiesX18;
        int256 healthX18;
    }

    struct SubaccountInfo {
        uint64 subaccountId;
        bool exists;
        HealthInfo[] healths;
        uint32 spotCount;
        uint32 perpCount;
        SpotBalance[] spotBalances;
        PerpBalance[] perpBalances;
        SpotProduct[] spotProducts;
        PerpProduct[] perpProducts;
    }

    struct ProductInfo {
        SpotProduct[] spotProducts;
        PerpProduct[] perpProducts;
    }

    function getClearinghouse() external view returns (address) {
        return address(clearinghouse);
    }

    function _getAllProductIds()
        internal
        view
        returns (uint32[] memory spotIds, uint32[] memory perpIds)
    {
        spotIds = ISpotEngine(
            clearinghouse.getEngineByType(IProductEngine.EngineType.SPOT)
        ).getProductIds();

        perpIds = ISpotEngine(
            clearinghouse.getEngineByType(IProductEngine.EngineType.PERP)
        ).getProductIds();
    }

    function getAllProducts() public view returns (ProductInfo memory) {
        (
            uint32[] memory spotIds,
            uint32[] memory perpIds
        ) = _getAllProductIds();
        return
            ProductInfo({
                spotProducts: getSpotProducts(spotIds),
                perpProducts: getPerpProducts(perpIds)
            });
    }

    function getSpotProducts(
        uint32[] memory productIds
    ) public view returns (SpotProduct[] memory spotProducts) {
        ISpotEngine engine = ISpotEngine(
            clearinghouse.getEngineByType(IProductEngine.EngineType.SPOT)
        );

        spotProducts = new SpotProduct[](productIds.length);

        for (uint32 i = 0; i < productIds.length; i++) {
            uint32 productId = productIds[i];
            spotProducts[i] = _getSpotProduct(
                productId,
                engine,
                clearinghouse,
                endpoint
            );
        }
    }

    function getPerpProducts(
        uint32[] memory productIds
    ) public view returns (PerpProduct[] memory perpProducts) {
        IPerpEngine engine = IPerpEngine(
            clearinghouse.getEngineByType(IProductEngine.EngineType.PERP)
        );

        perpProducts = new PerpProduct[](productIds.length);

        for (uint32 i = 0; i < productIds.length; i++) {
            uint32 productId = productIds[i];
            perpProducts[i] = _getPerpProduct(
                productId,
                engine,
                clearinghouse,
                endpoint
            );
        }
    }

    function _getSpotProduct(
        uint32 productId,
        ISpotEngine engine,
        IClearinghouse clearinghouse,
        IEndpoint endpoint
    ) internal view returns (SpotProduct memory spotProduct) {
        (
            ISpotEngine.LpState memory lpState,
            ,
            ISpotEngine.State memory state,

        ) = engine.getStatesAndBalances(productId, 0);
        int256 oraclePriceX18 = productId == QUOTE_PRODUCT_ID
            ? ONE
            : endpoint.getPriceX18(productId);
        return
            SpotProduct({
                productId: productId,
                oraclePriceX18: oraclePriceX18,
                risk: clearinghouse.getRisk(productId),
                config: engine.getConfig(productId),
                state: state,
                lpState: lpState,
                bookInfo: productId != 0
                    ? getBookInfo(productId, engine)
                    : BookInfo(0, 0, 0, 0)
            });
    }

    function _getPerpProduct(
        uint32 productId,
        IPerpEngine engine,
        IClearinghouse clearinghouse,
        IEndpoint endpoint
    ) internal view returns (PerpProduct memory spotProduct) {
        (
            IPerpEngine.LpState memory lpState,
            ,
            IPerpEngine.State memory state,

        ) = engine.getStatesAndBalances(productId, 0);

        return
            PerpProduct({
                productId: productId,
                oraclePriceX18: endpoint.getPriceX18(productId),
                markPriceX18: engine.getMarkPrice(productId),
                risk: clearinghouse.getRisk(productId),
                state: state,
                lpState: lpState,
                bookInfo: productId != 0
                    ? getBookInfo(productId, engine)
                    : BookInfo(0, 0, 0, 0)
            });
    }

    struct Txn {
        address to;
        bytes data;
    }

    function _getRevertMsg(
        bytes memory _returnData
    ) internal pure returns (string memory) {
        // If the _res length is less than 68, then the transaction failed silently (without a revert message)
        if (_returnData.length < 68) return "Transaction reverted silently";

        assembly {
            // Slice the sighash.
            _returnData := add(_returnData, 0x04)
        }
        return abi.decode(_returnData, (string)); // All that remains is the revert string
    }

    function getSubaccountInfoWithStateChange(
        uint64 subaccountId,
        Txn[] memory txns
    ) public {
        // black magic
        for (uint256 i = 0; i < txns.length; i++) {
            (bool success, bytes memory output) = txns[i].to.call(txns[i].data);
            //            require(success, "state change failed");
            //            require(txns[i].to.call(txns[i].data));
            require(
                success,
                string.concat("state change failed: ", _getRevertMsg(output))
            );
        }
        revert(Base64.encode(abi.encode(this.getSubaccountInfo(subaccountId))));
    }

    function getSubaccountInfo(
        uint64 subaccountId
    ) external view returns (SubaccountInfo memory) {
        SubaccountInfo memory subaccountInfo;

        {
            (
                uint32[] memory spotIds,
                uint32[] memory perpIds
            ) = _getAllProductIds();

            // initial, maintenance, pnl
            subaccountInfo.subaccountId = subaccountId;
            subaccountInfo.exists =
                subaccountId <= clearinghouse.getNumSubaccounts() &&
                subaccountId != FEES_SUBACCOUNT_ID;
            subaccountInfo.healths = new HealthInfo[](3);
            subaccountInfo.spotBalances = new SpotBalance[](spotIds.length);
            subaccountInfo.perpBalances = new PerpBalance[](perpIds.length);
            subaccountInfo.spotProducts = new SpotProduct[](spotIds.length);
            subaccountInfo.perpProducts = new PerpProduct[](perpIds.length);
        }

        IClearinghouseState.HealthGroup[] memory healthGroups = clearinghouse
            .getHealthGroups();
        for (uint256 i = 0; i < healthGroups.length; i++) {
            IClearinghouse.HealthGroup memory group = healthGroups[i];
            IClearinghouseState.HealthVars memory healthVars;

            if (group.spotId != 0) {
                (
                    ISpotEngine.LpState memory lpState,
                    ISpotEngine.LpBalance memory lpBalance,
                    ISpotEngine.State memory state,
                    ISpotEngine.Balance memory balance
                ) = spotEngine.getStatesAndBalances(group.spotId, subaccountId);

                healthVars.spotPriceX18 = endpoint.getPriceX18(group.spotId);
                int256 ratioX18 = lpBalance.amountX18 == 0
                    ? int256(0)
                    : lpBalance.amountX18.div(lpState.supply.fromInt());

                (int256 ammBaseX18, int256 ammQuoteX18) = MathHelper
                    .ammEquilibrium(
                        lpState.base.amountX18,
                        lpState.quote.amountX18,
                        healthVars.spotPriceX18
                    );

                for (uint256 j = 0; j < 3; ++j) {
                    subaccountInfo.healths[j].assetsX18 += ammQuoteX18.mul(
                        ratioX18
                    );
                }

                healthVars.spotInLpAmountX18 = ammBaseX18.mul(ratioX18);
                healthVars.spotAmountX18 = balance.amountX18;
                healthVars.spotRisk = clearinghouse.getRisk(group.spotId);

                subaccountInfo.spotBalances[
                    subaccountInfo.spotCount
                ] = SpotBalance({
                    productId: group.spotId,
                    balance: balance,
                    lpBalance: lpBalance
                });
                subaccountInfo.spotProducts[
                    subaccountInfo.spotCount++
                ] = SpotProduct({
                    productId: group.spotId,
                    oraclePriceX18: healthVars.spotPriceX18,
                    risk: healthVars.spotRisk,
                    config: spotEngine.getConfig(group.spotId),
                    state: state,
                    lpState: lpState,
                    bookInfo: getBookInfo(group.spotId, spotEngine)
                });
            }
            if (group.perpId != 0) {
                (
                    IPerpEngine.LpState memory lpState,
                    IPerpEngine.LpBalance memory lpBalance,
                    IPerpEngine.State memory state,
                    IPerpEngine.Balance memory balance
                ) = perpEngine.getStatesAndBalances(group.perpId, subaccountId);
                healthVars.perpPriceX18 = endpoint.getPriceX18(group.perpId);
                int256 ratioX18 = lpBalance.amountX18 == 0
                    ? int256(0)
                    : lpBalance.amountX18.div(lpState.supply.fromInt());

                (int256 ammBaseX18, int256 ammQuoteX18) = MathHelper
                    .ammEquilibrium(
                        lpState.base.fromInt(),
                        lpState.quote.fromInt(),
                        healthVars.perpPriceX18
                    );

                for (uint256 j = 0; j < 3; ++j) {
                    subaccountInfo.healths[j].assetsX18 += ammQuoteX18.mul(
                        ratioX18
                    );
                }

                for (uint256 j = 0; j < 3; ++j) {
                    if (balance.vQuoteBalanceX18 > 0) {
                        subaccountInfo.healths[j].assetsX18 += balance
                            .vQuoteBalanceX18;
                    } else {
                        subaccountInfo.healths[j].liabilitiesX18 -= balance
                            .vQuoteBalanceX18;
                    }
                }

                healthVars.perpInLpAmountX18 = ammBaseX18.mul(ratioX18);
                healthVars.perpAmountX18 = balance.amountX18;
                healthVars.perpRisk = clearinghouse.getRisk(group.perpId);

                if (
                    (healthVars.spotAmountX18 > 0) !=
                    (healthVars.perpAmountX18 > 0)
                ) {
                    if (healthVars.spotAmountX18 > 0) {
                        healthVars.basisAmountX18 = MathHelper.min(
                            healthVars.spotAmountX18,
                            -healthVars.perpAmountX18
                        );
                    } else {
                        healthVars.basisAmountX18 = MathHelper.max(
                            healthVars.spotAmountX18,
                            -healthVars.perpAmountX18
                        );
                    }
                    healthVars.spotAmountX18 -= healthVars.basisAmountX18;
                    healthVars.perpAmountX18 += healthVars.basisAmountX18;
                }

                subaccountInfo.perpBalances[
                    subaccountInfo.perpCount
                ] = PerpBalance({
                    productId: group.perpId,
                    balance: balance,
                    lpBalance: lpBalance
                });
                subaccountInfo.perpProducts[
                    subaccountInfo.perpCount++
                ] = PerpProduct({
                    productId: group.perpId,
                    oraclePriceX18: healthVars.perpPriceX18,
                    markPriceX18: perpEngine.getMarkPrice(group.perpId),
                    risk: healthVars.perpRisk,
                    state: state,
                    lpState: lpState,
                    bookInfo: getBookInfo(group.perpId, perpEngine)
                });
            }

            // risk for the basis trade, discounted
            if (healthVars.basisAmountX18 != 0) {
                int256 posAmountX18 = MathHelper.abs(healthVars.basisAmountX18);

                for (uint8 healthType = 0; healthType < 3; ++healthType) {
                    // add the actual value of the basis (PNL)

                    int256 healthContributionX18 = (healthVars.spotPriceX18 -
                        healthVars.perpPriceX18).mul(healthVars.basisAmountX18);

                    // compute a penalty% on the notional size of the basis trade
                    // this is equivalent to a long weight, i.e. long weight 0.95 == 0.05 penalty
                    // we take the square of the penalties on the spot and the perp positions
                    healthContributionX18 -= RiskHelper
                        ._getSpreadPenaltyX18(
                            healthVars.spotRisk,
                            healthVars.perpRisk,
                            posAmountX18,
                            IProductEngine.HealthType(healthType)
                        )
                        .mul(posAmountX18)
                        .mul(healthVars.spotPriceX18 + healthVars.perpPriceX18);
                    if (healthContributionX18 > 0) {
                        subaccountInfo
                            .healths[healthType]
                            .assetsX18 += healthContributionX18;
                    } else {
                        subaccountInfo
                            .healths[healthType]
                            .liabilitiesX18 -= healthContributionX18;
                    }
                }
            }

            // apply risk for spot and perp positions
            int256 combinedSpotX18 = healthVars.spotAmountX18 +
                healthVars.spotInLpAmountX18;

            for (uint8 healthType = 0; healthType < 3; ++healthType) {
                int256 healthContributionX18 = RiskHelper
                    ._getWeightX18(
                        healthVars.spotRisk,
                        combinedSpotX18,
                        IProductEngine.HealthType(healthType)
                    )
                    .mul(combinedSpotX18)
                    .mul(healthVars.spotPriceX18);

                // Spot LP penalty
                healthContributionX18 -= (ONE -
                    RiskHelper._getWeightX18(
                        healthVars.spotRisk,
                        healthVars.spotInLpAmountX18,
                        IProductEngine.HealthType(healthType)
                    )).mul(healthVars.spotInLpAmountX18).mul(
                        healthVars.spotPriceX18
                    );

                if (healthContributionX18 > 0) {
                    subaccountInfo
                        .healths[healthType]
                        .assetsX18 += healthContributionX18;
                } else {
                    subaccountInfo
                        .healths[healthType]
                        .liabilitiesX18 -= healthContributionX18;
                }
            }

            int256 combinedPerpX18 = healthVars.perpAmountX18 +
                healthVars.perpInLpAmountX18;

            for (uint8 healthType = 0; healthType < 3; ++healthType) {
                int256 healthContributionX18 = RiskHelper
                    ._getWeightX18(
                        healthVars.perpRisk,
                        combinedPerpX18,
                        IProductEngine.HealthType(healthType)
                    )
                    .mul(combinedPerpX18)
                    .mul(healthVars.perpPriceX18);

                // perp LP penalty
                healthContributionX18 -= (ONE -
                    RiskHelper._getWeightX18(
                        healthVars.perpRisk,
                        healthVars.perpInLpAmountX18,
                        IProductEngine.HealthType(healthType)
                    )).mul(healthVars.perpInLpAmountX18).mul(
                        healthVars.perpPriceX18
                    );

                if (healthContributionX18 > 0) {
                    subaccountInfo
                        .healths[healthType]
                        .assetsX18 += healthContributionX18;
                } else {
                    subaccountInfo
                        .healths[healthType]
                        .liabilitiesX18 -= healthContributionX18;
                }
            }
        }

        // handle the quote balance since its not present in healthGroups
        {
            (
                ISpotEngine.State memory state,
                ISpotEngine.Balance memory balance
            ) = spotEngine.getStateAndBalance(QUOTE_PRODUCT_ID, subaccountId);
            subaccountInfo
                .spotBalances[subaccountInfo.spotCount]
                .balance = balance;
            subaccountInfo
                .spotProducts[subaccountInfo.spotCount]
                .oraclePriceX18 = ONE;
            subaccountInfo
                .spotProducts[subaccountInfo.spotCount]
                .risk = clearinghouse.getRisk(QUOTE_PRODUCT_ID);
            subaccountInfo
                .spotProducts[subaccountInfo.spotCount]
                .config = spotEngine.getConfig(QUOTE_PRODUCT_ID);
            subaccountInfo
                .spotProducts[subaccountInfo.spotCount++]
                .state = state;

            for (uint256 i = 0; i < 3; ++i) {
                if (balance.amountX18 > 0) {
                    subaccountInfo.healths[i].assetsX18 += balance.amountX18;
                } else {
                    subaccountInfo.healths[i].liabilitiesX18 -= balance
                        .amountX18;
                }
            }
        }

        for (uint256 i = 0; i < 3; ++i) {
            subaccountInfo.healths[i].healthX18 =
                subaccountInfo.healths[i].assetsX18 -
                subaccountInfo.healths[i].liabilitiesX18;
        }

        return subaccountInfo;
    }

    function getSpotBalances(
        uint64 subaccountId,
        uint32[] memory productIds
    ) public view returns (SpotBalance[] memory spotBalances) {
        ISpotEngine engine = ISpotEngine(
            clearinghouse.getEngineByType(IProductEngine.EngineType.SPOT)
        );
        spotBalances = new SpotBalance[](productIds.length);

        for (uint32 i = 0; i < productIds.length; i++) {
            uint32 productId = productIds[i];
            spotBalances[i] = _getSpotBalance(subaccountId, productId, engine);
        }
    }

    function getPerpBalances(
        uint64 subaccountId,
        uint32[] memory productIds
    ) public view returns (PerpBalance[] memory perpBalances) {
        IPerpEngine engine = IPerpEngine(
            clearinghouse.getEngineByType(IProductEngine.EngineType.PERP)
        );
        perpBalances = new PerpBalance[](productIds.length);

        for (uint32 i = 0; i < productIds.length; i++) {
            uint32 productId = productIds[i];
            perpBalances[i] = _getPerpBalance(subaccountId, productId, engine);
        }
    }

    function _getSpotBalance(
        uint64 subaccountId,
        uint32 productId,
        ISpotEngine engine
    ) internal view returns (SpotBalance memory) {
        (
            ,
            ISpotEngine.LpBalance memory lpBalance,
            ,
            ISpotEngine.Balance memory balance
        ) = engine.getStatesAndBalances(productId, subaccountId);
        return
            SpotBalance({
                productId: productId,
                lpBalance: lpBalance,
                balance: balance
            });
    }

    function _getPerpBalance(
        uint64 subaccountId,
        uint32 productId,
        IPerpEngine engine
    ) internal view returns (PerpBalance memory) {
        (
            ,
            IPerpEngine.LpBalance memory lpBalance,
            ,
            IPerpEngine.Balance memory balance
        ) = engine.getStatesAndBalances(productId, subaccountId);
        return
            PerpBalance({
                productId: productId,
                lpBalance: lpBalance,
                balance: balance
            });
    }

    function getBookInfo(
        uint32 productId,
        IProductEngine engine
    ) public view returns (BookInfo memory bookInfo) {
        IOffchainBook book = IOffchainBook(engine.getOrderbook(productId));
        IOffchainBook.Market memory market = book.getMarket();
        return
            BookInfo({
                sizeIncrement: market.sizeIncrement,
                priceIncrementX18: market.priceIncrementX18,
                collectedFeesX18: market.collectedFeesX18,
                lpSpreadX18: market.lpSpreadX18
            });
    }
}
