// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "hardhat/console.sol";

import "./common/Constants.sol";
import "./interfaces/clearinghouse/IClearinghouseLiq.sol";
import "./interfaces/clearinghouse/IClearinghouse.sol";
import "./interfaces/engine/IProductEngine.sol";
import "./interfaces/engine/ISpotEngine.sol";
import "./interfaces/IOffchainBook.sol";
import "./libraries/KeyHelper.sol";
import "./libraries/ERC20Helper.sol";
import "./libraries/MathHelper.sol";
import "./libraries/MathSD21x18.sol";
import "./interfaces/engine/IPerpEngine.sol";
import "./EndpointGated.sol";
import "./interfaces/IEndpoint.sol";
import "./ClearinghouseRisk.sol";
import "./ClearinghouseStorage.sol";

contract ClearinghouseLiq is
    ClearinghouseRisk,
    ClearinghouseStorage,
    IClearinghouseLiq
{
    using MathSD21x18 for int128;

    function getHealth(
        uint64 subaccountId,
        IProductEngine.HealthType healthType
    ) internal view returns (int128 healthX18) {
        return
            IClearinghouse(clearinghouse).getHealth(subaccountId, healthType);
    }

    function _loadSubaccount(address from, string calldata name)
        internal
        returns (uint64)
    {
        require(bytes(name).length <= 12, ERR_LONG_NAME);
        if (subaccounts[from][name] == 0) {
            // IDs need to start at 1
            subaccounts[from][name] = ++subaccountCount;
            subaccountOwner[subaccountCount] = from;
            subaccountNames[subaccountCount] = name;
            emit CreateSubaccount(from, name, subaccountCount);
        }
        return subaccounts[from][name];
    }

    // TODO: we can optim this
    // 2 ideas:
    // 1. batch into one function so we just return all flavors of health in one go
    // 2. heuristic based health, cache last health and keep track of price changes
    //    s.t. we have a 4stdev likelihood of being able to determine these, this would be huge
    // tails would still be expensive, but 99.9% likelihood it would be super cheap
    function _isUnderInitial(uint64 subaccountId) public view returns (bool) {
        // Weighted initial health with limit orders < 0
        return getHealth(subaccountId, IProductEngine.HealthType.INITIAL) < 0;
    }

    function _isAboveInitial(uint64 subaccountId) public view returns (bool) {
        // Weighted initial health with limit orders < 0
        return getHealth(subaccountId, IProductEngine.HealthType.INITIAL) > 0;
    }

    function _isUnderMaintenance(uint64 subaccountId)
        internal
        view
        returns (bool)
    {
        // Weighted maintenance health < 0
        return
            getHealth(subaccountId, IProductEngine.HealthType.MAINTENANCE) < 0;
    }

    struct HealthGroupSummary {
        int128 perpAmount;
        int128 perpVQuote;
        int128 perpPriceX18;
        int128 spotAmount;
        int128 spotPriceX18;
        int128 basisAmount;
    }

    function describeHealthGroup(
        ISpotEngine spotEngine,
        IPerpEngine perpEngine,
        uint32 groupId,
        uint64 subaccountId
    ) internal view returns (HealthGroupSummary memory summary) {
        HealthGroup memory group = healthGroups[groupId];

        if (group.spotId != 0) {
            (, ISpotEngine.Balance memory balance) = spotEngine
                .getStateAndBalance(group.spotId, subaccountId);
            summary.spotAmount = balance.amount;
            summary.spotPriceX18 = getOraclePriceX18(group.spotId);
        }

        if (group.perpId != 0) {
            (, IPerpEngine.Balance memory balance) = perpEngine
                .getStateAndBalance(group.perpId, subaccountId);
            summary.perpAmount = balance.amount;
            summary.perpVQuote = balance.vQuoteBalance;
            summary.perpPriceX18 = getOraclePriceX18(group.perpId);
        }

        if ((summary.spotAmount > 0) != (summary.perpAmount > 0)) {
            if (summary.spotAmount > 0) {
                summary.basisAmount = MathHelper.min(
                    summary.spotAmount,
                    -summary.perpAmount
                );
            } else {
                summary.basisAmount = MathHelper.max(
                    summary.spotAmount,
                    -summary.perpAmount
                );
            }
            summary.spotAmount -= summary.basisAmount;
            summary.perpAmount += summary.basisAmount;
        }
    }

    enum LiquidationStatus {
        CannotLiquidateLiabilities, // still has assets or perps
        CannotSocialize, // still has basis liabilities
        // must wait until basis liability liquidation is finished
        // and only spot liabilities are remaining
        // remaining: spot liabilities and perp losses
        // if insurance drained:
        // -> socialize all
        // if insurance not drained
        // -> if spot liabilities, exit
        // -> else attempt to repay all from insurance
        CanSocialize
    }

    function getLiquidationStatus(
        ISpotEngine spotEngine,
        IPerpEngine perpEngine,
        uint64 subaccountId
    ) internal view returns (LiquidationStatus) {
        bool canSocialize = true;
        (, ISpotEngine.Balance memory balance) = spotEngine.getStateAndBalance(
            QUOTE_PRODUCT_ID,
            subaccountId
        );

        canSocialize = canSocialize && (balance.amount <= 0);

        for (uint32 i = 0; i < maxHealthGroup; ++i) {
            HealthGroupSummary memory summary = describeHealthGroup(
                spotEngine,
                perpEngine,
                i,
                subaccountId
            );
            // long spot and long spreads are assets and should
            // be liquidated first
            if (summary.spotAmount > 0 || summary.basisAmount > 0) {
                return LiquidationStatus.CannotLiquidateLiabilities;
            }

            canSocialize = canSocialize && (summary.basisAmount == 0);

            // perp positions (outside of spreads) should be completely
            // closed before we can start liquidating liabilities

            // however we could potentially still have a closed perp position
            // with a positive vQuote balance, in which case the vQuote balance
            // should be settled into USDC first, since it would be an asset
            // note this vQuote balance criteria does not interfere with spreads;
            // the only spreads remaining at this point are short spreads
            // which are short spot and long perp. long perp should always
            // have negative vQuote after settlement, so this will
            // not trigger on a short spread
            if (summary.perpVQuote > 0 || summary.perpAmount != 0) {
                return LiquidationStatus.CannotLiquidateLiabilities;
            }
        }
        return
            (canSocialize)
                ? LiquidationStatus.CanSocialize
                : LiquidationStatus.CannotSocialize;
    }

    function assertLiquidationAmount(
        int128 originalBalance,
        int128 liquidationAmount
    ) internal pure {
        require(
            (originalBalance != 0 && liquidationAmount != 0) &&
                ((liquidationAmount > 0 &&
                    originalBalance >= liquidationAmount) ||
                    (liquidationAmount <= 0 &&
                        originalBalance <= liquidationAmount)),
            ERR_NOT_LIQUIDATABLE_AMT
        );
    }

    struct LiquidationVars {
        int128 liquidationPriceX18;
        int128 excessPerpToLiquidate;
        int128 liquidationPayment;
        int128 insuranceCover;
        int128 oraclePriceX18;
        int128 liquidationFees;
    }

    function liquidateSubaccount(IEndpoint.LiquidateSubaccount calldata txn)
        external
    {
        uint64 liquidatorId = _loadSubaccount(txn.sender, txn.subaccountName);
        require(liquidatorId != txn.liquidateeId, ERR_UNAUTHORIZED);

        require(_isUnderMaintenance(txn.liquidateeId), ERR_NOT_LIQUIDATABLE);

        ISpotEngine spotEngine = ISpotEngine(
            address(engineByType[IProductEngine.EngineType.SPOT])
        );
        IPerpEngine perpEngine = IPerpEngine(
            address(engineByType[IProductEngine.EngineType.PERP])
        );
        spotEngine.decomposeLps(txn.liquidateeId, liquidatorId);
        perpEngine.decomposeLps(txn.liquidateeId, liquidatorId);

        if (
            getHealth(txn.liquidateeId, IProductEngine.HealthType.INITIAL) >= 0
        ) {
            return;
        }

        HealthGroupSummary memory summary = describeHealthGroup(
            spotEngine,
            perpEngine,
            txn.healthGroup,
            txn.liquidateeId
        );
        bool isLiability = false;
        int128 amountToLiquidate = txn.amount;
        LiquidationVars memory vars;

        // TODO: transfer some premium to insurance fund
        if (txn.mode == uint8(IEndpoint.LiquidationMode.SPREAD)) {
            assertLiquidationAmount(summary.basisAmount, amountToLiquidate);
            isLiability = summary.basisAmount < 0;

            HealthGroup memory healthGroup = healthGroups[txn.healthGroup];
            require(healthGroup.spotId != 0 && healthGroup.perpId != 0);

            vars.liquidationPriceX18 = getSpreadLiqPriceX18(
                healthGroup,
                amountToLiquidate
            );
            vars.oraclePriceX18 = getOraclePriceX18(healthGroup.spotId);

            // there is a fixed amount of the spot component of the spread
            // we can liquidate until the insurance fund runs out of money
            // however we can still liquidate the remaining perp component
            // at the perp liquidation price. this way the spot liability just remains
            // and the spread liability decomposes into a spot liability which is
            // handled through socialization

            // TODO: this block more or less copies spot liquidation exactly

            if (isLiability) {
                (, ISpotEngine.Balance memory quoteBalance) = spotEngine
                    .getStateAndBalance(QUOTE_PRODUCT_ID, txn.liquidateeId);

                int128 maximumLiquidatable = MathHelper.max(
                    (quoteBalance.amount + insurance).div(
                        vars.liquidationPriceX18
                    ),
                    0
                );

                vars.excessPerpToLiquidate =
                    MathHelper.max(amountToLiquidate, -maximumLiquidatable) -
                    amountToLiquidate;
                amountToLiquidate += vars.excessPerpToLiquidate;
                vars.liquidationPayment = vars.liquidationPriceX18.mul(
                    amountToLiquidate
                );
                vars.insuranceCover = MathHelper.min(
                    insurance,
                    MathHelper.max(
                        0,
                        -vars.liquidationPayment - quoteBalance.amount
                    )
                );
            } else {
                vars.liquidationPayment = vars.liquidationPriceX18.mul(
                    amountToLiquidate
                );
            }

            vars.liquidationFees = (vars.oraclePriceX18 -
                vars.liquidationPriceX18)
                .mul(
                    fees.getLiquidationFeeFractionX18(
                        liquidatorId,
                        healthGroup.spotId
                    )
                )
                .mul(amountToLiquidate);

            IProductEngine.ProductDelta[]
                memory deltas = new IProductEngine.ProductDelta[](4);
            deltas[0] = IProductEngine.ProductDelta({
                productId: healthGroup.spotId,
                subaccountId: txn.liquidateeId,
                amountDelta: -amountToLiquidate,
                vQuoteDelta: vars.liquidationPayment
            });
            deltas[1] = IProductEngine.ProductDelta({
                productId: healthGroup.spotId,
                subaccountId: liquidatorId,
                amountDelta: amountToLiquidate,
                vQuoteDelta: -vars.liquidationPayment
            });
            deltas[2] = IProductEngine.ProductDelta({
                productId: QUOTE_PRODUCT_ID,
                subaccountId: txn.liquidateeId,
                amountDelta: vars.liquidationPayment + vars.insuranceCover,
                vQuoteDelta: 0
            });
            deltas[3] = IProductEngine.ProductDelta({
                productId: QUOTE_PRODUCT_ID,
                subaccountId: liquidatorId,
                amountDelta: -vars.liquidationPayment - vars.liquidationFees,
                vQuoteDelta: 0
            });

            insurance -= vars.insuranceCover;
            insurance += vars.liquidationFees;
            spotEngine.applyDeltas(deltas);

            // end spot liquidation copied block

            vars.oraclePriceX18 = getOraclePriceX18(healthGroup.perpId);
            // write perp deltas
            // in spread liquidation, we do the liquidation payment
            // on top of liquidating the spot. for perp we simply
            // transfer the balances at 0 pnl
            // (ie. vQuoteAmount == amount * perpPrice)
            int128 perpQuoteDelta = amountToLiquidate.mul(vars.oraclePriceX18);

            vars.liquidationPriceX18 = getLiqPriceX18(
                healthGroup.perpId,
                vars.excessPerpToLiquidate
            );

            int128 excessPerpQuoteDelta = vars.liquidationPriceX18.mul(
                vars.excessPerpToLiquidate
            );

            vars.liquidationFees = (vars.oraclePriceX18 -
                vars.liquidationPriceX18)
                .mul(
                    fees.getLiquidationFeeFractionX18(
                        liquidatorId,
                        healthGroup.perpId
                    )
                )
                .mul(vars.excessPerpToLiquidate);

            deltas = new IProductEngine.ProductDelta[](2);
            deltas[0] = IProductEngine.ProductDelta({
                productId: healthGroup.perpId,
                subaccountId: txn.liquidateeId,
                amountDelta: amountToLiquidate - vars.excessPerpToLiquidate,
                vQuoteDelta: -perpQuoteDelta + excessPerpQuoteDelta
            });
            deltas[1] = IProductEngine.ProductDelta({
                productId: healthGroup.perpId,
                subaccountId: liquidatorId,
                amountDelta: -amountToLiquidate + vars.excessPerpToLiquidate,
                vQuoteDelta: perpQuoteDelta -
                    excessPerpQuoteDelta -
                    vars.liquidationFees
            });
            insurance += vars.liquidationFees;
            perpEngine.applyDeltas(deltas);
        } else if (txn.mode == uint8(IEndpoint.LiquidationMode.SPOT)) {
            uint32 productId = healthGroups[txn.healthGroup].spotId;
            require(
                productId != QUOTE_PRODUCT_ID,
                ERR_INVALID_LIQUIDATION_PARAMS
            );
            assertLiquidationAmount(summary.spotAmount, amountToLiquidate);
            isLiability = summary.spotAmount < 0;
            (, ISpotEngine.Balance memory quoteBalance) = spotEngine
                .getStateAndBalance(QUOTE_PRODUCT_ID, txn.liquidateeId);

            vars.liquidationPriceX18 = getLiqPriceX18(
                productId,
                amountToLiquidate
            );
            vars.oraclePriceX18 = getOraclePriceX18(productId);

            if (isLiability) {
                int128 maximumLiquidatable = MathHelper.max(
                    (quoteBalance.amount + insurance).div(
                        vars.liquidationPriceX18
                    ),
                    0
                );
                amountToLiquidate = MathHelper.max(
                    amountToLiquidate,
                    -maximumLiquidatable
                );
            }
            vars.liquidationPayment = vars.liquidationPriceX18.mul(
                amountToLiquidate
            );

            vars.liquidationFees = (vars.oraclePriceX18 -
                vars.liquidationPriceX18)
                .mul(fees.getLiquidationFeeFractionX18(liquidatorId, productId))
                .mul(amountToLiquidate);

            // quoteBalance.amount + liquidationPayment18 + insuranceCover == 0
            vars.insuranceCover = (isLiability)
                ? MathHelper.min(
                    insurance,
                    MathHelper.max(
                        0,
                        -vars.liquidationPayment - quoteBalance.amount
                    )
                )
                : int128(0);

            IProductEngine.ProductDelta[]
                memory deltas = new IProductEngine.ProductDelta[](4);
            deltas[0] = IProductEngine.ProductDelta({
                productId: productId,
                subaccountId: txn.liquidateeId,
                amountDelta: -amountToLiquidate,
                vQuoteDelta: vars.liquidationPayment
            });
            deltas[1] = IProductEngine.ProductDelta({
                productId: productId,
                subaccountId: liquidatorId,
                amountDelta: amountToLiquidate,
                vQuoteDelta: -vars.liquidationPayment
            });
            deltas[2] = IProductEngine.ProductDelta({
                productId: QUOTE_PRODUCT_ID,
                subaccountId: txn.liquidateeId,
                amountDelta: vars.liquidationPayment + vars.insuranceCover,
                vQuoteDelta: 0
            });
            deltas[3] = IProductEngine.ProductDelta({
                productId: QUOTE_PRODUCT_ID,
                subaccountId: liquidatorId,
                amountDelta: -vars.liquidationPayment - vars.liquidationFees,
                vQuoteDelta: 0
            });

            insurance -= vars.insuranceCover;
            insurance += vars.liquidationFees;
            spotEngine.applyDeltas(deltas);
        } else if (txn.mode == uint8(IEndpoint.LiquidationMode.PERP)) {
            uint32 productId = healthGroups[txn.healthGroup].perpId;
            require(
                productId != QUOTE_PRODUCT_ID,
                ERR_INVALID_LIQUIDATION_PARAMS
            );
            assertLiquidationAmount(summary.perpAmount, amountToLiquidate);

            vars.liquidationPriceX18 = getLiqPriceX18(
                productId,
                amountToLiquidate
            );
            vars.oraclePriceX18 = getOraclePriceX18(productId);

            vars.liquidationPayment = vars.liquidationPriceX18.mul(
                amountToLiquidate
            );
            vars.liquidationFees = (vars.oraclePriceX18 -
                vars.liquidationPriceX18)
                .mul(fees.getLiquidationFeeFractionX18(liquidatorId, productId))
                .mul(amountToLiquidate);

            IProductEngine.ProductDelta[]
                memory deltas = new IProductEngine.ProductDelta[](2);
            deltas[0] = IProductEngine.ProductDelta({
                productId: productId,
                subaccountId: txn.liquidateeId,
                amountDelta: -amountToLiquidate,
                vQuoteDelta: vars.liquidationPayment
            });
            deltas[1] = IProductEngine.ProductDelta({
                productId: productId,
                subaccountId: liquidatorId,
                amountDelta: amountToLiquidate,
                vQuoteDelta: -vars.liquidationPayment - vars.liquidationFees
            });
            insurance += vars.liquidationFees;
            perpEngine.applyDeltas(deltas);
        } else {
            revert(ERR_INVALID_LIQUIDATION_PARAMS);
        }

        // it's ok to let initial health become 0
        require(!_isAboveInitial(txn.liquidateeId), ERR_LIQUIDATED_TOO_MUCH);
        require(!_isUnderInitial(liquidatorId), ERR_SUBACCT_HEALTH);
        if (isLiability) {
            LiquidationStatus status = getLiquidationStatus(
                spotEngine,
                perpEngine,
                txn.liquidateeId
            );

            require(
                status != LiquidationStatus.CannotLiquidateLiabilities,
                ERR_NOT_LIQUIDATABLE_LIABILITIES
            );

            if (status == LiquidationStatus.CanSocialize) {
                insurance = perpEngine.socializeSubaccount(
                    txn.liquidateeId,
                    insurance
                );
                spotEngine.socializeSubaccount(txn.liquidateeId, insurance);
            }
        }

        emit Liquidation(
            liquidatorId,
            txn.liquidateeId,
            // 0 -> spread, 1 -> spot, 2 -> perp
            txn.mode,
            txn.healthGroup,
            txn.amount, // amount that was liquidated
            // this is the amount of product transferred from liquidatee
            // to liquidator; this and the following field will have the same sign
            // if spread, one unit represents one long spot and one short perp
            // i.e. if amount == -1, it means a short spot and a long perp was liquidated
            vars.liquidationPayment, // add actual liquidatee quoteDelta
            // meaning there was a payment of liquidationPayment
            // from liquidator to liquidatee for the liquidated products
            vars.insuranceCover
        );
    }
}
