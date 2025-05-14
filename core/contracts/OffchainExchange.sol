// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/utils/cryptography/draft-EIP712Upgradeable.sol";
import "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import "./interfaces/engine/IProductEngine.sol";
import "./libraries/MathSD21x18.sol";
import "./common/Constants.sol";
import "./libraries/MathHelper.sol";
import "./libraries/RiskHelper.sol";
import "./libraries/Logger.sol";
import "./interfaces/IOffchainExchange.sol";
import "./EndpointGated.sol";
import "./common/Errors.sol";
import "./interfaces/engine/ISpotEngine.sol";
import "./interfaces/engine/IPerpEngine.sol";

contract OffchainExchange is
    IOffchainExchange,
    EndpointGated,
    EIP712Upgradeable
{
    using MathSD21x18 for int128;
    IClearinghouse internal clearinghouse;

    mapping(uint32 => MarketInfoStore) internal marketInfo;
    mapping(uint32 => address) internal virtualBookContract;

    mapping(uint32 => LpParams) internal lpParams;
    mapping(bytes32 => int128) public filledAmounts;

    ISpotEngine internal spotEngine;
    IPerpEngine internal perpEngine;

    mapping(address => mapping(uint32 => FeeRates)) internal feeRates;

    mapping(address => bool) internal addressTouched;
    address[] internal customFeeAddresses;

    mapping(uint32 => uint32) internal quoteIds;

    // adding following two useless mappings to not break storage layout by FOffchainExchange.
    mapping(uint32 => int128) internal uselessMapping1;
    mapping(uint32 => int128) internal uselessMapping2;

    // address -> mask (if the i-th bit is 1, it means the i-th iso subacc is being used)
    mapping(address => uint256) internal isolatedSubaccountsMask;

    // isolated subaccount -> subaccount
    mapping(bytes32 => bytes32) internal parentSubaccounts;

    // (subaccount, id) -> isolated subaccount
    mapping(bytes32 => mapping(uint256 => bytes32))
        internal isolatedSubaccounts;

    // which isolated subaccount does an isolated order create
    mapping(bytes32 => bytes32) internal digestToSubaccount;

    // how much margin does an isolated order require
    mapping(bytes32 => int128) internal digestToMargin;

    function getAllFeeRates(address[] memory users, uint32[] memory productIds)
        external
        view
        returns (FeeRates[] memory)
    {
        FeeRates[] memory rates = new FeeRates[](
            users.length * productIds.length
        );

        for (uint256 i = 0; i < users.length; i++) {
            for (uint256 j = 0; j < productIds.length; j++) {
                rates[i * productIds.length + j] = feeRates[users[i]][
                    productIds[j]
                ];
            }
        }
        return rates;
    }

    function getCustomFeeAddresses(uint32 startAt, uint32 limit)
        external
        view
        returns (address[] memory)
    {
        uint32 endAt = startAt + limit;
        uint32 total = uint32(customFeeAddresses.length);
        if (endAt > total) {
            endAt = total;
        }
        if (startAt > total) {
            startAt = total;
        }
        address[] memory addresses = new address[](endAt - startAt);
        for (uint32 i = startAt; i < endAt; i++) {
            addresses[i - startAt] = customFeeAddresses[i];
        }
        return addresses;
    }

    // copied from EIP712Upgradeable
    bytes32 private constant _TYPE_HASH =
        keccak256(
            "EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"
        );

    function getMarketInfo(uint32 productId)
        public
        view
        returns (MarketInfo memory m)
    {
        MarketInfoStore memory market = marketInfo[productId];
        m.quoteId = quoteIds[productId];
        m.collectedFees = market.collectedFees;
        m.minSize = int128(market.minSize) * 1e9;
        m.sizeIncrement = int128(market.sizeIncrement) * 1e9;
        return m;
    }

    struct CallState {
        IPerpEngine perp;
        ISpotEngine spot;
        bool isPerp;
        uint32 productId;
    }

    function _getCallState(uint32 productId)
        internal
        view
        returns (CallState memory)
    {
        address engineAddr = clearinghouse.getEngineByProduct(productId);
        IPerpEngine perp = perpEngine;

        // don't read the spot engine from storage if its a perp engine
        if (engineAddr == address(perp)) {
            return
                CallState({
                    perp: IPerpEngine(engineAddr),
                    spot: ISpotEngine(address(0)),
                    isPerp: true,
                    productId: productId
                });
        } else {
            return
                CallState({
                    perp: IPerpEngine(address(0)),
                    spot: spotEngine,
                    isPerp: false,
                    productId: productId
                });
        }
    }

    function tryCloseIsolatedSubaccount(bytes32 subaccount) external virtual {
        require(msg.sender == address(clearinghouse), ERR_UNAUTHORIZED);
        _tryCloseIsolatedSubaccount(subaccount);
    }

    function _tryCloseIsolatedSubaccount(bytes32 subaccount) internal {
        uint32 productId = RiskHelper.getIsolatedProductId(subaccount);
        if (productId == 0) {
            return;
        }
        IPerpEngine.Balance memory balance = perpEngine.getBalance(
            productId,
            subaccount
        );
        if (balance.amount == 0) {
            uint8 id = RiskHelper.getIsolatedId(subaccount);
            address addr = address(uint160(bytes20(subaccount)));
            bytes32 parent = parentSubaccounts[subaccount];
            if (balance.vQuoteBalance != 0) {
                perpEngine.updateBalance(
                    productId,
                    subaccount,
                    0,
                    -balance.vQuoteBalance
                );
                perpEngine.updateBalance(
                    productId,
                    parent,
                    0,
                    balance.vQuoteBalance
                );
            }
            int128 quoteBalance = spotEngine
                .getBalance(QUOTE_PRODUCT_ID, subaccount)
                .amount;
            if (quoteBalance != 0) {
                spotEngine.updateBalance(
                    QUOTE_PRODUCT_ID,
                    subaccount,
                    -quoteBalance
                );
                spotEngine.updateBalance(
                    QUOTE_PRODUCT_ID,
                    parent,
                    quoteBalance
                );
            }
            isolatedSubaccountsMask[addr] &= ~uint256(0) ^ (1 << id);
            isolatedSubaccounts[parent][id] = bytes32(0);
            parentSubaccounts[subaccount] = bytes32(0);

            emit CloseIsolatedSubaccount(subaccount, parent);
        }
    }

    function _updateBalances(
        CallState memory callState,
        uint32 quoteId,
        bytes32 subaccount,
        int128 baseDelta,
        int128 quoteDelta
    ) internal {
        if (callState.isPerp) {
            callState.perp.updateBalance(
                callState.productId,
                subaccount,
                baseDelta,
                quoteDelta
            );
        } else {
            if (quoteId == QUOTE_PRODUCT_ID) {
                callState.spot.updateBalance(
                    callState.productId,
                    subaccount,
                    baseDelta,
                    quoteDelta
                );
            } else {
                callState.spot.updateBalance(
                    callState.productId,
                    subaccount,
                    baseDelta
                );
                callState.spot.updateBalance(quoteId, subaccount, quoteDelta);
            }
        }
    }

    function initialize(address _clearinghouse, address _endpoint)
        external
        initializer
    {
        __Ownable_init();
        setEndpoint(_endpoint);

        __EIP712_init("Vertex", "0.0.1");
        clearinghouse = IClearinghouse(_clearinghouse);
        spotEngine = ISpotEngine(
            clearinghouse.getEngineByType(IProductEngine.EngineType.SPOT)
        );
        perpEngine = IPerpEngine(
            clearinghouse.getEngineByType(IProductEngine.EngineType.PERP)
        );
    }

    function requireEngine() internal virtual {
        require(
            msg.sender == address(spotEngine) ||
                msg.sender == address(perpEngine),
            "only engine can modify config"
        );
    }

    function updateMarket(
        uint32 productId,
        uint32 quoteId,
        address virtualBook,
        int128 sizeIncrement,
        int128 minSize,
        int128 lpSpreadX18
    ) external {
        requireEngine();
        if (virtualBook != address(0)) {
            require(
                virtualBookContract[productId] == address(0),
                "virtual book already set"
            );
            virtualBookContract[productId] = virtualBook;
        }

        if (quoteId != type(uint32).max) {
            quoteIds[productId] = quoteId;
        }

        marketInfo[productId].minSize = int64(minSize / 1e9);
        marketInfo[productId].sizeIncrement = int64(sizeIncrement / 1e9);
        lpParams[productId] = LpParams(lpSpreadX18);
    }

    function getLpParams(uint32 productId)
        external
        view
        returns (LpParams memory)
    {
        return lpParams[productId];
    }

    function getSizeIncrement(uint32 productId) external view returns (int128) {
        return int128(marketInfo[productId].sizeIncrement) * 1e9;
    }

    function getMinSize(uint32 productId) external view returns (int128) {
        return int128(marketInfo[productId].minSize) * 1e9;
    }

    function getDigest(uint32 productId, IEndpoint.Order memory order)
        public
        view
        returns (bytes32)
    {
        string
            memory structType = "Order(bytes32 sender,int128 priceX18,int128 amount,uint64 expiration,uint64 nonce)";

        bytes32 structHash = keccak256(
            abi.encode(
                keccak256(bytes(structType)),
                order.sender,
                order.priceX18,
                order.amount,
                order.expiration,
                order.nonce
            )
        );

        bytes32 domainSeparator = keccak256(
            abi.encode(
                _TYPE_HASH,
                _EIP712NameHash(),
                _EIP712VersionHash(),
                block.chainid,
                address(virtualBookContract[productId])
            )
        );

        return ECDSAUpgradeable.toTypedDataHash(domainSeparator, structHash);
    }

    function _isPerp(IPerpEngine engine, uint32 productId)
        internal
        view
        returns (bool)
    {
        return clearinghouse.getEngineByProduct(productId) == address(engine);
    }

    function _checkSignature(
        bytes32 subaccount,
        bytes32 digest,
        address linkedSigner,
        bytes memory signature
    ) internal view virtual returns (bool) {
        address signer = ECDSA.recover(digest, signature);
        return
            (signer != address(0)) &&
            (subaccount == FEES_ACCOUNT ||
                signer == address(uint160(bytes20(subaccount))) ||
                signer == linkedSigner);
    }

    function _expired(uint64 expiration) internal view returns (bool) {
        return expiration & ((1 << 58) - 1) <= getOracleTime();
    }

    function _isReduceOnly(uint64 expiration) internal pure returns (bool) {
        return ((expiration >> 61) & 1) == 1;
    }

    function _validateOrder(
        CallState memory callState,
        MarketInfo memory,
        IEndpoint.SignedOrder memory signedOrder,
        bytes32 orderDigest,
        address /* linkedSigner */
    ) internal view returns (bool) {
        if (signedOrder.order.sender == X_ACCOUNT) {
            return true;
        }
        IEndpoint.Order memory order = signedOrder.order;
        uint32 isolatedProductId = RiskHelper.getIsolatedProductId(
            order.sender
        );
        if (isolatedProductId != 0) {
            require(callState.productId == isolatedProductId, ERR_UNAUTHORIZED);
        }
        int128 filledAmount = filledAmounts[orderDigest];
        order.amount -= filledAmount;

        if (_isReduceOnly(order.expiration)) {
            int128 amount = callState.isPerp
                ? callState
                    .perp
                    .getBalance(callState.productId, order.sender)
                    .amount
                : callState
                    .spot
                    .getBalance(callState.productId, order.sender)
                    .amount;
            if ((order.amount > 0) == (amount > 0)) {
                order.amount = 0;
            } else if (order.amount > 0) {
                order.amount = MathHelper.min(order.amount, -amount);
            } else if (order.amount < 0) {
                order.amount = MathHelper.max(order.amount, -amount);
            }
        }

        return
            (order.priceX18 > 0) &&
            //            _checkSignature(
            //                order.sender,
            //                orderDigest,
            //                linkedSigner,
            //                signedOrder.signature
            //            ) &&
            // valid amount
            (order.amount != 0) &&
            !_expired(order.expiration);
    }

    function _feeAmount(
        uint32 productId,
        bytes32 subaccount,
        MarketInfo memory market,
        int128 matchBase,
        int128 matchQuote,
        int128 alreadyMatched,
        int128 orderPriceX18,
        bool taker
    ) internal view returns (int128, int128) {
        // X account is passthrough for trading and incurs
        // no fees
        if (subaccount == X_ACCOUNT) {
            return (0, matchQuote);
        }
        int128 meteredQuote = 0;
        if (taker) {
            // flat minimum fee
            if (alreadyMatched == 0) {
                meteredQuote += market.minSize.mul(orderPriceX18);
                if (matchQuote < 0) {
                    meteredQuote = -meteredQuote;
                }
            }

            // exclude the portion on [0, self.min_size) for match_quote and
            // add to metered_quote
            int128 matchBaseAbs = matchBase.abs();
            // fee is only applied on [minSize, amount)
            int128 feeApplied = MathHelper.abs(alreadyMatched + matchBase) -
                market.minSize;
            feeApplied = MathHelper.min(feeApplied, matchBaseAbs);
            if (feeApplied > 0) {
                meteredQuote += matchQuote.mulDiv(feeApplied, matchBaseAbs);
            }
        } else {
            // for maker rebates things stay the same
            meteredQuote += matchQuote;
        }

        int128 keepRateX18 = ONE -
            getFeeFractionX18(subaccount, productId, taker);
        int128 newMeteredQuote = (meteredQuote > 0)
            ? meteredQuote.mul(keepRateX18)
            : meteredQuote.div(keepRateX18);
        int128 fee = meteredQuote - newMeteredQuote;
        market.collectedFees += fee;
        return (fee, matchQuote - fee);
    }

    function feeAmount(
        uint32 productId,
        bytes32 subaccount,
        MarketInfo memory market,
        int128 matchBase,
        int128 matchQuote,
        int128 alreadyMatched,
        int128 orderPriceX18,
        bool taker
    ) internal virtual returns (int128, int128) {
        return
            _feeAmount(
                productId,
                subaccount,
                market,
                matchBase,
                matchQuote,
                alreadyMatched,
                orderPriceX18,
                taker
            );
    }

    struct OrdersInfo {
        bytes32 takerDigest;
        bytes32 makerDigest;
        int128 makerAmount;
    }

    function _matchOrderAMM(
        CallState memory callState,
        int128 baseDelta, // change in the LP's base position
        int128 quoteDelta, // change in the LP's quote position
        IEndpoint.SignedOrder memory taker
    ) internal returns (int128, int128) {
        // 1. assert that the price is better than the limit price
        int128 impliedPriceX18 = quoteDelta.div(baseDelta).abs();
        if (taker.order.amount > 0) {
            // if buying, the implied price must be lower than the limit price
            require(
                impliedPriceX18 <= taker.order.priceX18,
                ERR_ORDERS_CANNOT_BE_MATCHED
            );

            // AMM must be selling
            // magnitude of what AMM is selling must be less than or equal to what the taker is buying
            require(
                baseDelta < 0 && taker.order.amount >= -baseDelta,
                ERR_ORDERS_CANNOT_BE_MATCHED
            );
        } else {
            // if selling, the implied price must be higher than the limit price
            require(
                impliedPriceX18 >= taker.order.priceX18,
                ERR_ORDERS_CANNOT_BE_MATCHED
            );
            // AMM must be buying
            // magnitude of what AMM is buying must be less than or equal to what the taker is selling
            require(
                baseDelta > 0 && taker.order.amount <= -baseDelta,
                ERR_ORDERS_CANNOT_BE_MATCHED
            );
        }

        IProductEngine engine = callState.isPerp
            ? IProductEngine(callState.perp)
            : IProductEngine(callState.spot);

        (int128 baseSwapped, int128 quoteSwapped) = engine.swapLp(
            callState.productId,
            baseDelta,
            quoteDelta
        );

        taker.order.amount += baseSwapped;
        return (-baseSwapped, -quoteSwapped);
    }

    function _matchOrderOrder(
        CallState memory callState,
        MarketInfo memory market,
        IEndpoint.Order memory taker,
        IEndpoint.Order memory maker,
        OrdersInfo memory ordersInfo
    ) internal returns (int128 takerAmountDelta, int128 takerQuoteDelta) {
        // execution happens at the maker's price
        if (taker.amount < 0) {
            takerAmountDelta = MathHelper.max(taker.amount, -maker.amount);
        } else if (taker.amount > 0) {
            takerAmountDelta = MathHelper.min(taker.amount, -maker.amount);
        } else {
            return (0, 0);
        }

        takerAmountDelta -= takerAmountDelta % market.sizeIncrement;

        int128 makerQuoteDelta = takerAmountDelta.mul(maker.priceX18);

        takerQuoteDelta = -makerQuoteDelta;

        // apply the maker fee
        int128 makerFee;

        (makerFee, makerQuoteDelta) = feeAmount(
            callState.productId,
            maker.sender,
            market,
            -takerAmountDelta,
            makerQuoteDelta,
            0, // alreadyMatched doesn't matter for a maker order
            0, // price doesn't matter for a maker order
            false
        );

        taker.amount -= takerAmountDelta;
        maker.amount += takerAmountDelta;

        _updateBalances(
            callState,
            market.quoteId,
            maker.sender,
            -takerAmountDelta,
            makerQuoteDelta
        );

        emit FillOrder(
            callState.productId,
            ordersInfo.makerDigest,
            maker.sender,
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

    function matchOrderAMM(
        IEndpoint.MatchOrderAMM calldata txn,
        address takerLinkedSigner
    ) external onlyEndpoint {
        CallState memory callState = _getCallState(txn.productId);
        MarketInfo memory market = getMarketInfo(txn.productId);
        bytes32 takerDigest = getDigest(txn.productId, txn.taker.order);
        int128 takerAmount = txn.taker.order.amount;

        // need to convert the taker order from calldata into memory
        // otherwise modifications we make to the order's amounts
        // don't persist
        IEndpoint.SignedOrder memory taker = txn.taker;
        require(
            !RiskHelper.isIsolatedSubaccount(taker.order.sender),
            ERR_UNAUTHORIZED
        );

        require(
            _validateOrder(
                callState,
                market,
                taker,
                takerDigest,
                takerLinkedSigner
            ),
            ERR_INVALID_TAKER
        );

        (int128 takerAmountDelta, int128 takerQuoteDelta) = _matchOrderAMM(
            callState,
            txn.baseDelta,
            txn.quoteDelta,
            taker
        );

        // apply the taker fee
        int128 takerFee;

        (takerFee, takerQuoteDelta) = feeAmount(
            txn.productId,
            taker.order.sender,
            market,
            takerAmountDelta,
            takerQuoteDelta,
            takerAmount - taker.order.amount - takerAmountDelta,
            -takerQuoteDelta.div(takerAmountDelta),
            true
        );

        _updateBalances(
            callState,
            market.quoteId,
            taker.order.sender,
            takerAmountDelta,
            takerQuoteDelta
        );

        require(isHealthy(taker.order.sender), ERR_INVALID_TAKER);

        emit FillOrder(
            txn.productId,
            takerDigest,
            taker.order.sender,
            taker.order.priceX18,
            takerAmount,
            taker.order.expiration,
            taker.order.nonce,
            true,
            takerFee,
            takerAmountDelta,
            takerQuoteDelta
        );
        marketInfo[txn.productId].collectedFees = market.collectedFees;
        filledAmounts[takerDigest] = takerAmount - taker.order.amount;
    }

    function isHealthy(
        bytes32 /* subaccount */
    ) internal view virtual returns (bool) {
        return true;
    }

    function matchOrders(IEndpoint.MatchOrdersWithSigner calldata txn)
        external
        onlyEndpoint
    {
        CallState memory callState = _getCallState(txn.matchOrders.productId);
        int128 takerAmount;
        int128 takerFee;
        int128 takerAmountDelta;
        int128 takerQuoteDelta;
        OrdersInfo memory ordersInfo;

        MarketInfo memory market = getMarketInfo(callState.productId);
        IEndpoint.SignedOrder memory taker = txn.matchOrders.taker;
        IEndpoint.SignedOrder memory maker = txn.matchOrders.maker;
        ordersInfo = OrdersInfo({
            takerDigest: getDigest(callState.productId, taker.order),
            makerDigest: getDigest(callState.productId, maker.order),
            makerAmount: maker.order.amount
        });
        if (digestToSubaccount[ordersInfo.takerDigest] != bytes32(0)) {
            taker.order.sender = digestToSubaccount[ordersInfo.takerDigest];
        }
        if (digestToSubaccount[ordersInfo.makerDigest] != bytes32(0)) {
            maker.order.sender = digestToSubaccount[ordersInfo.makerDigest];
        }

        takerAmount = taker.order.amount;

        require(
            _validateOrder(
                callState,
                market,
                taker,
                ordersInfo.takerDigest,
                txn.takerLinkedSigner
            ),
            ERR_INVALID_TAKER
        );
        require(
            _validateOrder(
                callState,
                market,
                maker,
                ordersInfo.makerDigest,
                txn.makerLinkedSigner
            ),
            ERR_INVALID_MAKER
        );

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

        (takerAmountDelta, takerQuoteDelta) = _matchOrderOrder(
            callState,
            market,
            taker.order,
            maker.order,
            ordersInfo
        );

        // apply the taker fee
        (takerFee, takerQuoteDelta) = feeAmount(
            callState.productId,
            taker.order.sender,
            market,
            takerAmountDelta,
            takerQuoteDelta,
            takerAmount - taker.order.amount - takerAmountDelta,
            maker.order.priceX18,
            true
        );

        _updateBalances(
            callState,
            market.quoteId,
            taker.order.sender,
            takerAmountDelta,
            takerQuoteDelta
        );

        require(isHealthy(taker.order.sender), ERR_INVALID_TAKER);
        require(isHealthy(maker.order.sender), ERR_INVALID_MAKER);

        marketInfo[callState.productId].collectedFees = market.collectedFees;

        if (taker.order.sender != X_ACCOUNT) {
            filledAmounts[ordersInfo.takerDigest] =
                takerAmount -
                taker.order.amount;
        }

        if (maker.order.sender != X_ACCOUNT) {
            filledAmounts[ordersInfo.makerDigest] =
                ordersInfo.makerAmount -
                maker.order.amount;
        }

        _tryCloseIsolatedSubaccount(taker.order.sender);
        _tryCloseIsolatedSubaccount(maker.order.sender);

        emit FillOrder(
            callState.productId,
            ordersInfo.takerDigest,
            taker.order.sender,
            taker.order.priceX18,
            takerAmount,
            taker.order.expiration,
            taker.order.nonce,
            true,
            takerFee,
            takerAmountDelta,
            takerQuoteDelta
        );
    }

    function swapAMM(IEndpoint.SwapAMM calldata txn) external onlyEndpoint {
        require(!RiskHelper.isIsolatedSubaccount(txn.sender), ERR_UNAUTHORIZED);
        MarketInfo memory market = getMarketInfo(txn.productId);
        CallState memory callState = _getCallState(txn.productId);

        require(txn.priceX18 > 0, ERR_INVALID_PRICE);

        if (callState.isPerp) {
            require(
                txn.amount % market.sizeIncrement == 0,
                ERR_INVALID_SWAP_PARAMS
            );
        }

        IProductEngine engine = callState.isPerp
            ? IProductEngine(callState.perp)
            : IProductEngine(callState.spot);

        (int128 takerAmountDelta, int128 takerQuoteDelta) = engine.swapLp(
            txn.productId,
            txn.amount,
            -txn.amount.mul(txn.priceX18)
        );

        takerAmountDelta = -takerAmountDelta;
        takerQuoteDelta = -takerQuoteDelta;

        int128 takerFee;

        (takerFee, takerQuoteDelta) = feeAmount(
            txn.productId,
            txn.sender,
            market,
            takerAmountDelta,
            takerQuoteDelta,
            (takerAmountDelta > 0) ? market.minSize : -market.minSize, // just charge the protocol fee without any flat stuff
            0,
            true
        );

        _updateBalances(
            callState,
            market.quoteId,
            txn.sender,
            takerAmountDelta,
            takerQuoteDelta
        );
        require(
            clearinghouse.getHealth(
                txn.sender,
                IProductEngine.HealthType.INITIAL
            ) >= 0,
            ERR_INVALID_TAKER
        );
        marketInfo[txn.productId].collectedFees = market.collectedFees;
    }

    function dumpFees() external onlyEndpoint {
        // loop over all spot and perp product ids
        uint32[] memory productIds = spotEngine.getProductIds();

        for (uint32 i = 1; i < productIds.length; i++) {
            uint32 productId = productIds[i];
            MarketInfoStore memory market = marketInfo[productId];
            if (market.collectedFees == 0) {
                continue;
            }

            spotEngine.updateBalance(
                quoteIds[productId],
                X_ACCOUNT,
                market.collectedFees
            );

            market.collectedFees = 0;
            marketInfo[productId] = market;
        }

        productIds = perpEngine.getProductIds();

        for (uint32 i = 0; i < productIds.length; i++) {
            uint32 productId = productIds[i];
            MarketInfoStore memory market = marketInfo[productId];
            if (market.collectedFees == 0) {
                continue;
            }

            perpEngine.updateBalance(
                productId,
                X_ACCOUNT,
                0,
                market.collectedFees
            );

            market.collectedFees = 0;
            marketInfo[productId] = market;
        }
    }

    function getFeeFractionX18(
        bytes32 subaccount,
        uint32 productId,
        bool taker
    ) public view returns (int128) {
        FeeRates memory userFeeRates = _getUserFeeRates(subaccount, productId);
        return taker ? userFeeRates.takerRateX18 : userFeeRates.makerRateX18;
    }

    function getFeeRatesX18(bytes32 subaccount, uint32 productId)
        public
        view
        returns (int128, int128)
    {
        FeeRates memory userFeeRates = _getUserFeeRates(subaccount, productId);
        return (userFeeRates.takerRateX18, userFeeRates.makerRateX18);
    }

    function _getUserFeeRates(bytes32 subaccount, uint32 productId)
        private
        view
        returns (FeeRates memory)
    {
        if (RiskHelper.isIsolatedSubaccount(subaccount)) {
            subaccount = parentSubaccounts[subaccount];
        }
        FeeRates memory userFeeRates = feeRates[
            address(uint160(bytes20(subaccount)))
        ][productId];

        uint96 subName = uint96((uint256(subaccount) << 160) >> 160);

        if ((subName & MASK_6_BYTES) == 0x666F78696679000000000000) {
            // defaults for "foxify". maker: 0bps / taker: 7.5bps
            userFeeRates = FeeRates(0, 750_000_000_000_000, 1);
        } else if ((subName & MASK_6_BYTES) == 0x66756E646564000000000000) {
            // defaults for "funded". maker: 7.5bps / taker: 7.5bps
            userFeeRates = FeeRates(
                750_000_000_000_000,
                750_000_000_000_000,
                1
            );
        } else if ((subName & MASK_6_BYTES) == 0x706572706965000000000000) {
            // defaults for "perpie". maker: 0bps / taker: 4bps
            userFeeRates = FeeRates(0, 400_000_000_000_000, 1);
        } else if (userFeeRates.isNonDefault == 0) {
            if (block.chainid == 80094 || block.chainid == 80084) {
                // defaults for Berachain. maker: 2bps / taker: 5bps
                userFeeRates = FeeRates(
                    200_000_000_000_000,
                    500_000_000_000_000,
                    1
                );
            } else {
                userFeeRates = FeeRates(0, 200_000_000_000_000, 1);
            }
        }

        return userFeeRates;
    }

    function updateFeeRates(
        address user,
        uint32 productId,
        int64 makerRateX18,
        int64 takerRateX18
    ) external {
        require(msg.sender == address(clearinghouse), ERR_UNAUTHORIZED);
        if (!addressTouched[user]) {
            addressTouched[user] = true;
            customFeeAddresses.push(user);
        }
        if (productId == QUOTE_PRODUCT_ID) {
            uint32[] memory spotProductIds = spotEngine.getProductIds();
            uint32[] memory perpProductIds = perpEngine.getProductIds();
            for (uint32 i = 0; i < spotProductIds.length; i++) {
                if (spotProductIds[i] == QUOTE_PRODUCT_ID) {
                    continue;
                }
                feeRates[user][spotProductIds[i]] = FeeRates(
                    makerRateX18,
                    takerRateX18,
                    1
                );
            }
            for (uint32 i = 0; i < perpProductIds.length; i++) {
                feeRates[user][perpProductIds[i]] = FeeRates(
                    makerRateX18,
                    takerRateX18,
                    1
                );
            }
        } else {
            feeRates[user][productId] = FeeRates(makerRateX18, takerRateX18, 1);
        }
    }

    function getVirtualBook(uint32 productId) external view returns (address) {
        return virtualBookContract[productId];
    }

    function getAllVirtualBooks() external view returns (address[] memory) {
        uint32[] memory spotProductIds = spotEngine.getProductIds();
        uint32[] memory perpProductIds = perpEngine.getProductIds();

        uint32 maxProductId = 0;
        for (uint32 i = 0; i < spotProductIds.length; i++) {
            if (spotProductIds[i] > maxProductId) {
                maxProductId = spotProductIds[i];
            }
        }
        for (uint32 i = 0; i < perpProductIds.length; i++) {
            if (perpProductIds[i] > maxProductId) {
                maxProductId = perpProductIds[i];
            }
        }

        address[] memory virtualBooks = new address[](maxProductId + 1);
        for (uint32 i = 0; i <= maxProductId; i++) {
            virtualBooks[i] = virtualBookContract[i];
        }
        return virtualBooks;
    }

    function getIsolatedDigest(
        uint32 productId,
        IEndpoint.IsolatedOrder memory order
    ) public view returns (bytes32) {
        string
            memory structType = "IsolatedOrder(bytes32 sender,int128 priceX18,int128 amount,uint64 expiration,uint64 nonce,int128 margin)";

        bytes32 structHash = keccak256(
            abi.encode(
                keccak256(bytes(structType)),
                order.sender,
                order.priceX18,
                order.amount,
                order.expiration,
                order.nonce,
                order.margin
            )
        );

        bytes32 domainSeparator = keccak256(
            abi.encode(
                _TYPE_HASH,
                _EIP712NameHash(),
                _EIP712VersionHash(),
                block.chainid,
                address(virtualBookContract[productId])
            )
        );

        return ECDSAUpgradeable.toTypedDataHash(domainSeparator, structHash);
    }

    function createIsolatedSubaccount(
        IEndpoint.CreateIsolatedSubaccount memory txn,
        address linkedSigner
    ) external onlyEndpoint returns (bytes32) {
        require(
            !RiskHelper.isIsolatedSubaccount(txn.order.sender),
            ERR_UNAUTHORIZED
        );
        bytes32 isolatedDigest = getIsolatedDigest(txn.productId, txn.order);
        require(
            _checkSignature(
                txn.order.sender,
                isolatedDigest,
                linkedSigner,
                txn.signature
            ),
            ERR_INVALID_SIGNATURE
        );

        address senderAddress = address(uint160(bytes20(txn.order.sender)));
        uint256 mask = isolatedSubaccountsMask[senderAddress];
        bytes32 newIsolatedSubaccount = bytes32(0);
        for (uint256 id = 0; (1 << id) <= mask; id += 1) {
            if (mask & (1 << id) != 0) {
                bytes32 subaccount = isolatedSubaccounts[txn.order.sender][id];
                if (subaccount != bytes32(0)) {
                    uint32 productId = RiskHelper.getIsolatedProductId(
                        subaccount
                    );
                    if (productId == txn.productId) {
                        newIsolatedSubaccount = subaccount;
                        break;
                    }
                }
            }
        }

        if (newIsolatedSubaccount == bytes32(0)) {
            require(
                mask != (1 << MAX_ISOLATED_SUBACCOUNTS_PER_ADDRESS) - 1,
                "Too many isolated subaccounts"
            );
            uint8 id = 0;
            while (mask & 1 != 0) {
                mask >>= 1;
                id += 1;
            }

            // |  address | reserved | productId |   id   |  'iso'  |
            // | 20 bytes |  6 bytes |  2 bytes  | 1 byte | 3 bytes |
            newIsolatedSubaccount = bytes32(
                (uint256(uint160(senderAddress)) << 96) |
                    (uint256(txn.productId) << 32) |
                    (uint256(id) << 24) |
                    6910831
            );
            isolatedSubaccountsMask[senderAddress] |= 1 << id;
            parentSubaccounts[newIsolatedSubaccount] = txn.order.sender;
            isolatedSubaccounts[txn.order.sender][id] = newIsolatedSubaccount;
        }

        bytes32 digest = getDigest(
            txn.productId,
            IEndpoint.Order({
                sender: txn.order.sender,
                priceX18: txn.order.priceX18,
                amount: txn.order.amount,
                expiration: txn.order.expiration,
                nonce: txn.order.nonce
            })
        );
        digestToSubaccount[digest] = newIsolatedSubaccount;

        if (txn.order.margin > 0) {
            digestToMargin[digest] = txn.order.margin;
            spotEngine.updateBalance(
                QUOTE_PRODUCT_ID,
                txn.order.sender,
                -txn.order.margin
            );
            spotEngine.updateBalance(
                QUOTE_PRODUCT_ID,
                newIsolatedSubaccount,
                txn.order.margin
            );
        }

        return newIsolatedSubaccount;
    }

    function getIsolatedSubaccounts(bytes32 subaccount)
        external
        view
        returns (bytes32[] memory)
    {
        uint256 nIsolatedSubaccounts = 0;
        for (uint256 id = 0; id < MAX_ISOLATED_SUBACCOUNTS_PER_ADDRESS; id++) {
            bytes32 isolatedSubaccount = isolatedSubaccounts[subaccount][id];
            if (isolatedSubaccount != bytes32(0)) {
                nIsolatedSubaccounts += 1;
            }
        }
        bytes32[] memory isolatedsubaccountsResponse = new bytes32[](
            nIsolatedSubaccounts
        );
        for (uint256 id = 0; id < MAX_ISOLATED_SUBACCOUNTS_PER_ADDRESS; id++) {
            bytes32 isolatedSubaccount = isolatedSubaccounts[subaccount][id];
            if (isolatedSubaccount != bytes32(0)) {
                isolatedsubaccountsResponse[
                    --nIsolatedSubaccounts
                ] = isolatedSubaccount;
            }
        }
        return isolatedsubaccountsResponse;
    }

    function isIsolatedSubaccountActive(bytes32 parent, bytes32 subaccount)
        external
        view
        returns (bool)
    {
        for (uint256 id = 0; id < MAX_ISOLATED_SUBACCOUNTS_PER_ADDRESS; id++) {
            if (subaccount == isolatedSubaccounts[parent][id]) {
                return true;
            }
        }
        return false;
    }

    function getParentSubaccount(bytes32 subaccount)
        external
        view
        returns (bytes32)
    {
        return parentSubaccounts[subaccount];
    }
}
