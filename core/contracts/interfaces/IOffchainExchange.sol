// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

import "./clearinghouse/IClearinghouse.sol";

interface IOffchainExchange {
    event FillOrder(
        uint32 indexed productId,
        // original order information
        bytes32 indexed digest,
        bytes32 indexed subaccount,
        int128 priceX18,
        int128 amount,
        uint64 expiration,
        uint64 nonce,
        // whether this order is taking or making
        bool isTaker,
        // amount paid in fees (in quote)
        int128 feeAmount,
        // change in this subaccount's base balance from this fill
        int128 baseDelta,
        // change in this subaccount's quote balance from this fill
        int128 quoteDelta
    );

    event CloseIsolatedSubaccount(
        bytes32 indexed isolatedSubaccount,
        bytes32 indexed parentSubaccount
    );

    struct FeeRates {
        int64 makerRateX18;
        int64 takerRateX18;
        uint8 isNonDefault; // 1: non-default, 0: default
    }

    struct LpParams {
        int128 lpSpreadX18;
    }

    struct MarketInfoStore {
        int64 minSize;
        int64 sizeIncrement;
        int128 collectedFees;
    }

    struct MarketInfo {
        uint32 quoteId;
        int128 minSize;
        int128 sizeIncrement;
        int128 collectedFees;
    }

    function initialize(address _clearinghouse, address _endpoint) external;

    function updateFeeRates(
        address user,
        uint32 productId,
        int64 makerRateX18,
        int64 takerRateX18
    ) external;

    function updateMarket(
        uint32 productId,
        uint32 quoteId,
        address virtualBook,
        int128 sizeIncrement,
        int128 minSize,
        int128 lpSpreadX18
    ) external;

    function getMinSize(uint32 productId) external view returns (int128);

    function getDigest(uint32 productId, IEndpoint.Order memory order)
        external
        view
        returns (bytes32);

    function getSizeIncrement(uint32 productId) external view returns (int128);

    function getMarketInfo(uint32 productId)
        external
        view
        returns (MarketInfo memory);

    function getLpParams(uint32 productId)
        external
        view
        returns (LpParams memory);

    function swapAMM(IEndpoint.SwapAMM calldata tx) external;

    function matchOrderAMM(
        IEndpoint.MatchOrderAMM calldata tx,
        address takerLinkedSigner
    ) external;

    function matchOrders(IEndpoint.MatchOrdersWithSigner calldata tx) external;

    function dumpFees() external;

    function createIsolatedSubaccount(
        IEndpoint.CreateIsolatedSubaccount memory tx,
        address linkedSigner
    ) external returns (bytes32);

    function isIsolatedSubaccountActive(bytes32 parent, bytes32 subaccount)
        external
        view
        returns (bool);

    function getParentSubaccount(bytes32 subaccount)
        external
        view
        returns (bytes32);

    function tryCloseIsolatedSubaccount(bytes32 subaccount) external;
}
