// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";

import "./common/Constants.sol";
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
import "./Version.sol";

interface IProxyManager {
    function getProxyManagerHelper() external view returns (address);
}

enum YieldMode {
    AUTOMATIC,
    DISABLED,
    CLAIMABLE
}

enum GasMode {
    VOID,
    CLAIMABLE
}

interface IBlastPoints {
    function configurePointsOperator(address operator) external;
}

interface IBlast {
    function configure(
        YieldMode _yield,
        GasMode gasMode,
        address governor
    ) external;
}

contract Clearinghouse is
    EndpointGated,
    ClearinghouseStorage,
    IClearinghouse,
    Version
{
    using MathSD21x18 for int128;
    using ERC20Helper for IERC20Base;

    function initialize(
        address _endpoint,
        address _quote,
        address _clearinghouseLiq,
        uint256 _spreads
    ) external initializer {
        __Ownable_init();
        setEndpoint(_endpoint);
        quote = _quote;
        clearinghouse = address(this);
        clearinghouseLiq = _clearinghouseLiq;
        spreads = _spreads;
        emit ClearinghouseInitialized(_endpoint, _quote);
    }

    /**
     * View
     */

    function getQuote() external view returns (address) {
        return quote;
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

        health = spotEngine.getHealthContribution(subaccount, healthType);
        // min health means that it is attempting to borrow a spot that exists outside
        // of the risk system -- return min health to error out this action
        if (health == (type(int128).min)) {
            return health;
        }

        uint256 _spreads = spreads;
        while (_spreads != 0) {
            uint32 _spotId = uint32(_spreads & 0xFF);
            _spreads >>= 8;
            uint32 _perpId = uint32(_spreads & 0xFF);
            _spreads >>= 8;

            IProductEngine.CoreRisk memory perpCoreRisk = perpEngine
                .getCoreRisk(subaccount, _perpId, healthType);

            if (perpCoreRisk.amount == 0) {
                continue;
            }

            IProductEngine.CoreRisk memory spotCoreRisk = spotEngine
                .getCoreRisk(subaccount, _spotId, healthType);

            if (
                (spotCoreRisk.amount == 0) ||
                ((spotCoreRisk.amount > 0) == (perpCoreRisk.amount > 0))
            ) {
                continue;
            }

            int128 basisAmount;
            if (spotCoreRisk.amount > 0) {
                basisAmount = MathHelper.min(
                    spotCoreRisk.amount,
                    -perpCoreRisk.amount
                );
            } else {
                basisAmount = -MathHelper.max(
                    spotCoreRisk.amount,
                    -perpCoreRisk.amount
                );
            }

            int128 existingPenalty = (spotCoreRisk.longWeight +
                perpCoreRisk.longWeight) / 2;
            int128 spreadPenalty;
            if (spotCoreRisk.amount > 0) {
                spreadPenalty = ONE - (ONE - perpCoreRisk.longWeight) / 5;
            } else {
                spreadPenalty = ONE - (ONE - spotCoreRisk.longWeight) / 5;
            }

            health += basisAmount
                .mul(spotCoreRisk.price + perpCoreRisk.price)
                .mul(spreadPenalty - existingPenalty);
        }

        health += perpEngine.getHealthContribution(subaccount, healthType);
    }

    function registerProduct(uint32 productId) external {
        IProductEngine engine = IProductEngine(msg.sender);
        IProductEngine.EngineType engineType = engine.getEngineType();
        require(
            address(engineByType[engineType]) == msg.sender,
            ERR_UNAUTHORIZED
        );

        productToEngine[productId] = engine;
    }

    /**
     * Actions
     */

    function addEngine(
        address engine,
        address offchainExchange,
        IProductEngine.EngineType engineType
    ) external onlyOwner {
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
            offchainExchange,
            quote,
            getEndpoint(),
            owner()
        );
    }

    function _tokenAddress(uint32 productId) internal view returns (address) {
        ISpotEngine spotEngine = ISpotEngine(
            address(engineByType[IProductEngine.EngineType.SPOT])
        );
        return spotEngine.getConfig(productId).token;
    }

    function _decimals(uint32 productId) internal virtual returns (uint8) {
        IERC20Base token = IERC20Base(_tokenAddress(productId));
        require(address(token) != address(0));
        return token.decimals();
    }

    function depositCollateral(IEndpoint.DepositCollateral calldata txn)
        external
        virtual
        onlyEndpoint
    {
        require(txn.amount <= INT128_MAX, ERR_CONVERSION_OVERFLOW);
        ISpotEngine spotEngine = ISpotEngine(
            address(engineByType[IProductEngine.EngineType.SPOT])
        );
        uint8 decimals = _decimals(txn.productId);

        require(decimals <= MAX_DECIMALS);
        int256 multiplier = int256(10**(MAX_DECIMALS - decimals));
        int128 amountRealized = int128(txn.amount) * int128(multiplier);

        spotEngine.updateBalance(txn.productId, txn.sender, amountRealized);
        emit ModifyCollateral(amountRealized, txn.sender, txn.productId);
    }

    function transferQuote(IEndpoint.TransferQuote calldata txn)
        external
        virtual
        onlyEndpoint
    {
        require(txn.amount <= INT128_MAX, ERR_CONVERSION_OVERFLOW);
        int128 toTransfer = int128(txn.amount);
        ISpotEngine spotEngine = ISpotEngine(
            address(engineByType[IProductEngine.EngineType.SPOT])
        );

        // require the sender address to be the same as the recipient address
        // otherwise linked signers can transfer out
        require(
            bytes20(txn.sender) == bytes20(txn.recipient),
            ERR_UNAUTHORIZED
        );

        spotEngine.updateBalance(QUOTE_PRODUCT_ID, txn.sender, -toTransfer);
        spotEngine.updateBalance(QUOTE_PRODUCT_ID, txn.recipient, toTransfer);
        require(_isAboveInitial(txn.sender), ERR_SUBACCT_HEALTH);
    }

    /// @notice control insurance balance, only callable by owner
    function depositInsurance(IEndpoint.DepositInsurance calldata txn)
        external
        virtual
        onlyEndpoint
    {
        require(txn.amount <= INT128_MAX, ERR_CONVERSION_OVERFLOW);
        int256 multiplier = int256(
            10**(MAX_DECIMALS - _decimals(QUOTE_PRODUCT_ID))
        );
        int128 amount = int128(txn.amount) * int128(multiplier);
        insurance += amount;
    }

    function handleWithdrawTransfer(
        IERC20Base token,
        address to,
        uint128 amount
    ) internal virtual {
        token.safeTransfer(to, uint256(amount));
    }

    function _balanceOf(address token) internal view virtual returns (uint128) {
        return uint128(IERC20Base(token).balanceOf(address(this)));
    }

    function withdrawCollateral(
        bytes32 sender,
        uint32 productId,
        uint128 amount,
        address sendTo
    ) external virtual onlyEndpoint {
        // TODO: remove this after we support WETH on mantle.
        require(productId != 93, ERR_INVALID_PRODUCT);

        require(amount <= INT128_MAX, ERR_CONVERSION_OVERFLOW);
        ISpotEngine spotEngine = ISpotEngine(
            address(engineByType[IProductEngine.EngineType.SPOT])
        );
        IERC20Base token = IERC20Base(spotEngine.getConfig(productId).token);
        require(address(token) != address(0));

        if (sender != X_ACCOUNT) {
            sendTo = address(uint160(bytes20(sender)));
        }

        handleWithdrawTransfer(token, sendTo, amount);

        int256 multiplier = int256(10**(MAX_DECIMALS - _decimals(productId)));
        int128 amountRealized = -int128(amount) * int128(multiplier);
        spotEngine.updateBalance(productId, sender, amountRealized);
        spotEngine.assertUtilization(productId);

        IProductEngine.HealthType healthType = sender == X_ACCOUNT
            ? IProductEngine.HealthType.PNL
            : IProductEngine.HealthType.INITIAL;

        require(getHealth(sender, healthType) >= 0, ERR_SUBACCT_HEALTH);

        emit ModifyCollateral(amountRealized, sender, productId);
    }

    function mintLp(IEndpoint.MintLp calldata txn)
        external
        virtual
        onlyEndpoint
    {
        // TODO: remove this after we support WETH on mantle.
        require(txn.productId != 93, ERR_INVALID_PRODUCT);

        require(txn.productId != QUOTE_PRODUCT_ID);
        productToEngine[txn.productId].mintLp(
            txn.productId,
            txn.sender,
            int128(txn.amountBase),
            int128(txn.quoteAmountLow),
            int128(txn.quoteAmountHigh)
        );
        require(_isAboveInitial(txn.sender), ERR_SUBACCT_HEALTH);
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

    function burnLpAndTransfer(IEndpoint.BurnLpAndTransfer calldata txn)
        external
        virtual
        onlyEndpoint
    {
        ISpotEngine spotEngine = ISpotEngine(
            address(engineByType[IProductEngine.EngineType.SPOT])
        );
        require(spotEngine == productToEngine[txn.productId]);
        (int128 amountBase, int128 amountQuote) = spotEngine.burnLp(
            txn.productId,
            txn.sender,
            int128(txn.amount)
        );
        spotEngine.updateBalance(QUOTE_PRODUCT_ID, txn.sender, -amountQuote);
        spotEngine.updateBalance(QUOTE_PRODUCT_ID, txn.recipient, amountQuote);
        spotEngine.updateBalance(txn.productId, txn.sender, -amountBase);
        spotEngine.updateBalance(txn.productId, txn.recipient, amountBase);
        require(_isAboveInitial(txn.sender), ERR_SUBACCT_HEALTH);
    }

    function claimSequencerFees(
        IEndpoint.ClaimSequencerFees calldata txn,
        int128[] calldata fees
    ) external virtual onlyEndpoint {
        ISpotEngine spotEngine = ISpotEngine(
            address(engineByType[IProductEngine.EngineType.SPOT])
        );

        IPerpEngine perpEngine = IPerpEngine(
            address(engineByType[IProductEngine.EngineType.PERP])
        );

        uint32[] memory spotIds = spotEngine.getProductIds();
        uint32[] memory perpIds = perpEngine.getProductIds();

        for (uint256 i = 0; i < spotIds.length; i++) {
            ISpotEngine.Balance memory feeBalance = spotEngine.getBalance(
                spotIds[i],
                FEES_ACCOUNT
            );

            spotEngine.updateBalance(
                spotIds[i],
                txn.subaccount,
                fees[i] + feeBalance.amount
            );

            spotEngine.updateBalance(
                spotIds[i],
                FEES_ACCOUNT,
                -feeBalance.amount
            );
        }

        for (uint256 i = 0; i < perpIds.length; i++) {
            IPerpEngine.Balance memory feeBalance = perpEngine.getBalance(
                perpIds[i],
                FEES_ACCOUNT
            );

            perpEngine.updateBalance(
                perpIds[i],
                txn.subaccount,
                feeBalance.amount,
                feeBalance.vQuoteBalance
            );

            perpEngine.updateBalance(
                perpIds[i],
                FEES_ACCOUNT,
                -feeBalance.amount,
                -feeBalance.vQuoteBalance
            );
        }
    }

    function _settlePnl(bytes32 subaccount, uint256 productIds) internal {
        IPerpEngine perpEngine = IPerpEngine(
            address(engineByType[IProductEngine.EngineType.PERP])
        );

        int128 amountSettled = perpEngine.settlePnl(subaccount, productIds);

        ISpotEngine(address(engineByType[IProductEngine.EngineType.SPOT]))
            .updateBalance(QUOTE_PRODUCT_ID, subaccount, amountSettled);
    }

    function settlePnl(IEndpoint.SettlePnl calldata txn) external onlyEndpoint {
        for (uint128 i = 0; i < txn.subaccounts.length; ++i) {
            _settlePnl(txn.subaccounts[i], txn.productIds[i]);
        }
    }

    function _isAboveInitial(bytes32 subaccount) internal view returns (bool) {
        // Weighted initial health with limit orders < 0
        return getHealth(subaccount, IProductEngine.HealthType.INITIAL) >= 0;
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
                "liquidateSubaccountImpl((bytes32,bytes32,uint32,bool,int128,uint64))"
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

    struct AddressSlot {
        address value;
    }

    function upgradeClearinghouseLiq(address _clearinghouseLiq) external {
        AddressSlot storage proxyAdmin;
        assembly {
            proxyAdmin.slot := 0xb53127684a568b3173ae13b9f8a6016e243e63b6e8ee1178d6a717850b5d6103
        }
        require(
            msg.sender ==
                IProxyManager(proxyAdmin.value).getProxyManagerHelper(),
            ERR_UNAUTHORIZED
        );
        clearinghouseLiq = _clearinghouseLiq;
    }

    function getClearinghouseLiq() external view returns (address) {
        return clearinghouseLiq;
    }

    function getSpreads() external view returns (uint256) {
        return spreads;
    }

    function configurePoints(
        address blastPoints,
        address blast,
        address gov
    ) external onlyOwner {
        IBlastPoints(blastPoints).configurePointsOperator(gov);
        IBlast(blast).configure(YieldMode.CLAIMABLE, GasMode.CLAIMABLE, gov);
    }
}
