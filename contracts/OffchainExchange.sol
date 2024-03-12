// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/utils/cryptography/draft-EIP712Upgradeable.sol";
import "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import "./interfaces/engine/IProductEngine.sol";
import "./libraries/MathSD21x18.sol";
import "./common/Constants.sol";
import "./libraries/MathHelper.sol";
import "./libraries/Logger.sol";
import "./interfaces/IOffchainExchange.sol";
import "./EndpointGated.sol";
import "./common/Errors.sol";
import "./Version.sol";
import "./interfaces/engine/ISpotEngine.sol";
import "./interfaces/engine/IPerpEngine.sol";

contract OffchainExchange is
    IOffchainExchange,
    EndpointGated,
    EIP712Upgradeable,
    Version
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

    function _updateBalances(
        CallState memory callState,
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
            callState.spot.updateBalance(
                callState.productId,
                subaccount,
                baseDelta,
                quoteDelta
            );
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

    function updateMarket(
        uint32 productId,
        address virtualBook,
        int128 sizeIncrement,
        int128 minSize,
        int128 lpSpreadX18
    ) external virtual {
        require(
            msg.sender == address(spotEngine) ||
                msg.sender == address(perpEngine),
            "only engine can modify config"
        );
        if (virtualBook != address(0)) {
            require(
                virtualBookContract[productId] == address(0),
                "virtual book already set"
            );
            virtualBookContract[productId] = virtualBook;
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
        address linkedSigner
    ) internal view returns (bool) {
        if (signedOrder.order.sender == X_ACCOUNT) {
            return true;
        }
        IEndpoint.Order memory order = signedOrder.order;
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

        {
            MarketInfo memory market = getMarketInfo(callState.productId);
            IEndpoint.SignedOrder memory taker = txn.matchOrders.taker;
            IEndpoint.SignedOrder memory maker = txn.matchOrders.maker;
            ordersInfo = OrdersInfo({
                takerDigest: getDigest(callState.productId, taker.order),
                makerDigest: getDigest(callState.productId, maker.order),
                makerAmount: maker.order.amount
            });

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
                taker.order.sender,
                takerAmountDelta,
                takerQuoteDelta
            );

            require(isHealthy(taker.order.sender), ERR_INVALID_TAKER);
            require(isHealthy(maker.order.sender), ERR_INVALID_MAKER);

            marketInfo[callState.productId].collectedFees = market
                .collectedFees;

            if (txn.matchOrders.taker.order.sender != X_ACCOUNT) {
                filledAmounts[ordersInfo.takerDigest] =
                    takerAmount -
                    taker.order.amount;
            }

            if (txn.matchOrders.maker.order.sender != X_ACCOUNT) {
                filledAmounts[ordersInfo.makerDigest] =
                    ordersInfo.makerAmount -
                    maker.order.amount;
            }
        }

        emit FillOrder(
            callState.productId,
            ordersInfo.takerDigest,
            txn.matchOrders.taker.order.sender,
            txn.matchOrders.taker.order.priceX18,
            takerAmount,
            txn.matchOrders.taker.order.expiration,
            txn.matchOrders.taker.order.nonce,
            true,
            takerFee,
            takerAmountDelta,
            takerQuoteDelta
        );
    }

    function swapAMM(IEndpoint.SwapAMM calldata txn) external onlyEndpoint {
        MarketInfo memory market = getMarketInfo(txn.productId);
        CallState memory callState = _getCallState(txn.productId);

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

            // its possible for fees to be <= 0 if there is a cross-chain trade
            // and the maker rebate is exclusively coming from one chain
            if (market.collectedFees <= 0) {
                continue;
            }

            spotEngine.updateBalance(
                QUOTE_PRODUCT_ID,
                FEES_ACCOUNT,
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
                FEES_ACCOUNT,
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
        FeeRates memory userFeeRates = feeRates[
            address(uint160(bytes20(subaccount)))
        ][productId];
        if (userFeeRates.isNonDefault == 0) {
            // use the default fee rates.
            userFeeRates = FeeRates(0, 200_000_000_000_000, 1);
        }
        return taker ? userFeeRates.takerRateX18 : userFeeRates.makerRateX18;
    }

    function getFeeRatesX18(bytes32 subaccount, uint32 productId)
        public
        view
        returns (int128, int128)
    {
        FeeRates memory userFeeRates = feeRates[
            address(uint160(bytes20(subaccount)))
        ][productId];
        if (userFeeRates.isNonDefault == 0) {
            // use the default fee rates.
            userFeeRates = FeeRates(0, 200_000_000_000_000, 1);
        }
        return (userFeeRates.takerRateX18, userFeeRates.makerRateX18);
    }

    function updateFeeRates(
        address user,
        uint32 productId,
        int64 makerRateX18,
        int64 takerRateX18
    ) external onlyEndpoint {
        if (!addressTouched[user]) {
            addressTouched[user] = true;
            customFeeAddresses.push(user);
        }
        feeRates[user][productId] = FeeRates(makerRateX18, takerRateX18, 1);
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

    // TODO: remove this function after migration
    function updateMinSizes(
        uint32[] memory productIds,
        int128[] memory minSizes
    ) external onlyOwner {
        require(productIds.length == minSizes.length, "invalid inputs.");
        for (uint32 i = 0; i < productIds.length; i++) {
            uint32 productId = productIds[i];
            int128 minSize = minSizes[i];
            require(
                marketInfo[productId].minSize != 0,
                "market doesn't exist."
            );
            marketInfo[productId].minSize = int64(minSize / 1e9);
        }
    }
}
