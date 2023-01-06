// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/utils/cryptography/draft-EIP712Upgradeable.sol";
import "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import "./interfaces/engine/IProductEngine.sol";
import "./interfaces/IFeeCalculator.sol";
import "prb-math/contracts/PRBMathSD59x18.sol";
import "./common/Constants.sol";
import "./libraries/MathHelper.sol";
import "./OffchainBook.sol";
import "./interfaces/IOffchainBook.sol";
import "./EndpointGated.sol";
import "./common/Errors.sol";
import "hardhat/console.sol";

// Similar to: https://stackoverflow.com/questions/1023860/exponential-moving-average-sampled-at-varying-times
// Set time constant tau = 600
// normal calculation for factor looks like: e^(-timedelta/600)
// change this to (e^-1/600)^(timedelta)
// TIME_CONSTANT -> e^(-1/600)
int256 constant EMA_TIME_CONSTANT_X18 = 998334721450938752;

contract OffchainBook is IOffchainBook, EndpointGated, EIP712Upgradeable {
    using PRBMathSD59x18 for int256;

    IClearinghouse public clearinghouse;
    IProductEngine private engine;
    IFeeCalculator internal fees;
    Market public market;

    mapping(bytes32 => int256) public filledAmounts;

    function initialize(
        IClearinghouse _clearinghouse,
        IProductEngine _engine,
        address _endpoint,
        address _admin,
        IFeeCalculator _fees,
        uint32 _productId,
        int256 _sizeIncrement,
        int256 _priceIncrementX18,
        int256 _lpSpreadX18
    ) external initializer {
        __Ownable_init();
        setEndpoint(_endpoint);
        transferOwnership(_admin);

        __EIP712_init("Vertex", "0.0.1");
        clearinghouse = _clearinghouse;
        engine = _engine;
        fees = _fees;

        market = Market({
            productId: _productId,
            sizeIncrement: _sizeIncrement,
            priceIncrementX18: _priceIncrementX18,
            lpSpreadX18: _lpSpreadX18,
            collectedFeesX18: 0
        });
    }

    function getDigest(IEndpoint.Order memory order, bool isCancellation)
        public
        view
        returns (bytes32)
    {
        string memory structType = isCancellation
            ? "Cancellation(address sender,string subaccountName,int256 priceX18,int256 amount,uint64 expiration,uint64 nonce)"
            : "Order(address sender,string subaccountName,int256 priceX18,int256 amount,uint64 expiration,uint64 nonce)";
        return
            _hashTypedDataV4(
                keccak256(
                    abi.encode(
                        keccak256(bytes(structType)),
                        order.sender,
                        keccak256(bytes(order.subaccountName)),
                        order.priceX18,
                        order.amount,
                        order.expiration,
                        order.nonce
                    )
                )
            );
    }

    function _checkSignature(
        address subaccountOwner,
        bytes32 digest,
        bytes memory signature
    ) internal view virtual returns (bool) {
        address signer = ECDSA.recover(digest, signature);
        return (signer != address(0)) && (signer == subaccountOwner);
    }

    function _validateOrder(
        Market memory _market,
        IEndpoint.SignedOrder memory signedOrder,
        bytes32 orderDigest
    ) internal view returns (bool) {
        IEndpoint.Order memory order = signedOrder.order;
        int256 filledAmount = filledAmounts[orderDigest];
        order.amount -= filledAmount;
        return
            (order.priceX18 % _market.priceIncrementX18 == 0) &&
            _checkSignature(order.sender, orderDigest, signedOrder.signature) &&
            // valid amount
            (order.amount != 0) &&
            (order.amount % _market.sizeIncrement == 0) &&
            (order.expiration > getOracleTime());
    }

    function _feeAmountX18(
        uint64 subaccountId,
        uint32 productId,
        int256 amountX18,
        bool taker
    ) internal returns (int256, int256) {
        int256 keepRateX18 = ONE -
            fees.getFeeFractionX18(subaccountId, productId, taker);
        int256 newAmountX18 = (amountX18 > 0)
            ? amountX18.mul(keepRateX18)
            : amountX18.div(keepRateX18);
        return (amountX18 - newAmountX18, newAmountX18);
    }

    struct OrdersInfo {
        bytes32 takerDigest;
        bytes32 makerDigest;
        uint64 takerSubaccountId;
        uint64 makerSubaccountId;
    }

    function _matchOrderAMM(
        Market memory _market,
        IEndpoint.SignedOrder memory taker,
        uint64 takerSubaccountId
    ) internal returns (int256, int256) {
        (int256 baseSwappedX18, int256 quoteSwappedX18) = engine.swapLp(
            _market.productId,
            takerSubaccountId,
            // positive amount == buying base
            // means we are trying to swap a negative
            // amount of base
            -taker.order.amount,
            taker.order.priceX18,
            _market.sizeIncrement,
            _market.lpSpreadX18
        );

        taker.order.amount += baseSwappedX18.toInt();
        return (-baseSwappedX18, -quoteSwappedX18);
    }

    function _matchOrderOrder(
        Market memory _market,
        IEndpoint.Order memory taker,
        IEndpoint.Order memory maker,
        OrdersInfo memory ordersInfo
    ) internal returns (int256 takerAmountDeltaX18, int256 takerQuoteDeltaX18) {
        // execution happens at the maker's price
        int256 takerAmountDelta;

        if (taker.amount < 0) {
            takerAmountDelta = MathHelper.max(taker.amount, -maker.amount);
        } else {
            takerAmountDelta = MathHelper.min(taker.amount, -maker.amount);
        }

        takerAmountDeltaX18 = PRBMathSD59x18.fromInt(takerAmountDelta);
        int256 makerQuoteDeltaX18 = PRBMathSD59x18.mul(
            takerAmountDeltaX18,
            maker.priceX18
        );

        takerQuoteDeltaX18 = -makerQuoteDeltaX18;

        // apply the maker fee
        int256 makerFeeX18;
        (makerFeeX18, makerQuoteDeltaX18) = _feeAmountX18(
            ordersInfo.makerSubaccountId,
            _market.productId,
            makerQuoteDeltaX18,
            false
        );
        _market.collectedFeesX18 += makerFeeX18;

        taker.amount -= takerAmountDelta;
        maker.amount += takerAmountDelta;

        IProductEngine.ProductDelta[]
            memory deltas = new IProductEngine.ProductDelta[](2);

        // maker
        deltas[0] = IProductEngine.ProductDelta({
            productId: _market.productId,
            subaccountId: ordersInfo.makerSubaccountId,
            amountDeltaX18: -takerAmountDeltaX18,
            vQuoteDeltaX18: makerQuoteDeltaX18
        });
        deltas[1] = IProductEngine.ProductDelta({
            productId: QUOTE_PRODUCT_ID,
            subaccountId: ordersInfo.makerSubaccountId,
            amountDeltaX18: makerQuoteDeltaX18,
            vQuoteDeltaX18: 0
        });

        engine.applyDeltas(deltas);

        emit FillOrder(
            ordersInfo.makerDigest,
            ordersInfo.makerSubaccountId,
            maker.priceX18,
            maker.amount,
            maker.expiration,
            maker.nonce,
            false,
            makerFeeX18,
            -takerAmountDeltaX18,
            makerQuoteDeltaX18
        );
    }

    function matchOrderAMM(IEndpoint.MatchOrderAMM calldata txn)
        external
        onlyEndpoint
    {
        Market memory _market = market;
        bytes32 takerDigest = getDigest(txn.taker.order, false);
        int256 takerAmount = txn.taker.order.amount;
        _validateOrder(_market, txn.taker, takerDigest);
        uint64 takerSubaccountId = clearinghouse.getSubaccountId(
            txn.taker.order.sender,
            txn.taker.order.subaccountName
        );

        require(takerSubaccountId != 0, ERR_INVALID_TAKER);
        (
            int256 takerAmountDeltaX18,
            int256 takerQuoteDeltaX18
        ) = _matchOrderAMM(_market, txn.taker, takerSubaccountId);

        // apply the taker fee
        int256 takerFeeX18;
        (takerFeeX18, takerQuoteDeltaX18) = _feeAmountX18(
            takerSubaccountId,
            _market.productId,
            takerQuoteDeltaX18,
            true
        );
        _market.collectedFeesX18 += takerFeeX18;

        IProductEngine.ProductDelta[]
            memory deltas = new IProductEngine.ProductDelta[](2);

        // taker
        deltas[0] = IProductEngine.ProductDelta({
            productId: _market.productId,
            subaccountId: takerSubaccountId,
            amountDeltaX18: takerAmountDeltaX18,
            vQuoteDeltaX18: takerQuoteDeltaX18
        });
        deltas[1] = IProductEngine.ProductDelta({
            productId: QUOTE_PRODUCT_ID,
            subaccountId: takerSubaccountId,
            amountDeltaX18: takerQuoteDeltaX18,
            vQuoteDeltaX18: 0
        });

        engine.applyDeltas(deltas);

        require(
            clearinghouse.getHealthX18(
                takerSubaccountId,
                IProductEngine.HealthType.INITIAL
            ) >= 0,
            ERR_INVALID_TAKER
        );

        emit FillOrder(
            takerDigest,
            takerSubaccountId,
            txn.taker.order.priceX18,
            takerAmount,
            txn.taker.order.expiration,
            txn.taker.order.nonce,
            true,
            takerFeeX18,
            takerAmountDeltaX18,
            takerQuoteDeltaX18
        );
        market = _market;
        filledAmounts[takerDigest] = takerAmount - txn.taker.order.amount;
    }

    function matchOrders(IEndpoint.MatchOrders calldata txn)
        external
        onlyEndpoint
    {
        Market memory _market = market;
        IEndpoint.SignedOrder memory taker = txn.taker;
        IEndpoint.SignedOrder memory maker = txn.maker;

        OrdersInfo memory ordersInfo = OrdersInfo({
            takerDigest: getDigest(taker.order, false),
            makerDigest: getDigest(maker.order, false),
            takerSubaccountId: clearinghouse.getSubaccountId(
                taker.order.sender,
                taker.order.subaccountName
            ),
            makerSubaccountId: clearinghouse.getSubaccountId(
                maker.order.sender,
                maker.order.subaccountName
            )
        });

        int256 takerAmount = taker.order.amount;
        int256 makerAmount = maker.order.amount;

        require(
            _validateOrder(_market, taker, ordersInfo.takerDigest),
            ERR_INVALID_TAKER
        );
        require(ordersInfo.takerSubaccountId != 0, ERR_INVALID_TAKER);
        require(
            _validateOrder(_market, maker, ordersInfo.makerDigest),
            ERR_INVALID_MAKER
        );
        require(ordersInfo.makerSubaccountId != 0, ERR_INVALID_MAKER);

        // ensure orders are crossing
        require(
            (maker.order.amount > 0) != (taker.order.amount > 0),
            ERR_ORDERS_CANNOT_BE_MATCHED
        );
        if (maker.order.amount > 0) {
            require(
                maker.order.priceX18 >= taker.order.priceX18,
                ERR_ORDERS_CANNOT_BE_MATCHED
            );
        } else {
            require(
                maker.order.priceX18 <= taker.order.priceX18,
                ERR_ORDERS_CANNOT_BE_MATCHED
            );
        }

        int256 takerAmountDeltaX18;
        int256 takerQuoteDeltaX18;

        if (txn.amm) {
            (takerAmountDeltaX18, takerQuoteDeltaX18) = _matchOrderAMM(
                _market,
                taker,
                ordersInfo.takerSubaccountId
            );
        }

        {
            (int256 baseDeltaX18, int256 quoteDeltaX18) = _matchOrderOrder(
                _market,
                taker.order,
                maker.order,
                ordersInfo
            );
            takerAmountDeltaX18 += baseDeltaX18;
            takerQuoteDeltaX18 += quoteDeltaX18;
        }

        // apply the taker fee
        int256 takerFeeX18;
        (takerFeeX18, takerQuoteDeltaX18) = _feeAmountX18(
            ordersInfo.takerSubaccountId,
            _market.productId,
            takerQuoteDeltaX18,
            true
        );
        _market.collectedFeesX18 += takerFeeX18;

        {
            IProductEngine.ProductDelta[]
                memory deltas = new IProductEngine.ProductDelta[](2);

            // taker
            deltas[0] = IProductEngine.ProductDelta({
                productId: _market.productId,
                subaccountId: ordersInfo.takerSubaccountId,
                amountDeltaX18: takerAmountDeltaX18,
                vQuoteDeltaX18: takerQuoteDeltaX18
            });
            deltas[1] = IProductEngine.ProductDelta({
                productId: QUOTE_PRODUCT_ID,
                subaccountId: ordersInfo.takerSubaccountId,
                amountDeltaX18: takerQuoteDeltaX18,
                vQuoteDeltaX18: 0
            });

            engine.applyDeltas(deltas);
        }

        require(
            clearinghouse.getHealthX18(
                ordersInfo.takerSubaccountId,
                IProductEngine.HealthType.INITIAL
            ) >= 0,
            ERR_INVALID_TAKER
        );
        require(
            clearinghouse.getHealthX18(
                ordersInfo.makerSubaccountId,
                IProductEngine.HealthType.INITIAL
            ) >= 0,
            ERR_INVALID_MAKER
        );

        emit FillOrder(
            ordersInfo.takerDigest,
            ordersInfo.takerSubaccountId,
            txn.taker.order.priceX18,
            takerAmount,
            txn.taker.order.expiration,
            txn.taker.order.nonce,
            true,
            takerFeeX18,
            takerAmountDeltaX18,
            takerQuoteDeltaX18
        );

        market = _market;
        filledAmounts[ordersInfo.takerDigest] =
            takerAmount -
            taker.order.amount;
        filledAmounts[ordersInfo.makerDigest] =
            makerAmount -
            maker.order.amount;
    }

    function swapAMM(IEndpoint.SwapAMM calldata txn) external onlyEndpoint {
        Market memory _market = market;
        uint64 takerSubaccountId = clearinghouse.getSubaccountId(
            txn.sender,
            txn.subaccountName
        );
        require(takerSubaccountId != 0, ERR_INVALID_TAKER);
        (int256 takerAmountDeltaX18, int256 takerQuoteDeltaX18) = engine.swapLp(
            _market.productId,
            takerSubaccountId,
            txn.amount,
            txn.priceX18,
            _market.sizeIncrement,
            _market.lpSpreadX18
        );
        takerAmountDeltaX18 = -takerAmountDeltaX18;
        takerQuoteDeltaX18 = -takerQuoteDeltaX18;

        int256 takerFeeX18;
        (takerFeeX18, takerQuoteDeltaX18) = _feeAmountX18(
            takerSubaccountId,
            _market.productId,
            takerQuoteDeltaX18,
            true
        );
        _market.collectedFeesX18 += takerFeeX18;

        {
            IProductEngine.ProductDelta[]
                memory deltas = new IProductEngine.ProductDelta[](2);

            // taker
            deltas[0] = IProductEngine.ProductDelta({
                productId: _market.productId,
                subaccountId: takerSubaccountId,
                amountDeltaX18: takerAmountDeltaX18,
                vQuoteDeltaX18: takerQuoteDeltaX18
            });
            deltas[1] = IProductEngine.ProductDelta({
                productId: QUOTE_PRODUCT_ID,
                subaccountId: takerSubaccountId,
                amountDeltaX18: takerQuoteDeltaX18,
                vQuoteDeltaX18: 0
            });

            engine.applyDeltas(deltas);
        }
        require(
            clearinghouse.getHealthX18(
                takerSubaccountId,
                IProductEngine.HealthType.INITIAL
            ) >= 0,
            ERR_INVALID_TAKER
        );
        market = _market;
    }

    function dumpFees() external onlyEndpoint {
        IProductEngine.ProductDelta[]
            memory feeAccDeltas = new IProductEngine.ProductDelta[](1);
        int256 feesAmountX18 = market.collectedFeesX18;
        // https://en.wikipedia.org/wiki/Design_Patterns
        market.collectedFeesX18 = 0;

        // TODO: this is probably fucked for perps
        feeAccDeltas[0] = IProductEngine.ProductDelta({
            productId: QUOTE_PRODUCT_ID,
            subaccountId: FEES_SUBACCOUNT_ID,
            amountDeltaX18: feesAmountX18,
            vQuoteDeltaX18: feesAmountX18
        });
        engine.applyDeltas(feeAccDeltas);
    }

    function getMarket() external view returns (Market memory) {
        return market;
    }
}
