// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

import "./libraries/MathSD21x18.sol";
import "@openzeppelin/contracts/utils/Base64.sol";
import "./interfaces/IFEndpoint.sol";
import "./Clearinghouse.sol";
import "./ClearinghouseLiq.sol";

contract FClearinghouse is Clearinghouse, ClearinghouseLiq {
    using MathSD21x18 for int128;

    // token => balance
    mapping(address => uint128) public tokenBalances;

    function handleDepositTransfer(
        IERC20Base token,
        address,
        uint128 amount
    ) internal override {
        tokenBalances[address(token)] += amount;
    }

    function handleWithdrawTransfer(
        IERC20Base token,
        address,
        uint128 amount
    ) internal override {
        require(tokenBalances[address(token)] >= amount, "balance is too low");
        tokenBalances[address(token)] -= amount;
    }

    function setInsurance(int128 amount) external {
        insurance = amount;
    }

    function setTokenBalance(address token, uint128 amount) external {
        tokenBalances[token] = amount;
    }

    function getTokenBalance(address token) external view returns (uint128) {
        IERC20Base erc20Token = IERC20Base(token);
        uint256 multiplier = uint256(
            10**(MAX_DECIMALS - erc20Token.decimals())
        );
        return tokenBalances[token] * uint128(multiplier);
    }

    function liquidateSubaccount(IEndpoint.LiquidateSubaccount calldata txn)
        external
        override
        onlyEndpoint
    {
        this.liquidateSubaccountImpl(txn);
    }

    // helper functions
    // allows indexer to access balances after specific steps in liquidation
    // to make computing pnl easier
    function liqDecomposeLps(IEndpoint.LiquidateSubaccount calldata txn)
        public
        returns (bool)
    {
        require(txn.sender != txn.liquidatee, ERR_UNAUTHORIZED);
        require(isUnderMaintenance(txn.liquidatee), ERR_NOT_LIQUIDATABLE);

        ISpotEngine spotEngine = ISpotEngine(
            address(engineByType[IProductEngine.EngineType.SPOT])
        );
        IPerpEngine perpEngine = IPerpEngine(
            address(engineByType[IProductEngine.EngineType.PERP])
        );
        insurance += spotEngine.decomposeLps(
            txn.liquidatee,
            txn.sender,
            address(fees)
        );
        insurance += perpEngine.decomposeLps(
            txn.liquidatee,
            txn.sender,
            address(fees)
        );

        return
            getHealthFromClearinghouse(
                txn.liquidatee,
                IProductEngine.HealthType.INITIAL
            ) >= 0;
    }

    function liqFinalizeSubaccount(IEndpoint.LiquidateSubaccount calldata txn)
        public
        returns (bool)
    {
        ISpotEngine spotEngine = ISpotEngine(
            address(engineByType[IProductEngine.EngineType.SPOT])
        );
        IPerpEngine perpEngine = IPerpEngine(
            address(engineByType[IProductEngine.EngineType.PERP])
        );
        if (txn.healthGroup == type(uint32).max) {
            finalizeSubaccount(
                spotEngine,
                perpEngine,
                txn.sender,
                txn.liquidatee
            );
            return true;
        }
        return false;
    }

    function liqSettleAgainstLiquidator(
        IEndpoint.LiquidateSubaccount calldata txn
    ) public {
        ISpotEngine spotEngine = ISpotEngine(
            address(engineByType[IProductEngine.EngineType.SPOT])
        );
        IPerpEngine perpEngine = IPerpEngine(
            address(engineByType[IProductEngine.EngineType.PERP])
        );

        int128 amountToLiquidate = txn.amount;
        bool isLiability = (txn.mode !=
            uint8(IEndpoint.LiquidationMode.PERP)) && (amountToLiquidate < 0);

        if (isLiability) {
            // check whether liabilities can be liquidated and settle
            // all positive pnls
            for (uint32 i = 0; i <= maxHealthGroup; ++i) {
                HealthGroupSummary memory groupSummary = describeHealthGroup(
                    spotEngine,
                    perpEngine,
                    i,
                    txn.liquidatee
                );

                // liabilities can only be liquidated after
                // - all perp positions (outside of spreads) have closed
                // - no spot nor spread assets exist
                require(
                    groupSummary.perpAmount == 0 &&
                        groupSummary.spotAmount <= 0 &&
                        groupSummary.basisAmount <= 0,
                    ERR_NOT_LIQUIDATABLE_LIABILITIES
                );

                // settle positive pnl against the liquidator
                int128 positionPnl = perpEngine.getPositionPnl(
                    groupSummary.perpId,
                    txn.liquidatee
                );
                if (positionPnl > 0) {
                    settlePnlAgainstLiquidator(
                        spotEngine,
                        perpEngine,
                        txn.sender,
                        txn.liquidatee,
                        groupSummary.perpId,
                        positionPnl
                    );
                }
            }
        }
    }

    function liqLiquidationPayment(IEndpoint.LiquidateSubaccount calldata txn)
        public
    {
        ISpotEngine spotEngine = ISpotEngine(
            address(engineByType[IProductEngine.EngineType.SPOT])
        );
        IPerpEngine perpEngine = IPerpEngine(
            address(engineByType[IProductEngine.EngineType.PERP])
        );
        int128 amountToLiquidate = txn.amount;
        bool isLiability = (txn.mode !=
            uint8(IEndpoint.LiquidationMode.PERP)) && (amountToLiquidate < 0);

        IProductEngine.ProductDelta[] memory deltas;

        HealthGroupSummary memory summary = describeHealthGroup(
            spotEngine,
            perpEngine,
            txn.healthGroup,
            txn.liquidatee
        );
        LiquidationVars memory vars;

        vars.perpSizeIncrement = IOffchainBook(_getOrderbook(summary.perpId))
            .getMarket()
            .sizeIncrement;

        {
            int128 excessBasisAmount = summary.basisAmount %
                vars.perpSizeIncrement;
            if (excessBasisAmount != 0) {
                summary.basisAmount -= excessBasisAmount;
                summary.spotAmount += excessBasisAmount;
                summary.perpAmount -= excessBasisAmount;
            }
        }

        if (txn.mode != uint8(IEndpoint.LiquidationMode.SPOT)) {
            require(
                amountToLiquidate % vars.perpSizeIncrement == 0,
                ERR_INVALID_LIQUIDATION_AMOUNT
            );
        }

        if (txn.mode == uint8(IEndpoint.LiquidationMode.SPREAD)) {
            assertLiquidationAmount(summary.basisAmount, amountToLiquidate);
            require(summary.spotId != 0 && summary.perpId != 0);

            vars.liquidationPriceX18 = getSpreadLiqPriceX18(
                HealthGroup(summary.spotId, summary.perpId),
                amountToLiquidate
            );
            vars.oraclePriceX18 = getOraclePriceX18(summary.spotId);

            // there is a fixed amount of the spot component of the spread
            // we can liquidate until the insurance fund runs out of money
            // however we can still liquidate the remaining perp component
            // at the perp liquidation price. this way the spot liability just remains
            // and the spread liability decomposes into a spot liability which is
            // handled through socialization

            if (isLiability) {
                (, ISpotEngine.Balance memory quoteBalance) = spotEngine
                    .getStateAndBalance(QUOTE_PRODUCT_ID, txn.liquidatee);

                int128 maximumLiquidatable = MathHelper.ceil(
                    MathHelper.max(
                        // liquidate slightly more to not block socialization.
                        (quoteBalance.amount + insurance).div(
                            vars.liquidationPriceX18
                        ) + 1,
                        0
                    ),
                    vars.perpSizeIncrement
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
                        txn.sender,
                        summary.spotId
                    )
                )
                .mul(amountToLiquidate);

            deltas = new IProductEngine.ProductDelta[](4);
            deltas[0] = IProductEngine.ProductDelta({
                productId: summary.spotId,
                subaccount: txn.liquidatee,
                amountDelta: -amountToLiquidate,
                vQuoteDelta: vars.liquidationPayment
            });
            deltas[1] = IProductEngine.ProductDelta({
                productId: summary.spotId,
                subaccount: txn.sender,
                amountDelta: amountToLiquidate,
                vQuoteDelta: -vars.liquidationPayment
            });
            deltas[2] = IProductEngine.ProductDelta({
                productId: QUOTE_PRODUCT_ID,
                subaccount: txn.liquidatee,
                amountDelta: vars.liquidationPayment + vars.insuranceCover,
                vQuoteDelta: 0
            });
            deltas[3] = IProductEngine.ProductDelta({
                productId: QUOTE_PRODUCT_ID,
                subaccount: txn.sender,
                amountDelta: -vars.liquidationPayment,
                vQuoteDelta: 0
            });

            insurance -= vars.insuranceCover;
            spotEngine.applyDeltas(deltas);

            vars.oraclePriceX18 = getOraclePriceX18(summary.perpId);
            // write perp deltas
            // in spread liquidation, we do the liquidation payment
            // on top of liquidating the spot. for perp we simply
            // transfer the balances at 0 pnl
            // (ie. vQuoteAmount == amount * perpPrice)
            int128 perpQuoteDelta = amountToLiquidate.mul(vars.oraclePriceX18);

            vars.liquidationPriceX18 = getLiqPriceX18(
                summary.perpId,
                vars.excessPerpToLiquidate
            );

            int128 excessPerpQuoteDelta = vars.liquidationPriceX18.mul(
                vars.excessPerpToLiquidate
            );

            vars.liquidationFees += (vars.oraclePriceX18 -
                vars.liquidationPriceX18)
                .mul(
                    fees.getLiquidationFeeFractionX18(
                        txn.sender,
                        summary.perpId
                    )
                )
                .mul(vars.excessPerpToLiquidate);

            deltas = new IProductEngine.ProductDelta[](2);
            deltas[0] = IProductEngine.ProductDelta({
                productId: summary.perpId,
                subaccount: txn.liquidatee,
                amountDelta: amountToLiquidate - vars.excessPerpToLiquidate,
                vQuoteDelta: -perpQuoteDelta + excessPerpQuoteDelta
            });
            deltas[1] = IProductEngine.ProductDelta({
                productId: summary.perpId,
                subaccount: txn.sender,
                amountDelta: -amountToLiquidate + vars.excessPerpToLiquidate,
                vQuoteDelta: perpQuoteDelta -
                    excessPerpQuoteDelta -
                    vars.liquidationFees
            });
            perpEngine.applyDeltas(deltas);
        } else if (txn.mode == uint8(IEndpoint.LiquidationMode.SPOT)) {
            uint32 productId = summary.spotId;
            require(
                productId != QUOTE_PRODUCT_ID,
                ERR_INVALID_LIQUIDATION_PARAMS
            );
            assertLiquidationAmount(summary.spotAmount, amountToLiquidate);
            (, ISpotEngine.Balance memory quoteBalance) = spotEngine
                .getStateAndBalance(QUOTE_PRODUCT_ID, txn.liquidatee);

            vars.liquidationPriceX18 = getLiqPriceX18(
                productId,
                amountToLiquidate
            );
            vars.oraclePriceX18 = getOraclePriceX18(productId);

            if (isLiability) {
                int128 maximumLiquidatable = MathHelper.max(
                    // liquidate slightly more to not block socialization.
                    (quoteBalance.amount + insurance).div(
                        vars.liquidationPriceX18
                    ) + 1,
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
                .mul(fees.getLiquidationFeeFractionX18(txn.sender, productId))
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

            deltas = new IProductEngine.ProductDelta[](4);
            deltas[0] = IProductEngine.ProductDelta({
                productId: productId,
                subaccount: txn.liquidatee,
                amountDelta: -amountToLiquidate,
                vQuoteDelta: vars.liquidationPayment
            });
            deltas[1] = IProductEngine.ProductDelta({
                productId: productId,
                subaccount: txn.sender,
                amountDelta: amountToLiquidate,
                vQuoteDelta: -vars.liquidationPayment
            });
            deltas[2] = IProductEngine.ProductDelta({
                productId: QUOTE_PRODUCT_ID,
                subaccount: txn.liquidatee,
                amountDelta: vars.liquidationPayment + vars.insuranceCover,
                vQuoteDelta: 0
            });
            deltas[3] = IProductEngine.ProductDelta({
                productId: QUOTE_PRODUCT_ID,
                subaccount: txn.sender,
                amountDelta: -vars.liquidationPayment - vars.liquidationFees,
                vQuoteDelta: 0
            });

            insurance -= vars.insuranceCover;
            spotEngine.applyDeltas(deltas);
        } else if (txn.mode == uint8(IEndpoint.LiquidationMode.PERP)) {
            uint32 productId = summary.perpId;
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
                .mul(fees.getLiquidationFeeFractionX18(txn.sender, productId))
                .mul(amountToLiquidate);

            deltas = new IProductEngine.ProductDelta[](2);
            deltas[0] = IProductEngine.ProductDelta({
                productId: productId,
                subaccount: txn.liquidatee,
                amountDelta: -amountToLiquidate,
                vQuoteDelta: vars.liquidationPayment
            });
            deltas[1] = IProductEngine.ProductDelta({
                productId: productId,
                subaccount: txn.sender,
                amountDelta: amountToLiquidate,
                vQuoteDelta: -vars.liquidationPayment - vars.liquidationFees
            });
            perpEngine.applyDeltas(deltas);
        } else {
            revert(ERR_INVALID_LIQUIDATION_PARAMS);
        }

        // it's ok to let initial health become 0
        require(!isAboveInitial(txn.liquidatee), ERR_LIQUIDATED_TOO_MUCH);
        require(!isUnderInitial(txn.sender), ERR_SUBACCT_HEALTH);

        insurance += vars.liquidationFees;

        // if insurance is not enough for making a subaccount healthy, we should
        // - use all insurance to buy its liabilities, then
        // - socialize the subaccount

        // however, after the first step, insurance funds will be refilled a little bit
        // which blocks the second step, so we keep the fees of the last liquidation and
        // do not use this part in socialization to unblock it.
        lastLiquidationFees = vars.liquidationFees;

        emit Liquidation(
            txn.sender,
            txn.liquidatee,
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
