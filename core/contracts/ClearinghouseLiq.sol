// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "hardhat/console.sol";

import "./common/Constants.sol";
import "./interfaces/clearinghouse/IClearinghouseLiq.sol";
import "./interfaces/clearinghouse/IClearinghouse.sol";
import "./interfaces/engine/IProductEngine.sol";
import "./interfaces/engine/ISpotEngine.sol";
import "./interfaces/IOffchainExchange.sol";
import "./libraries/ERC20Helper.sol";
import "./libraries/MathHelper.sol";
import "./libraries/Logger.sol";
import "./libraries/MathSD21x18.sol";
import "./interfaces/engine/IPerpEngine.sol";
import "./EndpointGated.sol";
import "./interfaces/IEndpoint.sol";
import "./ClearinghouseStorage.sol";

contract ClearinghouseLiq is
    EndpointGated,
    ClearinghouseStorage,
    IClearinghouseLiq
{
    using MathSD21x18 for int128;

    function getHealthFromClearinghouse(
        bytes32 subaccount,
        IProductEngine.HealthType healthType
    ) internal view returns (int128 health) {
        return IClearinghouse(clearinghouse).getHealth(subaccount, healthType);
    }

    function isUnderInitial(bytes32 subaccount) public view returns (bool) {
        // Weighted initial health with limit orders < 0
        return
            getHealthFromClearinghouse(
                subaccount,
                IProductEngine.HealthType.INITIAL
            ) < 0;
    }

    function isAboveInitial(bytes32 subaccount) public view returns (bool) {
        // Weighted initial health with limit orders < 0
        return
            getHealthFromClearinghouse(
                subaccount,
                IProductEngine.HealthType.INITIAL
            ) > 0;
    }

    function isUnderMaintenance(bytes32 subaccount)
        internal
        view
        returns (bool)
    {
        // Weighted maintenance health < 0
        return
            getHealthFromClearinghouse(
                subaccount,
                IProductEngine.HealthType.MAINTENANCE
            ) < 0;
    }

    function _assertSpotLiquidationAmount(
        IEndpoint.LiquidateSubaccount calldata txn,
        ISpotEngine spotEngine,
        IPerpEngine perpEngine
    ) internal {}

    // perform all checks related to asserting liquidation amounts
    // 1. check that the liquidation reduces position without going across 0
    // 2. if perp or basis: check that it is a multiple of the size increment
    // 3. if spot or basis (liabilty): check that the liquidatee + insurance
    //    has enough quote funds to actually pay back the liability
    function _assertLiquidationAmount(
        IEndpoint.LiquidateSubaccount calldata txn,
        ISpotEngine spotEngine,
        IPerpEngine perpEngine
    ) internal view {
        uint32 spotId = 0;
        uint32 perpId = 0;

        // iterate spreads and determine spot / perp ids if applicable
        {
            uint256 _spreads = spreads;
            while (_spreads > 0) {
                uint32 _spotId = uint32(_spreads & 0xFF);
                _spreads >>= 8;
                uint32 _perpId = uint32(_spreads & 0xFF);
                _spreads >>= 8;

                uint32 encoding = (_perpId << 16) | _spotId;

                if (
                    (txn.isEncodedSpread && txn.productId == encoding) ||
                    txn.productId == _spotId ||
                    txn.productId == _perpId
                ) {
                    spotId = _spotId;
                    perpId = _perpId;
                }
            }
        }

        if (txn.isEncodedSpread) {
            require(spotId != 0 && perpId != 0, ERR_INVALID_LIQUIDATION_PARAMS);
        }

        bool isPerp = _isPerp(txn, perpEngine);
        if (spotId == 0 && perpId == 0) {
            // the product doesn't have spread
            if (isPerp) {
                perpId = txn.productId;
            } else {
                spotId = txn.productId;
            }
        }

        int128 perpSizeIncrement = 0;

        if (isPerp || perpId != 0) {
            uint32 productId = txn.isEncodedSpread ? perpId : txn.productId;
            perpSizeIncrement = IOffchainExchange(
                IEndpoint(getEndpoint()).getOffchainExchange()
            ).getSizeIncrement(productId);
        }

        if (isPerp || txn.isEncodedSpread) {
            require(
                txn.amount % perpSizeIncrement == 0,
                ERR_INVALID_LIQUIDATION_AMOUNT
            );
        }

        if (!isPerp || spotId != 0) {
            if (spotEngine.getRisk(spotId).longWeightInitialX18 == 0) {
                revert(ERR_INVALID_PRODUCT);
            }
        }

        int128 originalBalance;
        if (spotId == 0) {
            // risk of this product is not involved in spread netting
            require(!txn.isEncodedSpread, ERR_INVALID_LIQUIDATION_PARAMS);
            originalBalance = perpEngine
                .getBalance(perpId, txn.liquidatee)
                .amount;
        } else if (perpId == 0) {
            // risk of this product is not involved in spread netting
            require(!txn.isEncodedSpread, ERR_INVALID_LIQUIDATION_PARAMS);
            originalBalance = spotEngine
                .getBalance(spotId, txn.liquidatee)
                .amount;
        } else {
            int128 spotAmount = spotEngine
                .getBalance(spotId, txn.liquidatee)
                .amount;
            int128 perpAmount = perpEngine
                .getBalance(perpId, txn.liquidatee)
                .amount;
            int128 basisAmount = 0;

            if ((spotAmount > 0) != (perpAmount > 0)) {
                if (spotAmount > 0) {
                    basisAmount = MathHelper.min(spotAmount, -perpAmount);
                } else {
                    basisAmount = MathHelper.max(spotAmount, -perpAmount);

                    // increase basis amount based on how much spot can be liquidated
                    // (basis amount is negative here)
                    // if the liquidatee isn't able to buy back the entire basis using
                    // the quote balance, then we have to liquidate the spot and the perp
                    // separately
                    (int128 liquidationPrice, , ) = getSpreadLiqPriceX18(
                        spotId,
                        perpId,
                        basisAmount
                    );
                    (, ISpotEngine.Balance memory quoteBalance) = spotEngine
                        .getStateAndBalance(QUOTE_PRODUCT_ID, txn.liquidatee);
                    // this is the cross account
                    int128 maximumLiquidatable = (quoteBalance.amount +
                        insurance).div(liquidationPrice);
                    maximumLiquidatable = MathHelper.max(
                        maximumLiquidatable + 1,
                        0
                    );
                    basisAmount = MathHelper.max(
                        -maximumLiquidatable,
                        basisAmount
                    );
                }
                basisAmount -= basisAmount % perpSizeIncrement;
            }
            spotAmount -= basisAmount;
            perpAmount += basisAmount;

            if (txn.isEncodedSpread) {
                originalBalance = basisAmount;
            } else if (isPerp) {
                originalBalance = perpAmount;
            } else {
                originalBalance = spotAmount;
            }
        }

        require(
            originalBalance != 0 && txn.amount != 0,
            ERR_NOT_LIQUIDATABLE_AMT
        );
        if (txn.amount > 0) {
            require(originalBalance >= txn.amount, ERR_NOT_LIQUIDATABLE_AMT);
        } else {
            if (!isPerp && !txn.isEncodedSpread) {
                // this is a spot liquidation --
                // check if liquidatee has enough quote to buyback spot liability
                (int128 liquidationPrice, ) = getLiqPriceX18(
                    txn.productId,
                    txn.amount
                );

                int128 maximumLiquidatable;
                {
                    (, ISpotEngine.Balance memory quoteBalance) = spotEngine
                        .getStateAndBalance(QUOTE_PRODUCT_ID, txn.liquidatee);
                    maximumLiquidatable = quoteBalance.amount;
                }
                maximumLiquidatable += insurance;
                maximumLiquidatable = maximumLiquidatable.div(liquidationPrice);
                maximumLiquidatable = MathHelper.max(
                    maximumLiquidatable + 1,
                    0
                );

                require(
                    -txn.amount <= maximumLiquidatable,
                    ERR_LIQUIDATED_TOO_MUCH
                );
            }

            require(originalBalance <= txn.amount, ERR_NOT_LIQUIDATABLE_AMT);
        }
    }

    function _assertCanLiquidateLiability(
        IEndpoint.LiquidateSubaccount calldata txn,
        ISpotEngine spotEngine,
        IPerpEngine perpEngine
    ) internal view {
        // ensure:
        // 1. no positive spot balances
        // 2. no perp balance that aren't part of a spread liability
        uint256 clearedPerpIds = 0;
        uint256 clearedSpotIds = 0;
        uint256 _spreads = spreads;
        while (_spreads > 0) {
            uint32 _spotId = uint32(_spreads & 0xFF);
            _spreads >>= 8;
            uint32 _perpId = uint32(_spreads & 0xFF);
            _spreads >>= 8;

            ISpotEngine.Balance memory spotBalance = spotEngine.getBalance(
                _spotId,
                txn.liquidatee
            );
            require(spotBalance.amount <= 0, ERR_NOT_LIQUIDATABLE_LIABILITIES);
            clearedSpotIds |= 1 << _spotId;
            IPerpEngine.Balance memory perpBalance = perpEngine.getBalance(
                _perpId,
                txn.liquidatee
            );
            // either perp amount is 0 or it is positive and it is part of a spread
            if (perpBalance.amount >= 0) {
                if (perpBalance.amount > 0) {
                    require(
                        spotBalance.amount < 0 &&
                            spotBalance.amount.abs() >=
                            perpBalance.amount.abs(),
                        ERR_NOT_LIQUIDATABLE_LIABILITIES
                    );
                }
                clearedPerpIds |= 1 << _perpId;
            } else {
                revert(ERR_NOT_LIQUIDATABLE_LIABILITIES);
            }
        }

        uint32[] memory spotIds = spotEngine.getProductIds();
        uint32[] memory perpIds = perpEngine.getProductIds();
        require(spotIds[0] == QUOTE_PRODUCT_ID);
        for (uint32 i = 1; i < spotIds.length; ++i) {
            uint32 spotId = spotIds[i];
            if ((clearedSpotIds & (1 << spotId)) == 0) {
                if (spotEngine.getRisk(spotId).longWeightInitialX18 == 0) {
                    continue;
                }
                ISpotEngine.Balance memory balance = spotEngine.getBalance(
                    spotId,
                    txn.liquidatee
                );
                require(balance.amount <= 0, ERR_NOT_LIQUIDATABLE_LIABILITIES);
            }
        }
        for (uint32 i = 0; i < perpIds.length; ++i) {
            uint32 perpId = perpIds[i];
            if ((clearedPerpIds & (1 << perpId)) == 0) {
                IPerpEngine.Balance memory balance = perpEngine.getBalance(
                    perpId,
                    txn.liquidatee
                );
                require(balance.amount == 0, ERR_NOT_LIQUIDATABLE_LIABILITIES);
            }
        }
    }

    function _settlePnlAgainstLiquidator(
        IEndpoint.LiquidateSubaccount calldata txn,
        uint32 perpId,
        int128 pnl,
        ISpotEngine spotEngine,
        IPerpEngine perpEngine
    ) internal {
        perpEngine.updateBalance(perpId, txn.liquidatee, 0, -pnl);
        perpEngine.updateBalance(perpId, txn.sender, 0, pnl);
        spotEngine.updateBalance(QUOTE_PRODUCT_ID, txn.liquidatee, pnl);
        spotEngine.updateBalance(QUOTE_PRODUCT_ID, txn.sender, -pnl);
    }

    struct FinalizeVars {
        uint32[] spotIds;
        uint32[] perpIds;
        int128 insurance;
        bool canLiquidateMore;
    }

    function _finalizeSubaccount(
        IEndpoint.LiquidateSubaccount calldata txn,
        ISpotEngine spotEngine,
        IPerpEngine perpEngine
    ) internal returns (bool) {
        if (txn.productId != type(uint32).max) {
            return false;
        }
        // check whether the subaccount can be finalized:
        // - all perps positions have closed
        // - all spread positions have closed
        // - all spot assets have closed
        // - all positive pnls have been settled

        // AP (rewrite) : the above really means only short spot
        // or unsettled neg pnl perps remaining

        FinalizeVars memory v;

        v.spotIds = spotEngine.getProductIds();
        v.perpIds = perpEngine.getProductIds();
        // - after settling all positive pnls, if (quote + insurance) is positive,
        //   all spot liabilities have closed

        require(v.spotIds[0] == 0);

        // all spot assets (except USDC) must be closed out
        for (uint32 i = 1; i < v.spotIds.length; ++i) {
            uint32 spotId = v.spotIds[i];
            if (spotEngine.getRisk(spotId).longWeightInitialX18 == 0) {
                continue;
            }
            (
                ,
                ISpotEngine.LpBalance memory lpBalance,
                ,
                ISpotEngine.Balance memory balance
            ) = spotEngine.getStatesAndBalances(spotId, txn.liquidatee);

            require(
                lpBalance.amount == 0 && balance.amount <= 0,
                ERR_NOT_FINALIZABLE_SUBACCOUNT
            );
        }

        for (uint32 i = 0; i < v.perpIds.length; ++i) {
            uint32 perpId = v.perpIds[i];
            (
                ,
                IPerpEngine.LpBalance memory lpBalance,
                ,
                IPerpEngine.Balance memory balance
            ) = perpEngine.getStatesAndBalances(perpId, txn.liquidatee);

            require(
                lpBalance.amount == 0 && balance.amount == 0,
                ERR_NOT_FINALIZABLE_SUBACCOUNT
            );

            if (balance.vQuoteBalance > 0) {
                _settlePnlAgainstLiquidator(
                    txn,
                    perpId,
                    balance.vQuoteBalance,
                    spotEngine,
                    perpEngine
                );
            }
        }

        (, ISpotEngine.Balance memory quoteBalance) = spotEngine
            .getStateAndBalance(QUOTE_PRODUCT_ID, txn.liquidatee);

        v.insurance = insurance;
        v.insurance -= lastLiquidationFees;
        v.canLiquidateMore = (quoteBalance.amount + v.insurance) > 0;

        // settle all negative pnl until quote balance becomes 0
        for (uint32 i = 0; i < v.perpIds.length; ++i) {
            uint32 perpId = v.perpIds[i];
            (, IPerpEngine.Balance memory balance) = perpEngine
                .getStateAndBalance(perpId, txn.liquidatee);
            require(balance.amount == 0, ERR_NOT_FINALIZABLE_SUBACCOUNT);
            if (balance.vQuoteBalance < 0 && quoteBalance.amount > 0) {
                int128 canSettle = MathHelper.max(
                    balance.vQuoteBalance,
                    -quoteBalance.amount
                );
                _settlePnlAgainstLiquidator(
                    txn,
                    perpId,
                    canSettle,
                    spotEngine,
                    perpEngine
                );
                quoteBalance.amount += canSettle;
            }
        }

        if (v.canLiquidateMore) {
            for (uint32 i = 1; i < v.spotIds.length; ++i) {
                uint32 spotId = v.spotIds[i];
                (, ISpotEngine.Balance memory balance) = spotEngine
                    .getStateAndBalance(spotId, txn.liquidatee);
                if (spotEngine.getRisk(spotId).longWeightInitialX18 == 0) {
                    continue;
                }
                require(balance.amount == 0, ERR_NOT_FINALIZABLE_SUBACCOUNT);
            }
        }

        v.insurance = perpEngine.socializeSubaccount(
            txn.liquidatee,
            v.insurance
        );

        // we can assure that quoteBalance must be non positive
        int128 insuranceCover = MathHelper.min(
            v.insurance,
            -quoteBalance.amount
        );
        if (insuranceCover > 0) {
            v.insurance -= insuranceCover;
            spotEngine.updateBalance(
                QUOTE_PRODUCT_ID,
                txn.liquidatee,
                insuranceCover
            );
        }
        if (v.insurance <= 0) {
            spotEngine.socializeSubaccount(txn.liquidatee);
        }
        v.insurance += lastLiquidationFees;
        insurance = v.insurance;
        return true;
    }

    function _decomposeLps(
        IEndpoint.LiquidateSubaccount calldata txn,
        ISpotEngine spotEngine,
        IPerpEngine perpEngine
    ) internal returns (bool) {
        insurance += spotEngine.decomposeLps(txn.liquidatee, txn.sender);
        insurance += perpEngine.decomposeLps(txn.liquidatee, txn.sender);
        return
            getHealthFromClearinghouse(
                txn.liquidatee,
                IProductEngine.HealthType.INITIAL
            ) >= 0;
    }

    function _settlePositivePerpPnl(
        IEndpoint.LiquidateSubaccount calldata txn,
        ISpotEngine spotEngine,
        IPerpEngine perpEngine
    ) internal {
        uint32[] memory productIds = perpEngine.getProductIds();
        for (uint32 i = 0; i < productIds.length; ++i) {
            uint32 productId = productIds[i];
            _settlePositivePerpPnl(txn, spotEngine, perpEngine, productId);
        }
    }

    function _isPerp(
        IEndpoint.LiquidateSubaccount calldata txn,
        IPerpEngine perpEngine
    ) internal view returns (bool) {
        return
            !txn.isEncodedSpread &&
            (address(productToEngine[txn.productId]) == address(perpEngine));
    }

    function _settlePositivePerpPnl(
        IEndpoint.LiquidateSubaccount calldata txn,
        ISpotEngine spotEngine,
        IPerpEngine perpEngine,
        uint32 productId
    ) internal {
        int128 positionPnl = perpEngine.getPositionPnl(
            productId,
            txn.liquidatee
        );
        if (positionPnl > 0) {
            _settlePnlAgainstLiquidator(
                txn,
                productId,
                positionPnl,
                spotEngine,
                perpEngine
            );
        }
    }

    // top down:
    // 1. can liquidate any spot asset
    // 2. can liquidate any perp
    // 3. can settle any positive perp PNL
    // 4. for short spot / spread (liab), requires:
    //    - no positive perp pnl
    //    - no long spot except USDC

    // 5.

    // 1. decompose LPs
    // 2. finalize if able
    //

    struct LiquidationVars {
        int128 liquidationPriceX18;
        int128 liquidationPayment;
        int128 oraclePriceX18;
        int128 oraclePriceX18Perp;
        int128 liquidationFees;
    }

    function _handleLiquidationPayment(
        IEndpoint.LiquidateSubaccount calldata txn,
        ISpotEngine spotEngine,
        IPerpEngine perpEngine
    ) internal {
        bool isPerp = _isPerp(txn, perpEngine);
        LiquidationVars memory v;

        if (txn.isEncodedSpread) {
            uint32 spotId = txn.productId & 0xFFFF;
            uint32 perpId = txn.productId >> 16;
            (
                v.liquidationPriceX18,
                v.oraclePriceX18,
                v.oraclePriceX18Perp
            ) = getSpreadLiqPriceX18(spotId, perpId, txn.amount);

            v.liquidationPayment = v.liquidationPriceX18.mul(txn.amount);

            v.liquidationFees = (v.oraclePriceX18 - v.liquidationPriceX18)
                .mul(LIQUIDATION_FEE_FRACTION)
                .mul(txn.amount);

            // transfer spot at the calculated liquidation price
            spotEngine.updateBalance(spotId, txn.liquidatee, -txn.amount);
            spotEngine.updateBalance(
                QUOTE_PRODUCT_ID,
                txn.liquidatee,
                v.liquidationPayment
            );
            spotEngine.updateBalance(spotId, txn.sender, txn.amount);
            spotEngine.updateBalance(
                QUOTE_PRODUCT_ID,
                txn.sender,
                -v.liquidationPayment - v.liquidationFees
            );

            v.liquidationPayment = v.oraclePriceX18Perp.mul(txn.amount);
            perpEngine.updateBalance(
                perpId,
                txn.liquidatee,
                txn.amount,
                -v.liquidationPayment
            );

            perpEngine.updateBalance(
                perpId,
                txn.sender,
                -txn.amount,
                v.liquidationPayment
            );

            if (txn.amount < 0) {
                insurance = spotEngine.updateQuoteFromInsurance(
                    txn.liquidatee,
                    insurance
                );
            }
        } else if (!isPerp) {
            // certain spot products that do not contribute to health
            // exist outside of the risk system and cannot be liquidated

            (v.liquidationPriceX18, v.oraclePriceX18) = getLiqPriceX18(
                txn.productId,
                txn.amount
            );

            v.liquidationPayment = v.liquidationPriceX18.mul(txn.amount);
            v.liquidationFees = (v.oraclePriceX18 - v.liquidationPriceX18)
                .mul(LIQUIDATION_FEE_FRACTION)
                .mul(txn.amount);

            spotEngine.updateBalance(
                txn.productId,
                txn.liquidatee,
                -txn.amount
            );

            spotEngine.updateBalance(
                QUOTE_PRODUCT_ID,
                txn.liquidatee,
                v.liquidationPayment
            );

            spotEngine.updateBalance(txn.productId, txn.sender, txn.amount);

            spotEngine.updateBalance(
                QUOTE_PRODUCT_ID,
                txn.sender,
                -v.liquidationPayment - v.liquidationFees
            );

            if (txn.amount < 0) {
                insurance = spotEngine.updateQuoteFromInsurance(
                    txn.liquidatee,
                    insurance
                );
            }
        } else {
            require(
                txn.productId != QUOTE_PRODUCT_ID,
                ERR_INVALID_LIQUIDATION_PARAMS
            );
            (v.liquidationPriceX18, v.oraclePriceX18) = getLiqPriceX18(
                txn.productId,
                txn.amount
            );
            v.liquidationPayment = v.liquidationPriceX18.mul(txn.amount);
            v.liquidationFees = (v.oraclePriceX18 - v.liquidationPriceX18)
                .mul(LIQUIDATION_FEE_FRACTION)
                .mul(txn.amount);
            perpEngine.updateBalance(
                txn.productId,
                txn.liquidatee,
                -txn.amount,
                v.liquidationPayment
            );

            perpEngine.updateBalance(
                txn.productId,
                txn.sender,
                txn.amount,
                -v.liquidationPayment - v.liquidationFees
            );
        }

        // it's ok to let initial health become 0
        require(!isAboveInitial(txn.liquidatee), ERR_LIQUIDATED_TOO_MUCH);
        require(
            txn.sender == V_ACCOUNT || !isUnderInitial(txn.sender),
            ERR_SUBACCT_HEALTH
        );

        insurance += v.liquidationFees;

        // if insurance is not enough for making a subaccount healthy, we should
        // - use all insurance to buy its liabilities, then
        // - socialize the subaccount

        // however, after the first step, insurance funds will be refilled a little bit
        // which blocks the second step, so we keep the fees of the last liquidation and
        // do not use this part in socialization to unblock it.
        lastLiquidationFees = v.liquidationFees;

        emit Liquidation(
            txn.sender,
            txn.liquidatee,
            // 0 -> spread, 1 -> spot, 2 -> perp
            txn.productId,
            txn.isEncodedSpread,
            txn.amount, // amount that was liquidated
            // this is the amount of product transferred from liquidatee
            // to liquidator; this and the following field will have the same sign
            // if spread, one unit represents one long spot and one short perp
            // i.e. if amount == -1, it means a short spot and a long perp was liquidated
            v.liquidationPayment // add actual liquidatee quoteDelta
            // meaning there was a payment of liquidationPayment
            // from liquidator to liquidatee for the liquidated products
        );
    }

    function liquidateSubaccountImpl(IEndpoint.LiquidateSubaccount calldata txn)
        external
    {
        require(!RiskHelper.isIsolatedSubaccount(txn.sender), ERR_UNAUTHORIZED);
        require(txn.sender != txn.liquidatee, ERR_UNAUTHORIZED);
        require(isUnderMaintenance(txn.liquidatee), ERR_NOT_LIQUIDATABLE);
        require(
            txn.liquidatee != X_ACCOUNT && txn.liquidatee != V_ACCOUNT,
            ERR_NOT_LIQUIDATABLE
        );
        require(
            txn.productId != QUOTE_PRODUCT_ID,
            ERR_INVALID_LIQUIDATION_PARAMS
        );

        ISpotEngine spotEngine = ISpotEngine(
            address(engineByType[IProductEngine.EngineType.SPOT])
        );
        IPerpEngine perpEngine = IPerpEngine(
            address(engineByType[IProductEngine.EngineType.PERP])
        );

        if (_finalizeSubaccount(txn, spotEngine, perpEngine)) {
            if (RiskHelper.isIsolatedSubaccount(txn.liquidatee)) {
                IOffchainExchange(
                    IEndpoint(getEndpoint()).getOffchainExchange()
                ).tryCloseIsolatedSubaccount(txn.liquidatee);
            }
            return;
        }

        if (_decomposeLps(txn, spotEngine, perpEngine)) {
            return;
        }

        bool isPerp = _isPerp(txn, perpEngine);
        bool isLiability = (txn.amount < 0) && !isPerp;

        if (isLiability) {
            _assertCanLiquidateLiability(txn, spotEngine, perpEngine);
            _settlePositivePerpPnl(txn, spotEngine, perpEngine);
        }

        _assertLiquidationAmount(txn, spotEngine, perpEngine);

        // beyond this point, we can be sure that we can liquidate the entire
        // liquidation amount knowing that the insurance fund will remain solvent
        // subsequently we can just blast the remainder of the liquidation and
        // cover the quote balance from the insurance fund at the end
        _handleLiquidationPayment(txn, spotEngine, perpEngine);
    }
}
