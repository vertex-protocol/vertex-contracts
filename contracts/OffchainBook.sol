// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/utils/cryptography/draft-EIP712Upgradeable.sol";
import "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import "./interfaces/engine/IProductEngine.sol";
import "./interfaces/IFeeCalculator.sol";
import "./libraries/MathSD21x18.sol";
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
int128 constant EMA_TIME_CONSTANT_X18 = 998334721450938752;

contract OffchainBook is IOffchainBook, EndpointGated, EIP712Upgradeable {
    using MathSD21x18 for int128;

    IClearinghouse public clearinghouse;
    IProductEngine private engine;
    IFeeCalculator internal fees;
    Market public market;

    mapping(bytes32 => int128) public filledAmounts;

    function initialize(
        IClearinghouse _clearinghouse,
        IProductEngine _engine,
        address _endpoint,
        address _admin,
        IFeeCalculator _fees,
        uint32 _productId,
        int128 _sizeIncrement,
        int128 _priceIncrementX18,
        int128 _lpSpreadX18
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
            collectedFees: 0
        });
    }

    function getDigest(IEndpoint.Order memory order)
        public
        view
        returns (bytes32)
    {
        string
            memory structType = "Order(address sender,string subaccountName,int128 priceX18,int128 amount,uint64 expiration,uint64 nonce)";
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
        int128 filledAmount = filledAmounts[orderDigest];
        order.amount -= filledAmount;
        return
            (order.priceX18 % _market.priceIncrementX18 == 0) &&
            _checkSignature(order.sender, orderDigest, signedOrder.signature) &&
            // valid amount
            (order.amount != 0) &&
            (order.amount % _market.sizeIncrement == 0) &&
            (order.expiration > getOracleTime());
    }

    function _feeAmount(
        uint64 subaccountId,
        uint32 productId,
        int128 amount,
        bool taker
    ) internal view returns (int128, int128) {
        int128 keepRateX18 = ONE -
            fees.getFeeFractionX18(subaccountId, productId, taker);
        int128 newAmount = (amount > 0)
            ? amount.mul(keepRateX18)
            : amount.div(keepRateX18);
        return (amount - newAmount, newAmount);
    }

    struct OrdersInfo {
        bytes32 takerDigest;
        bytes32 makerDigest;
        uint64 takerSubaccountId;
        uint64 makerSubaccountId;
        int128 makerAmount;
    }

    function _matchOrderAMM(
        Market memory _market,
        IEndpoint.SignedOrder memory taker,
        uint64 takerSubaccountId
    ) internal returns (int128, int128) {
        (int128 baseSwapped, int128 quoteSwapped) = engine.swapLp(
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

        taker.order.amount += baseSwapped;
        return (-baseSwapped, -quoteSwapped);
    }

    function _matchOrderOrder(
        Market memory _market,
        IEndpoint.Order memory taker,
        IEndpoint.Order memory maker,
        OrdersInfo memory ordersInfo
    ) internal returns (int128 takerAmountDelta, int128 takerQuoteDelta) {
        // execution happens at the maker's price
        if (taker.amount < 0) {
            takerAmountDelta = MathHelper.max(taker.amount, -maker.amount);
        } else {
            takerAmountDelta = MathHelper.min(taker.amount, -maker.amount);
        }

        int128 makerQuoteDelta = takerAmountDelta.mul(maker.priceX18);

        takerQuoteDelta = -makerQuoteDelta;

        // apply the maker fee
        int128 makerFee;
        (makerFee, makerQuoteDelta) = _feeAmount(
            ordersInfo.makerSubaccountId,
            _market.productId,
            makerQuoteDelta,
            false
        );
        _market.collectedFees += makerFee;

        taker.amount -= takerAmountDelta;
        maker.amount += takerAmountDelta;

        IProductEngine.ProductDelta[]
            memory deltas = new IProductEngine.ProductDelta[](2);

        // maker
        deltas[0] = IProductEngine.ProductDelta({
            productId: _market.productId,
            subaccountId: ordersInfo.makerSubaccountId,
            amountDelta: -takerAmountDelta,
            vQuoteDelta: makerQuoteDelta
        });
        deltas[1] = IProductEngine.ProductDelta({
            productId: QUOTE_PRODUCT_ID,
            subaccountId: ordersInfo.makerSubaccountId,
            amountDelta: makerQuoteDelta,
            vQuoteDelta: 0
        });

        engine.applyDeltas(deltas);

        emit FillOrder(
            ordersInfo.makerDigest,
            ordersInfo.makerSubaccountId,
            maker.priceX18,
            ordersInfo.makerAmount,
            maker.expiration,
            maker.nonce,
            false,
            makerFee,
            -takerAmountDelta,
            makerQuoteDelta
        );
    }

    function matchOrderAMM(IEndpoint.MatchOrderAMM calldata txn)
        external
        onlyEndpoint
    {
        Market memory _market = market;
        bytes32 takerDigest = getDigest(txn.taker.order);
        int128 takerAmount = txn.taker.order.amount;
        _validateOrder(_market, txn.taker, takerDigest);
        uint64 takerSubaccountId = clearinghouse.getSubaccountId(
            txn.taker.order.sender,
            txn.taker.order.subaccountName
        );

        require(takerSubaccountId != 0, ERR_INVALID_TAKER);
        (int128 takerAmountDelta, int128 takerQuoteDelta) = _matchOrderAMM(
            _market,
            txn.taker,
            takerSubaccountId
        );

        // apply the taker fee
        int128 takerFee;
        (takerFee, takerQuoteDelta) = _feeAmount(
            takerSubaccountId,
            _market.productId,
            takerQuoteDelta,
            true
        );
        _market.collectedFees += takerFee;

        IProductEngine.ProductDelta[]
            memory deltas = new IProductEngine.ProductDelta[](2);

        // taker
        deltas[0] = IProductEngine.ProductDelta({
            productId: _market.productId,
            subaccountId: takerSubaccountId,
            amountDelta: takerAmountDelta,
            vQuoteDelta: takerQuoteDelta
        });
        deltas[1] = IProductEngine.ProductDelta({
            productId: QUOTE_PRODUCT_ID,
            subaccountId: takerSubaccountId,
            amountDelta: takerQuoteDelta,
            vQuoteDelta: 0
        });

        engine.applyDeltas(deltas);

        require(
            clearinghouse.getHealth(
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
            takerFee,
            takerAmountDelta,
            takerQuoteDelta
        );
        market.collectedFees = _market.collectedFees;
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
            takerDigest: getDigest(taker.order),
            makerDigest: getDigest(maker.order),
            takerSubaccountId: clearinghouse.getSubaccountId(
                taker.order.sender,
                taker.order.subaccountName
            ),
            makerSubaccountId: clearinghouse.getSubaccountId(
                maker.order.sender,
                maker.order.subaccountName
            ),
            makerAmount: maker.order.amount
        });

        int128 takerAmount = taker.order.amount;

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

        int128 takerAmountDelta;
        int128 takerQuoteDelta;

        if (txn.amm) {
            (takerAmountDelta, takerQuoteDelta) = _matchOrderAMM(
                _market,
                taker,
                ordersInfo.takerSubaccountId
            );
        }

        {
            (int128 baseDelta, int128 quoteDelta) = _matchOrderOrder(
                _market,
                taker.order,
                maker.order,
                ordersInfo
            );
            takerAmountDelta += baseDelta;
            takerQuoteDelta += quoteDelta;
        }

        // apply the taker fee
        int128 takerFee;
        (takerFee, takerQuoteDelta) = _feeAmount(
            ordersInfo.takerSubaccountId,
            _market.productId,
            takerQuoteDelta,
            true
        );
        _market.collectedFees += takerFee;

        {
            IProductEngine.ProductDelta[]
                memory deltas = new IProductEngine.ProductDelta[](2);

            // taker
            deltas[0] = IProductEngine.ProductDelta({
                productId: _market.productId,
                subaccountId: ordersInfo.takerSubaccountId,
                amountDelta: takerAmountDelta,
                vQuoteDelta: takerQuoteDelta
            });
            deltas[1] = IProductEngine.ProductDelta({
                productId: QUOTE_PRODUCT_ID,
                subaccountId: ordersInfo.takerSubaccountId,
                amountDelta: takerQuoteDelta,
                vQuoteDelta: 0
            });

            engine.applyDeltas(deltas);
        }

        require(
            clearinghouse.getHealth(
                ordersInfo.takerSubaccountId,
                IProductEngine.HealthType.INITIAL
            ) >= 0,
            ERR_INVALID_TAKER
        );
        require(
            clearinghouse.getHealth(
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
            takerFee,
            takerAmountDelta,
            takerQuoteDelta
        );

        market.collectedFees = _market.collectedFees;
        filledAmounts[ordersInfo.takerDigest] =
            takerAmount -
            taker.order.amount;
        filledAmounts[ordersInfo.makerDigest] =
            ordersInfo.makerAmount -
            maker.order.amount;
    }

    function swapAMM(IEndpoint.SwapAMM calldata txn) external onlyEndpoint {
        Market memory _market = market;
        uint64 takerSubaccountId = clearinghouse.getSubaccountId(
            txn.sender,
            txn.subaccountName
        );
        require(takerSubaccountId != 0, ERR_INVALID_TAKER);
        (int128 takerAmountDelta, int128 takerQuoteDelta) = engine.swapLp(
            _market.productId,
            takerSubaccountId,
            txn.amount,
            txn.priceX18,
            _market.sizeIncrement,
            _market.lpSpreadX18
        );
        takerAmountDelta = -takerAmountDelta;
        takerQuoteDelta = -takerQuoteDelta;

        int128 takerFee;
        (takerFee, takerQuoteDelta) = _feeAmount(
            takerSubaccountId,
            _market.productId,
            takerQuoteDelta,
            true
        );
        _market.collectedFees += takerFee;

        {
            IProductEngine.ProductDelta[]
                memory deltas = new IProductEngine.ProductDelta[](2);

            // taker
            deltas[0] = IProductEngine.ProductDelta({
                productId: _market.productId,
                subaccountId: takerSubaccountId,
                amountDelta: takerAmountDelta,
                vQuoteDelta: takerQuoteDelta
            });
            deltas[1] = IProductEngine.ProductDelta({
                productId: QUOTE_PRODUCT_ID,
                subaccountId: takerSubaccountId,
                amountDelta: takerQuoteDelta,
                vQuoteDelta: 0
            });

            engine.applyDeltas(deltas);
        }
        require(
            clearinghouse.getHealth(
                takerSubaccountId,
                IProductEngine.HealthType.INITIAL
            ) >= 0,
            ERR_INVALID_TAKER
        );
        market.collectedFees = _market.collectedFees;
    }

    function dumpFees() external onlyEndpoint {
        IProductEngine.ProductDelta[]
            memory feeAccDeltas = new IProductEngine.ProductDelta[](1);
        int128 feesAmount = market.collectedFees;
        // https://en.wikipedia.org/wiki/Design_Patterns
        market.collectedFees = 0;

        if (engine.getEngineType() == IProductEngine.EngineType.SPOT) {
            feeAccDeltas[0] = IProductEngine.ProductDelta({
                productId: QUOTE_PRODUCT_ID,
                subaccountId: FEES_SUBACCOUNT_ID,
                amountDelta: feesAmount,
                vQuoteDelta: 0
            });
        } else {
            feeAccDeltas[0] = IProductEngine.ProductDelta({
                productId: market.productId,
                subaccountId: FEES_SUBACCOUNT_ID,
                amountDelta: 0,
                vQuoteDelta: feesAmount
            });
        }

        engine.applyDeltas(feeAccDeltas);
    }

    function getMarket() external view returns (Market memory) {
        return market;
    }
}
