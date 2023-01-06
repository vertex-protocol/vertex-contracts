// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "prb-math/contracts/PRBMathSD59x18.sol";
import "hardhat/console.sol";

import "./common/Constants.sol";
import "./interfaces/clearinghouse/IClearinghouse.sol";
import "./interfaces/engine/IProductEngine.sol";
import "./interfaces/engine/ISpotEngine.sol";
import "./interfaces/IOffchainBook.sol";
import "./libraries/KeyHelper.sol";
import "./libraries/ERC20Helper.sol";
import "./libraries/MathHelper.sol";
import "./interfaces/engine/IPerpEngine.sol";
import "./EndpointGated.sol";
import "./interfaces/IEndpoint.sol";
import "./ClearinghouseRisk.sol";

contract Clearinghouse is ClearinghouseRisk, IClearinghouse {
    using PRBMathSD59x18 for int256;
    using ERC20Helper for IERC20Base;

    // Each clearinghouse has a quote ERC20
    address private quote;

    // fee calculator
    address private fees;

    // Number of products registered across all engines
    uint32 private numProducts;

    // product ID -> engine address
    mapping(uint32 => IProductEngine) internal productToEngine;
    // Type to engine address
    mapping(IProductEngine.EngineType => IProductEngine) engineByType;
    // Supported engine types
    IProductEngine.EngineType[] private supportedEngines;

    // sender addr -> subaccount id
    mapping(address => mapping(string => uint64)) public subaccounts;
    mapping(uint64 => address) public subaccountOwner;
    mapping(uint64 => string) public subaccountNames;

    uint64 private subaccountCount;
    // insurance stuff, consider making it its own subaccount later
    int256 public insuranceX18;

    function initialize(
        address _endpoint,
        address _quote,
        address _fees
    ) external initializer {
        __Ownable_init();
        setEndpoint(_endpoint);
        quote = _quote;
        fees = _fees;
        numProducts = 1;

        // fees account will be subaccount max int
        subaccounts[msg.sender]["fees"] = FEES_SUBACCOUNT_ID;
        subaccountOwner[FEES_SUBACCOUNT_ID] = msg.sender;

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

    function getEngineByType(
        IProductEngine.EngineType engineType
    ) external view returns (address) {
        return address(engineByType[engineType]);
    }

    function getEngineByProduct(
        uint32 productId
    ) external view returns (address) {
        return address(productToEngine[productId]);
    }

    function getOrderbook(uint32 productId) external view returns (address) {
        return address(productToEngine[productId].getOrderbook(productId));
    }

    function getNumProducts() external view returns (uint32) {
        return numProducts;
    }

    function getNumSubaccounts() external view returns (uint64) {
        return subaccountCount;
    }

    function getSubaccountId(
        address owner,
        string memory name
    ) external view returns (uint64) {
        return subaccounts[owner][name];
    }

    function getSubaccountOwner(
        uint64 subaccountId
    ) external view returns (address) {
        return subaccountOwner[subaccountId];
    }

    function getInsuranceX18() external view returns (int256) {
        return insuranceX18;
    }

    /// @notice grab total subaccount health
    function getHealthX18(
        uint64 subaccountId,
        IProductEngine.HealthType healthType
    ) public view returns (int256 healthX18) {
        ISpotEngine spotEngine = ISpotEngine(
            address(engineByType[IProductEngine.EngineType.SPOT])
        );
        IPerpEngine perpEngine = IPerpEngine(
            address(engineByType[IProductEngine.EngineType.PERP])
        );

        {
            (, ISpotEngine.Balance memory balance) = spotEngine
                .getStateAndBalance(QUOTE_PRODUCT_ID, subaccountId);
            healthX18 = balance.amountX18;
        }

        for (uint32 i = 0; i <= maxHealthGroup; ++i) {
            HealthGroup memory group = healthGroups[i];
            HealthVars memory healthVars;

            if (group.spotId != 0) {
                (
                    ISpotEngine.LpState memory lpState,
                    ISpotEngine.LpBalance memory lpBalance,
                    ISpotEngine.State memory state,
                    ISpotEngine.Balance memory balance
                ) = spotEngine.getStatesAndBalances(group.spotId, subaccountId);

                healthVars.spotPriceX18 = getOraclePriceX18(group.spotId);
                int256 ratioX18 = lpBalance.amountX18 == 0
                    ? int256(0)
                    : lpBalance.amountX18.div(lpState.supply.fromInt());

                (int256 ammBaseX18, int256 ammQuoteX18) = MathHelper
                    .ammEquilibrium(
                        lpState.base.amountX18,
                        lpState.quote.amountX18,
                        healthVars.spotPriceX18
                    );

                healthX18 += ammQuoteX18.mul(ratioX18);
                healthVars.spotInLpAmountX18 = ammBaseX18.mul(ratioX18);
                healthVars.spotAmountX18 = balance.amountX18;
                healthVars.spotRisk = getRisk(group.spotId);
            }
            if (group.perpId != 0) {
                (
                    IPerpEngine.LpState memory lpState,
                    IPerpEngine.LpBalance memory lpBalance,
                    IPerpEngine.State memory state,
                    IPerpEngine.Balance memory balance
                ) = perpEngine.getStatesAndBalances(group.perpId, subaccountId);
                healthVars.perpPriceX18 = getOraclePriceX18(group.perpId);
                int256 ratioX18 = lpBalance.amountX18 == 0
                    ? int256(0)
                    : lpBalance.amountX18.div(lpState.supply.fromInt());

                (int256 ammBaseX18, int256 ammQuoteX18) = MathHelper
                    .ammEquilibrium(
                        lpState.base.fromInt(),
                        lpState.quote.fromInt(),
                        healthVars.perpPriceX18
                    );

                healthX18 +=
                    ammQuoteX18.mul(ratioX18) +
                    balance.vQuoteBalanceX18;
                healthVars.perpInLpAmountX18 = ammBaseX18.mul(ratioX18);
                healthVars.perpAmountX18 = balance.amountX18;
                healthVars.perpRisk = getRisk(group.perpId);

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
            }

            // risk for the basis trade, discounted
            if (healthVars.basisAmountX18 != 0) {
                // add the actual value of the basis (PNL)
                healthX18 += (healthVars.spotPriceX18 - healthVars.perpPriceX18)
                    .mul(healthVars.basisAmountX18);

                int256 posAmountX18 = MathHelper.abs(healthVars.basisAmountX18);

                // compute a penalty% on the notional size of the basis trade
                // this is equivalent to a long weight, i.e. long weight 0.95 == 0.05 penalty
                // we take the square of the penalties on the spot and the perp positions
                healthX18 -= RiskHelper
                    ._getSpreadPenaltyX18(
                        healthVars.spotRisk,
                        healthVars.perpRisk,
                        posAmountX18,
                        healthType
                    )
                    .mul(posAmountX18)
                    .mul(healthVars.spotPriceX18 + healthVars.perpPriceX18);
            }

            // apply risk for spot and perp positions
            int256 combinedSpotX18 = healthVars.spotAmountX18 +
                healthVars.spotInLpAmountX18;
            healthX18 += RiskHelper
                ._getWeightX18(healthVars.spotRisk, combinedSpotX18, healthType)
                .mul(combinedSpotX18)
                .mul(healthVars.spotPriceX18);

            int256 combinedPerpX18 = healthVars.perpAmountX18 +
                healthVars.perpInLpAmountX18;
            healthX18 += RiskHelper
                ._getWeightX18(healthVars.perpRisk, combinedPerpX18, healthType)
                .mul(combinedPerpX18)
                .mul(healthVars.perpPriceX18);

            // apply penalties on amount in LPs
            healthX18 -= (ONE -
                RiskHelper._getWeightX18(
                    healthVars.spotRisk,
                    healthVars.spotInLpAmountX18,
                    healthType
                )).mul(healthVars.spotInLpAmountX18).mul(
                    healthVars.spotPriceX18
                );

            healthX18 -= (ONE -
                RiskHelper._getWeightX18(
                    healthVars.perpRisk,
                    healthVars.perpInLpAmountX18,
                    healthType
                )).mul(healthVars.perpInLpAmountX18).mul(
                    healthVars.perpPriceX18
                );
        }
    }

    /**
     * Actions
     */

    function addEngine(
        address engine,
        IProductEngine.EngineType engineType
    ) external onlyOwner {
        require(address(engineByType[engineType]) == address(0));
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
            fees
        );
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

        productId = numProducts++;
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
        uint256 amount
    ) internal virtual {
        token.safeTransferFrom(from, address(this), amount);
    }

    function depositCollateral(
        IEndpoint.DepositCollateral calldata txn
    ) external virtual onlyEndpoint {
        uint64 subaccountId = _loadSubaccount(txn.sender, txn.subaccountName);

        int256 amountRealized = int256(txn.amount);

        IProductEngine.ProductDelta[]
            memory deltas = new IProductEngine.ProductDelta[](1);

        deltas[0] = IProductEngine.ProductDelta({
            productId: txn.productId,
            subaccountId: subaccountId,
            amountDeltaX18: amountRealized.fromInt(),
            vQuoteDeltaX18: 0
        });
        ISpotEngine spotEngine = ISpotEngine(
            address(engineByType[IProductEngine.EngineType.SPOT])
        );
        spotEngine.applyDeltas(deltas);
        IERC20Base token = IERC20Base(
            spotEngine.getConfig(txn.productId).token
        );
        // transfer from the endpoint
        handleDepositTransfer(token, msg.sender, uint256(txn.amount));
        emit ModifyCollateral(amountRealized, subaccountId, txn.productId);
    }

    /// @notice control insurance balance, only callable by owner
    function depositInsurance(
        IEndpoint.DepositInsurance calldata txn
    ) external virtual onlyEndpoint {
        int256 amountX18 = int256(txn.amount);
        insuranceX18 += amountX18.fromInt();
        // facilitate transfer
        handleDepositTransfer(
            IERC20Base(quote),
            msg.sender,
            uint256(txn.amount)
        );
    }

    function handleWithdrawTransfer(
        IERC20Base token,
        address to,
        uint256 amount
    ) internal virtual {
        token.safeTransfer(to, amount);
    }

    function withdrawCollateral(
        IEndpoint.WithdrawCollateral calldata txn
    ) external virtual onlyEndpoint {
        uint64 subaccountId = _loadSubaccount(txn.sender, txn.subaccountName);

        int256 amountRealized = -int256(txn.amount);

        IProductEngine.ProductDelta[]
            memory deltas = new IProductEngine.ProductDelta[](1);

        deltas[0] = IProductEngine.ProductDelta({
            productId: txn.productId,
            subaccountId: subaccountId,
            amountDeltaX18: amountRealized.fromInt(),
            vQuoteDeltaX18: 0
        });

        ISpotEngine spotEngine = ISpotEngine(
            address(engineByType[IProductEngine.EngineType.SPOT])
        );
        spotEngine.applyDeltas(deltas);
        require(!_isUnderInitial(subaccountId), ERR_SUBACCT_HEALTH);
        IERC20Base token = IERC20Base(
            spotEngine.getConfig(txn.productId).token
        );
        handleWithdrawTransfer(token, txn.sender, txn.amount);
        emit ModifyCollateral(amountRealized, subaccountId, txn.productId);
    }

    function mintLp(
        IEndpoint.MintLp calldata txn
    ) external virtual onlyEndpoint {
        uint64 subaccountId = _loadSubaccount(txn.sender, txn.subaccountName);
        productToEngine[txn.productId].mintLp(
            txn.productId,
            subaccountId,
            int256(txn.amountBase).fromInt(),
            int256(txn.quoteAmountLow).fromInt(),
            int256(txn.quoteAmountHigh).fromInt()
        );
        require(!_isUnderInitial(subaccountId), ERR_SUBACCT_HEALTH);
    }

    function burnLp(
        IEndpoint.BurnLp calldata txn
    ) external virtual onlyEndpoint {
        uint64 subaccountId = _loadSubaccount(txn.sender, txn.subaccountName);
        productToEngine[txn.productId].burnLp(
            txn.productId,
            subaccountId,
            int256(txn.amount).fromInt()
        );
    }

    function _settlePnl(uint64 subaccountId) internal {
        // TODO: if this subaccount is in liquidation
        // then do not settle negative perp PNL into USDC
        IPerpEngine perpEngine = IPerpEngine(
            address(engineByType[IProductEngine.EngineType.PERP])
        );
        IProductEngine.ProductDelta[]
            memory deltas = new IProductEngine.ProductDelta[](1);

        int256 amountSettledX18 = perpEngine.settlePnl(subaccountId);
        deltas[0] = IProductEngine.ProductDelta({
            productId: QUOTE_PRODUCT_ID,
            subaccountId: subaccountId,
            amountDeltaX18: amountSettledX18,
            vQuoteDeltaX18: 0
        });

        ISpotEngine spotEngine = ISpotEngine(
            address(engineByType[IProductEngine.EngineType.SPOT])
        );
        spotEngine.applyDeltas(deltas);
    }

    function settlePnl(IEndpoint.SettlePnl calldata txn) external onlyEndpoint {
        for (uint256 i = 0; i < txn.subaccountIds.length; ++i) {
            _settlePnl(txn.subaccountIds[i]);
        }
    }

    /**
     * Internal
     */

    function _loadSubaccount(
        address from,
        string calldata name
    ) internal returns (uint64) {
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
        return
            getHealthX18(subaccountId, IProductEngine.HealthType.INITIAL) < 0;
    }

    function _isUnderMaintenance(
        uint64 subaccountId
    ) internal view returns (bool) {
        // Weighted maintenance health < 0
        return
            getHealthX18(subaccountId, IProductEngine.HealthType.MAINTENANCE) <
            0;
    }

    struct HealthGroupSummary {
        int256 perpAmountX18;
        int256 perpVQuoteX18;
        int256 perpPriceX18;
        int256 spotAmountX18;
        int256 spotPriceX18;
        int256 basisAmountX18;
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
            summary.spotAmountX18 = balance.amountX18;
            summary.spotPriceX18 = getOraclePriceX18(group.spotId);
        }

        if (group.perpId != 0) {
            (, IPerpEngine.Balance memory balance) = perpEngine
                .getStateAndBalance(group.perpId, subaccountId);
            summary.perpAmountX18 = balance.amountX18;
            summary.perpVQuoteX18 = balance.vQuoteBalanceX18;
            summary.perpPriceX18 = getOraclePriceX18(group.perpId);
        }

        if ((summary.spotAmountX18 > 0) != (summary.perpAmountX18 > 0)) {
            if (summary.spotAmountX18 > 0) {
                summary.basisAmountX18 = MathHelper.min(
                    summary.spotAmountX18,
                    -summary.perpAmountX18
                );
            } else {
                summary.basisAmountX18 = MathHelper.max(
                    summary.spotAmountX18,
                    -summary.perpAmountX18
                );
            }
            summary.spotAmountX18 -= summary.basisAmountX18;
            summary.perpAmountX18 += summary.basisAmountX18;
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
        for (uint32 i = 0; i < maxHealthGroup; ++i) {
            HealthGroupSummary memory summary = describeHealthGroup(
                spotEngine,
                perpEngine,
                i,
                subaccountId
            );
            // long spot and long spreads are assets and should
            // be liquidated first
            if (summary.spotAmountX18 > 0 || summary.basisAmountX18 > 0) {
                return LiquidationStatus.CannotLiquidateLiabilities;
            }

            canSocialize = canSocialize && (summary.basisAmountX18 != 0);

            // perp positions (outside of spreads) should be completely
            // closed before we can start liquidating liabilities

            // however we could potentially still have a closed perp position
            // with a positive vQuote balance, in which case the vQuote balance
            // should be settled into USDC first, since it would be an asset
            // note this vQuote balance criteria does not interfere with spreads;
            // the only spreads remaining at this point are short spreads
            // which are short spot and long perp. long perp should always
            // have negative vQuoteX18 after settlement, so this will
            // not trigger on a short spread
            if (summary.perpVQuoteX18 > 0 || summary.perpAmountX18 != 0) {
                return LiquidationStatus.CannotLiquidateLiabilities;
            }
        }
        return
            (canSocialize)
                ? LiquidationStatus.CanSocialize
                : LiquidationStatus.CannotSocialize;
    }

    function assertLiquidationAmount(
        int256 originalBalanceX18,
        int256 liquidationAmountX18
    ) internal pure {
        require(
            (originalBalanceX18 != 0 && liquidationAmountX18 != 0) &&
                ((liquidationAmountX18 > 0 &&
                    originalBalanceX18 >= liquidationAmountX18 &&
                    originalBalanceX18 > 0) ||
                    (liquidationAmountX18 <= 0 &&
                        originalBalanceX18 <= liquidationAmountX18 &&
                        originalBalanceX18 < 0)),
            ERR_NOT_LIQUIDATABLE_AMT
        );
    }

    struct LiquidationVars {
        int256 liquidationPriceX18;
        int256 excessPerpToLiquidateX18;
        int256 liquidationPaymentX18;
        int256 insuranceCoverX18;
    }

    function liquidateSubaccount(
        IEndpoint.LiquidateSubaccount calldata txn
    ) external onlyEndpoint {
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
            getHealthX18(txn.liquidateeId, IProductEngine.HealthType.INITIAL) >=
            0
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
        int256 amountToLiquidateX18 = PRBMathSD59x18.fromInt(txn.amount);
        LiquidationVars memory vars;

        // TODO: transfer some premium to insurance fund
        if (txn.mode == uint8(IEndpoint.LiquidationMode.SPREAD)) {
            assertLiquidationAmount(
                summary.basisAmountX18,
                amountToLiquidateX18
            );
            isLiability = summary.basisAmountX18 < 0;

            HealthGroup memory healthGroup = healthGroups[txn.healthGroup];

            vars.liquidationPriceX18 = getSpreadLiqPriceX18(
                healthGroup,
                amountToLiquidateX18
            );

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

                int256 maximumLiquidatableX18 = MathHelper.max(
                    (quoteBalance.amountX18 + insuranceX18).div(
                        vars.liquidationPriceX18
                    ),
                    0
                );

                vars.excessPerpToLiquidateX18 =
                    MathHelper.max(
                        amountToLiquidateX18,
                        -maximumLiquidatableX18
                    ) -
                    amountToLiquidateX18;
                amountToLiquidateX18 += vars.excessPerpToLiquidateX18;
                vars.liquidationPaymentX18 = vars.liquidationPriceX18.mul(
                    amountToLiquidateX18
                );
                vars.insuranceCoverX18 = MathHelper.min(
                    insuranceX18,
                    MathHelper.max(
                        0,
                        -vars.liquidationPaymentX18 - quoteBalance.amountX18
                    )
                );
            } else {
                vars.liquidationPaymentX18 = vars.liquidationPriceX18.mul(
                    amountToLiquidateX18
                );
            }

            IProductEngine.ProductDelta[]
                memory deltas = new IProductEngine.ProductDelta[](4);
            deltas[0] = IProductEngine.ProductDelta({
                productId: healthGroup.spotId,
                subaccountId: txn.liquidateeId,
                amountDeltaX18: -amountToLiquidateX18,
                vQuoteDeltaX18: vars.liquidationPaymentX18
            });
            deltas[1] = IProductEngine.ProductDelta({
                productId: healthGroup.spotId,
                subaccountId: liquidatorId,
                amountDeltaX18: amountToLiquidateX18,
                vQuoteDeltaX18: -vars.liquidationPaymentX18
            });
            deltas[2] = IProductEngine.ProductDelta({
                productId: QUOTE_PRODUCT_ID,
                subaccountId: txn.liquidateeId,
                amountDeltaX18: vars.liquidationPaymentX18 +
                    vars.insuranceCoverX18,
                vQuoteDeltaX18: 0
            });
            deltas[3] = IProductEngine.ProductDelta({
                productId: QUOTE_PRODUCT_ID,
                subaccountId: liquidatorId,
                amountDeltaX18: -vars.liquidationPaymentX18,
                vQuoteDeltaX18: 0
            });

            insuranceX18 -= vars.insuranceCoverX18;
            spotEngine.applyDeltas(deltas);

            // end spot liquidation copied block

            // write perp deltas
            // in spread liquidation, we do the liquidation payment
            // on top of liquidating the spot. for perp we simply
            // transfer the balances at 0 pnl
            // (ie. vQuoteAmount == amount * perpPrice)
            int256 perpQuoteDeltaX18 = amountToLiquidateX18.mul(
                getOraclePriceX18(healthGroup.perpId)
            );

            int256 excessPerpQuoteDeltaX18 = getLiqPriceX18(
                healthGroup.perpId,
                vars.excessPerpToLiquidateX18
            ).mul(vars.excessPerpToLiquidateX18);

            deltas = new IProductEngine.ProductDelta[](2);
            deltas[0] = IProductEngine.ProductDelta({
                productId: healthGroup.perpId,
                subaccountId: txn.liquidateeId,
                amountDeltaX18: amountToLiquidateX18 -
                    vars.excessPerpToLiquidateX18,
                vQuoteDeltaX18: -perpQuoteDeltaX18 + excessPerpQuoteDeltaX18
            });
            deltas[1] = IProductEngine.ProductDelta({
                productId: healthGroup.perpId,
                subaccountId: liquidatorId,
                amountDeltaX18: -amountToLiquidateX18 +
                    vars.excessPerpToLiquidateX18,
                vQuoteDeltaX18: perpQuoteDeltaX18 - excessPerpQuoteDeltaX18
            });
            perpEngine.applyDeltas(deltas);
        } else if (txn.mode == uint8(IEndpoint.LiquidationMode.SPOT)) {
            uint32 productId = healthGroups[txn.healthGroup].spotId;
            require(
                productId != QUOTE_PRODUCT_ID,
                ERR_INVALID_LIQUIDATION_PARAMS
            );
            assertLiquidationAmount(
                summary.spotAmountX18,
                amountToLiquidateX18
            );
            isLiability = summary.spotAmountX18 < 0;
            (, ISpotEngine.Balance memory quoteBalance) = spotEngine
                .getStateAndBalance(QUOTE_PRODUCT_ID, txn.liquidateeId);

            vars.liquidationPriceX18 = getLiqPriceX18(
                productId,
                amountToLiquidateX18
            );
            if (isLiability) {
                int256 maximumLiquidatableX18 = MathHelper.max(
                    (quoteBalance.amountX18 + insuranceX18).div(
                        vars.liquidationPriceX18
                    ),
                    0
                );
                amountToLiquidateX18 = MathHelper.max(
                    amountToLiquidateX18,
                    -maximumLiquidatableX18
                );
            }
            vars.liquidationPaymentX18 = vars.liquidationPriceX18.mul(
                amountToLiquidateX18
            );

            // quoteBalance.amountX18 + liquidationPayment18 + insuranceCoverX18 == 0
            vars.insuranceCoverX18 = (isLiability)
                ? MathHelper.min(
                    insuranceX18,
                    MathHelper.max(
                        0,
                        -vars.liquidationPaymentX18 - quoteBalance.amountX18
                    )
                )
                : int256(0);

            IProductEngine.ProductDelta[]
                memory deltas = new IProductEngine.ProductDelta[](4);
            deltas[0] = IProductEngine.ProductDelta({
                productId: productId,
                subaccountId: txn.liquidateeId,
                amountDeltaX18: -amountToLiquidateX18,
                vQuoteDeltaX18: vars.liquidationPaymentX18
            });
            deltas[1] = IProductEngine.ProductDelta({
                productId: productId,
                subaccountId: liquidatorId,
                amountDeltaX18: amountToLiquidateX18,
                vQuoteDeltaX18: -vars.liquidationPaymentX18
            });
            deltas[2] = IProductEngine.ProductDelta({
                productId: QUOTE_PRODUCT_ID,
                subaccountId: txn.liquidateeId,
                amountDeltaX18: vars.liquidationPaymentX18 +
                    vars.insuranceCoverX18,
                vQuoteDeltaX18: 0
            });
            deltas[3] = IProductEngine.ProductDelta({
                productId: QUOTE_PRODUCT_ID,
                subaccountId: liquidatorId,
                amountDeltaX18: -vars.liquidationPaymentX18,
                vQuoteDeltaX18: 0
            });

            insuranceX18 -= vars.insuranceCoverX18;
            spotEngine.applyDeltas(deltas);
        } else if (txn.mode == uint8(IEndpoint.LiquidationMode.PERP)) {
            uint32 productId = healthGroups[txn.healthGroup].perpId;
            require(
                productId != QUOTE_PRODUCT_ID,
                ERR_INVALID_LIQUIDATION_PARAMS
            );
            assertLiquidationAmount(
                summary.perpAmountX18,
                amountToLiquidateX18
            );
            vars.liquidationPaymentX18 = getLiqPriceX18(
                productId,
                amountToLiquidateX18
            ).mul(amountToLiquidateX18);

            IProductEngine.ProductDelta[]
                memory deltas = new IProductEngine.ProductDelta[](2);
            deltas[0] = IProductEngine.ProductDelta({
                productId: productId,
                subaccountId: txn.liquidateeId,
                amountDeltaX18: -amountToLiquidateX18,
                vQuoteDeltaX18: vars.liquidationPaymentX18
            });
            deltas[1] = IProductEngine.ProductDelta({
                productId: productId,
                subaccountId: liquidatorId,
                amountDeltaX18: amountToLiquidateX18,
                vQuoteDeltaX18: -vars.liquidationPaymentX18
            });
            perpEngine.applyDeltas(deltas);
        } else {
            revert(ERR_INVALID_LIQUIDATION_PARAMS);
        }

        require(_isUnderInitial(txn.liquidateeId), ERR_LIQUIDATED_TOO_MUCH);
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
                insuranceX18 = perpEngine.socializeSubaccount(
                    txn.liquidateeId,
                    insuranceX18
                );
                spotEngine.socializeSubaccount(txn.liquidateeId, insuranceX18);
            }
        }

        emit Liquidation(
            liquidatorId,
            txn.liquidateeId,
            // 0 -> spread, 1 -> spot, 2 -> perp
            txn.mode,
            txn.healthGroup,
            txn.amount.fromInt(), // amount that was liquidated
            // this is the amount of product transferred from liquidatee
            // to liquidator; this and the following field will have the same sign
            // if spread, one unit represents one long spot and one short perp
            // i.e. if amount == -1, it means a short spot and a long perp was liquidated
            vars.liquidationPaymentX18, // add actual liquidatee quoteDelta
            // meaning there was a payment of liquidationPaymentX18
            // from liquidator to liquidatee for the liquidated products
            vars.insuranceCoverX18
        );
    }
}
