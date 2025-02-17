// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "hardhat/console.sol";

import "./common/Constants.sol";
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
import "./Version.sol";

contract Clearinghouse is
    ClearinghouseRisk,
    ClearinghouseStorage,
    IClearinghouse,
    Version
{
    using MathSD21x18 for int128;
    using ERC20Helper for IERC20Base;

    function initialize(
        address _endpoint,
        address _quote,
        address _fees,
        address _clearinghouseLiq
    ) external initializer {
        __Ownable_init();
        setEndpoint(_endpoint);
        quote = _quote;
        fees = IFeeCalculator(_fees);
        clearinghouse = address(this);
        clearinghouseLiq = _clearinghouseLiq;
        numProducts = 1;

        // fees subaccount will be subaccount max int

        risks[QUOTE_PRODUCT_ID] = RiskStore({
            longWeightInitial: 1e9,
            shortWeightInitial: 1e9,
            longWeightMaintenance: 1e9,
            shortWeightMaintenance: 1e9,
            largePositionPenalty: 0
        });

        emit ClearinghouseInitialized(_endpoint, _quote, _fees);
    }

    /**
     * View
     */

    function getQuote() external view returns (address) {
        return quote;
    }

    function getSupportedEngines()
        external
        view
        returns (IProductEngine.EngineType[] memory)
    {
        return supportedEngines;
    }

    function getEngineByType(IProductEngine.EngineType engineType)
        external
        view
        returns (address)
    {
        return address(engineByType[engineType]);
    }

    function getEngineByProduct(uint32 productId)
        external
        view
        returns (address)
    {
        return address(productToEngine[productId]);
    }

    function getOrderbook(uint32 productId) external view returns (address) {
        return address(productToEngine[productId].getOrderbook(productId));
    }

    function getNumProducts() external view returns (uint32) {
        return numProducts;
    }

    function getInsurance() external view returns (int128) {
        return insurance;
    }

    /// @notice grab total subaccount health
    function getHealth(bytes32 subaccount, IProductEngine.HealthType healthType)
        public
        view
        returns (int128 health)
    {
        ISpotEngine spotEngine = ISpotEngine(
            address(engineByType[IProductEngine.EngineType.SPOT])
        );
        IPerpEngine perpEngine = IPerpEngine(
            address(engineByType[IProductEngine.EngineType.PERP])
        );

        {
            ISpotEngine.Balance memory balance = spotEngine.getBalance(
                QUOTE_PRODUCT_ID,
                subaccount
            );
            health = balance.amount;
        }

        for (uint32 i = 0; i <= maxHealthGroup; ++i) {
            HealthGroup memory group = healthGroups[i];
            HealthVars memory healthVars;
            healthVars.pricesX18 = getOraclePricesX18(i);

            if (
                group.spotId != 0 &&
                spotEngine.hasBalance(group.spotId, subaccount)
            ) {
                (
                    ISpotEngine.LpBalance memory lpBalance,
                    ISpotEngine.Balance memory balance
                ) = spotEngine.getBalances(group.spotId, subaccount);

                if (lpBalance.amount != 0) {
                    ISpotEngine.LpState memory lpState = spotEngine.getLpState(
                        group.spotId
                    );
                    (int128 ammBase, int128 ammQuote) = MathHelper
                        .ammEquilibrium(
                            lpState.base.amount,
                            lpState.quote.amount,
                            healthVars.pricesX18.spotPriceX18
                        );

                    health += ammQuote.mul(lpBalance.amount).div(
                        lpState.supply
                    );
                    healthVars.spotInLpAmount = ammBase
                        .mul(lpBalance.amount)
                        .div(lpState.supply);
                }

                healthVars.spotAmount = balance.amount;
                healthVars.spotRisk = getRisk(group.spotId);
            }
            if (
                group.perpId != 0 &&
                perpEngine.hasBalance(group.perpId, subaccount)
            ) {
                (
                    IPerpEngine.LpBalance memory lpBalance,
                    IPerpEngine.Balance memory balance
                ) = perpEngine.getBalances(group.perpId, subaccount);

                if (lpBalance.amount != 0) {
                    IPerpEngine.LpState memory lpState = perpEngine.getLpState(
                        group.perpId
                    );
                    (int128 ammBase, int128 ammQuote) = MathHelper
                        .ammEquilibrium(
                            lpState.base,
                            lpState.quote,
                            healthVars.pricesX18.perpPriceX18
                        );

                    health += ammQuote.mul(lpBalance.amount).div(
                        lpState.supply
                    );
                    healthVars.perpInLpAmount = ammBase
                        .mul(lpBalance.amount)
                        .div(lpState.supply);
                }

                health += balance.vQuoteBalance;
                healthVars.perpAmount = balance.amount;
                healthVars.perpRisk = getRisk(group.perpId);

                if (
                    (healthVars.spotAmount > 0) != (healthVars.perpAmount > 0)
                ) {
                    if (healthVars.spotAmount > 0) {
                        healthVars.basisAmount = MathHelper.min(
                            healthVars.spotAmount,
                            -healthVars.perpAmount
                        );
                    } else {
                        healthVars.basisAmount = MathHelper.max(
                            healthVars.spotAmount,
                            -healthVars.perpAmount
                        );
                    }
                    healthVars.spotAmount -= healthVars.basisAmount;
                    healthVars.perpAmount += healthVars.basisAmount;
                }
            }

            // risk for the basis trade, discounted
            if (healthVars.basisAmount != 0) {
                // add the actual value of the basis (PNL)
                health += (healthVars.pricesX18.spotPriceX18 -
                    healthVars.pricesX18.perpPriceX18).mul(
                        healthVars.basisAmount
                    );

                int128 posAmount = MathHelper.abs(healthVars.basisAmount);

                // compute a penalty% on the notional size of the basis trade
                // this is equivalent to a long weight, i.e. long weight 0.95 == 0.05 penalty
                // we take the square of the penalties on the spot and the perp positions
                health -= RiskHelper
                    ._getSpreadPenaltyX18(
                        healthVars.spotRisk,
                        healthVars.perpRisk,
                        posAmount,
                        healthType
                    )
                    .mul(posAmount)
                    .mul(
                        healthVars.pricesX18.spotPriceX18 +
                            healthVars.pricesX18.perpPriceX18
                    );
            }

            // apply risk for spot and perp positions
            int128 combinedSpot = healthVars.spotAmount +
                healthVars.spotInLpAmount;

            if (combinedSpot != 0) {
                health += RiskHelper
                    ._getWeightX18(
                        healthVars.spotRisk,
                        combinedSpot,
                        healthType
                    )
                    .mul(combinedSpot)
                    .mul(healthVars.pricesX18.spotPriceX18);
            }

            int128 combinedPerp = healthVars.perpAmount +
                healthVars.perpInLpAmount;

            if (combinedPerp != 0) {
                health += RiskHelper
                    ._getWeightX18(
                        healthVars.perpRisk,
                        combinedPerp,
                        healthType
                    )
                    .mul(combinedPerp)
                    .mul(healthVars.pricesX18.perpPriceX18);
            }

            if (healthVars.spotInLpAmount != 0) {
                // apply penalties on amount in LPs
                health -= (ONE -
                    RiskHelper._getWeightX18(
                        healthVars.spotRisk,
                        healthVars.spotInLpAmount,
                        healthType
                    )).mul(healthVars.spotInLpAmount).mul(
                        healthVars.pricesX18.spotPriceX18
                    );
            }

            if (healthVars.perpInLpAmount != 0) {
                health -= (ONE -
                    RiskHelper._getWeightX18(
                        healthVars.perpRisk,
                        healthVars.perpInLpAmount,
                        healthType
                    )).mul(healthVars.perpInLpAmount).mul(
                        healthVars.pricesX18.perpPriceX18
                    );
            }
        }
    }

    /**
     * Actions
     */

    function addEngine(address engine, IProductEngine.EngineType engineType)
        external
        onlyOwner
    {
        require(address(engineByType[engineType]) == address(0));
        require(engine != address(0));
        IProductEngine productEngine = IProductEngine(engine);
        // Register
        supportedEngines.push(engineType);
        engineByType[engineType] = productEngine;

        // add quote to product mapping
        if (engineType == IProductEngine.EngineType.SPOT) {
            productToEngine[QUOTE_PRODUCT_ID] = productEngine;
        }

        // Initialize engine
        productEngine.initialize(
            address(this),
            quote,
            getEndpoint(),
            owner(),
            address(fees)
        );
    }

    function modifyProductConfig(uint32 productId, RiskStore memory riskStore)
        external
    {
        IProductEngine engine = IProductEngine(msg.sender);
        IProductEngine.EngineType engineType = engine.getEngineType();
        require(
            address(engineByType[engineType]) == msg.sender,
            ERR_UNAUTHORIZED
        );
        risks[productId] = riskStore;
    }

    /// @notice registers product id and returns
    function registerProductForId(
        address book,
        RiskStore memory riskStore,
        uint32 healthGroup
    ) external returns (uint32 productId) {
        IProductEngine engine = IProductEngine(msg.sender);
        IProductEngine.EngineType engineType = engine.getEngineType();
        require(
            address(engineByType[engineType]) == msg.sender,
            ERR_UNAUTHORIZED
        );

        numProducts += 1;

        // So for a given productId except quote, its healthGroup
        // is (productId + 1) / 2
        productId = healthGroup * 2 + 1;
        if (engineType == IProductEngine.EngineType.PERP) {
            productId += 1;
        }
        risks[productId] = riskStore;

        require(
            (engineType == IProductEngine.EngineType.SPOT &&
                healthGroups[healthGroup].spotId == 0) ||
                (engineType == IProductEngine.EngineType.PERP &&
                    healthGroups[healthGroup].perpId == 0),
            ERR_ALREADY_REGISTERED
        );

        if (engineType == IProductEngine.EngineType.SPOT) {
            healthGroups[healthGroup].spotId = productId;
        } else {
            healthGroups[healthGroup].perpId = productId;
        }

        if (healthGroup > maxHealthGroup) {
            require(
                healthGroup == maxHealthGroup + 1,
                ERR_INVALID_HEALTH_GROUP
            );
            maxHealthGroup = healthGroup;
        }

        productToEngine[productId] = engine;
        IEndpoint(getEndpoint()).setBook(productId, book);
        return productId;
    }

    function handleDepositTransfer(
        IERC20Base token,
        address from,
        uint128 amount
    ) internal virtual {
        token.safeTransferFrom(from, address(this), uint256(amount));
    }

    function depositCollateral(IEndpoint.DepositCollateral calldata txn)
        external
        virtual
        onlyEndpoint
    {
        ISpotEngine spotEngine = ISpotEngine(
            address(engineByType[IProductEngine.EngineType.SPOT])
        );
        IERC20Base token = IERC20Base(
            spotEngine.getConfig(txn.productId).token
        );
        require(address(token) != address(0));
        // transfer from the endpoint
        handleDepositTransfer(token, msg.sender, uint128(txn.amount));

        require(token.decimals() <= MAX_DECIMALS);
        int256 multiplier = int256(10**(MAX_DECIMALS - token.decimals()));
        int128 amountRealized = int128(txn.amount) * int128(multiplier);

        IProductEngine.ProductDelta[]
            memory deltas = new IProductEngine.ProductDelta[](1);

        deltas[0] = IProductEngine.ProductDelta({
            productId: txn.productId,
            subaccount: txn.sender,
            amountDelta: amountRealized,
            vQuoteDelta: 0
        });

        spotEngine.applyDeltas(deltas);

        emit ModifyCollateral(amountRealized, txn.sender, txn.productId);
    }

    /// @notice control insurance balance, only callable by owner
    function depositInsurance(IEndpoint.DepositInsurance calldata txn)
        external
        virtual
        onlyEndpoint
    {
        IERC20Base token = IERC20Base(quote);
        int256 multiplier = int256(10**(MAX_DECIMALS - token.decimals()));
        int128 amount = int128(txn.amount) * int128(multiplier);

        insurance += amount;
        // facilitate transfer
        handleDepositTransfer(token, msg.sender, uint128(txn.amount));
    }

    function handleWithdrawTransfer(
        IERC20Base token,
        address to,
        uint128 amount
    ) internal virtual {
        token.safeTransfer(to, uint256(amount));
    }

    function withdrawCollateral(IEndpoint.WithdrawCollateral calldata txn)
        external
        virtual
        onlyEndpoint
    {
        ISpotEngine spotEngine = ISpotEngine(
            address(engineByType[IProductEngine.EngineType.SPOT])
        );
        IERC20Base token = IERC20Base(
            spotEngine.getConfig(txn.productId).token
        );
        require(address(token) != address(0));
        handleWithdrawTransfer(
            token,
            address(uint160(bytes20(txn.sender))),
            txn.amount
        );

        int256 multiplier = int256(10**(MAX_DECIMALS - token.decimals()));
        int128 amountRealized = -int128(txn.amount) * int128(multiplier);

        IProductEngine.ProductDelta[]
            memory deltas = new IProductEngine.ProductDelta[](1);

        deltas[0] = IProductEngine.ProductDelta({
            productId: txn.productId,
            subaccount: txn.sender,
            amountDelta: amountRealized,
            vQuoteDelta: 0
        });

        spotEngine.applyDeltas(deltas);
        require(!_isUnderInitial(txn.sender), ERR_SUBACCT_HEALTH);

        emit ModifyCollateral(amountRealized, txn.sender, txn.productId);
    }

    function mintLp(IEndpoint.MintLp calldata txn)
        external
        virtual
        onlyEndpoint
    {
        productToEngine[txn.productId].mintLp(
            txn.productId,
            txn.sender,
            int128(txn.amountBase),
            int128(txn.quoteAmountLow),
            int128(txn.quoteAmountHigh)
        );
        require(!_isUnderInitial(txn.sender), ERR_SUBACCT_HEALTH);
    }

    function burnLp(IEndpoint.BurnLp calldata txn)
        external
        virtual
        onlyEndpoint
    {
        productToEngine[txn.productId].burnLp(
            txn.productId,
            txn.sender,
            int128(txn.amount)
        );
    }

    function rebate(IEndpoint.Rebate calldata txn)
        external
        virtual
        onlyEndpoint
    {
        IProductEngine.ProductDelta[]
            memory deltas = IProductEngine.ProductDelta[](
                new IProductEngine.ProductDelta[](txn.subaccounts.length + 1)
            );
        int128 totalRebates = 0;
        for (uint128 i = 0; i < txn.subaccounts.length; ++i) {
            require(txn.amounts[i] >= 0);
            totalRebates += txn.amounts[i];
            deltas[i] = IProductEngine.ProductDelta({
                productId: QUOTE_PRODUCT_ID,
                subaccount: txn.subaccounts[i],
                amountDelta: txn.amounts[i],
                vQuoteDelta: 0
            });
        }
        deltas[txn.subaccounts.length] = IProductEngine.ProductDelta({
            productId: QUOTE_PRODUCT_ID,
            subaccount: FEES_ACCOUNT,
            amountDelta: -totalRebates,
            vQuoteDelta: 0
        });

        ISpotEngine spotEngine = ISpotEngine(
            address(engineByType[IProductEngine.EngineType.SPOT])
        );
        spotEngine.applyDeltas(deltas);
        require(!_isUnderInitial(FEES_ACCOUNT), ERR_SUBACCT_HEALTH);
    }

    function _settlePnl(bytes32 subaccount, uint256 productIds) internal {
        IPerpEngine perpEngine = IPerpEngine(
            address(engineByType[IProductEngine.EngineType.PERP])
        );
        IProductEngine.ProductDelta[]
            memory deltas = new IProductEngine.ProductDelta[](1);

        int128 amountSettled = perpEngine.settlePnl(subaccount, productIds);
        deltas[0] = IProductEngine.ProductDelta({
            productId: QUOTE_PRODUCT_ID,
            subaccount: subaccount,
            amountDelta: amountSettled,
            vQuoteDelta: 0
        });

        ISpotEngine spotEngine = ISpotEngine(
            address(engineByType[IProductEngine.EngineType.SPOT])
        );
        spotEngine.applyDeltas(deltas);
    }

    function settlePnl(IEndpoint.SettlePnl calldata txn) external onlyEndpoint {
        for (uint128 i = 0; i < txn.subaccounts.length; ++i) {
            _settlePnl(txn.subaccounts[i], txn.productIds[i]);
        }
    }

    function _isUnderInitial(bytes32 subaccount) public view returns (bool) {
        // Weighted initial health with limit orders < 0
        return getHealth(subaccount, IProductEngine.HealthType.INITIAL) < 0;
    }

    function _isAboveInitial(bytes32 subaccount) public view returns (bool) {
        // Weighted initial health with limit orders < 0
        return getHealth(subaccount, IProductEngine.HealthType.INITIAL) > 0;
    }

    function _isUnderMaintenance(bytes32 subaccount)
        internal
        view
        returns (bool)
    {
        // Weighted maintenance health < 0
        return getHealth(subaccount, IProductEngine.HealthType.MAINTENANCE) < 0;
    }

    function liquidateSubaccount(IEndpoint.LiquidateSubaccount calldata txn)
        external
        virtual
        onlyEndpoint
    {
        bytes4 liquidateSubaccountSelector = bytes4(
            keccak256(
                "liquidateSubaccountImpl((bytes32,bytes32,uint8,uint32,int128,uint64))"
            )
        );
        bytes memory liquidateSubaccountCall = abi.encodeWithSelector(
            liquidateSubaccountSelector,
            txn
        );
        (bool success, bytes memory result) = clearinghouseLiq.delegatecall(
            liquidateSubaccountCall
        );
        require(success, string(result));
    }

    function upgradeClearinghouseLiq(address _clearinghouseLiq)
        external
        onlyOwner
    {
        clearinghouseLiq = _clearinghouseLiq;
    }
}
