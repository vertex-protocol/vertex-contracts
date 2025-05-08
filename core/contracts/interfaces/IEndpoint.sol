// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

import "./clearinghouse/IClearinghouse.sol";

interface IEndpoint {
    event SubmitTransactions();

    // events that we parse transactions into
    enum TransactionType {
        LiquidateSubaccount,
        DepositCollateral,
        WithdrawCollateral,
        SpotTick,
        UpdatePrice,
        SettlePnl,
        MatchOrders,
        DepositInsurance,
        ExecuteSlowMode,
        MintLp,
        BurnLp,
        SwapAMM,
        MatchOrderAMM,
        DumpFees,
        ClaimSequencerFees, // deprecated
        PerpTick,
        ManualAssert,
        Rebate, // deprecated
        UpdateProduct,
        LinkSigner,
        UpdateFeeRates,
        BurnLpAndTransfer,
        MatchOrdersRFQ,
        TransferQuote,
        RebalanceXWithdraw,
        UpdateMinDepositRate,
        AssertCode,
        WithdrawInsurance,
        CreateIsolatedSubaccount,
        DelistProduct,
        MintVlp,
        BurnVlp,
        RebalanceVlp
    }

    struct UpdateProduct {
        address engine;
        bytes tx;
    }

    /// requires signature from sender
    enum LiquidationMode {
        SPREAD,
        SPOT,
        PERP
    }

    struct LegacyLiquidateSubaccount {
        bytes32 sender;
        bytes32 liquidatee;
        uint8 mode;
        uint32 healthGroup;
        int128 amount;
        uint64 nonce;
    }

    struct LiquidateSubaccount {
        bytes32 sender;
        bytes32 liquidatee;
        uint32 productId;
        bool isEncodedSpread;
        int128 amount;
        uint64 nonce;
    }

    struct LegacySignedLiquidateSubaccount {
        LegacyLiquidateSubaccount tx;
        bytes signature;
    }

    struct SignedLiquidateSubaccount {
        LiquidateSubaccount tx;
        bytes signature;
    }

    struct DepositCollateral {
        bytes32 sender;
        uint32 productId;
        uint128 amount;
    }

    struct SignedDepositCollateral {
        DepositCollateral tx;
        bytes signature;
    }

    struct WithdrawCollateral {
        bytes32 sender;
        uint32 productId;
        uint128 amount;
        uint64 nonce;
    }

    struct SignedWithdrawCollateral {
        WithdrawCollateral tx;
        bytes signature;
    }

    struct MintLp {
        bytes32 sender;
        uint32 productId;
        uint128 amountBase;
        uint128 quoteAmountLow;
        uint128 quoteAmountHigh;
        uint64 nonce;
    }

    struct SignedMintLp {
        MintLp tx;
        bytes signature;
    }

    struct BurnLp {
        bytes32 sender;
        uint32 productId;
        uint128 amount;
        uint64 nonce;
    }

    struct SignedBurnLp {
        BurnLp tx;
        bytes signature;
    }

    struct MintVlp {
        bytes32 sender;
        uint128 quoteAmount;
        uint64 nonce;
    }

    struct SignedMintVlp {
        MintVlp tx;
        bytes signature;
        int128 oraclePriceX18;
    }

    struct BurnVlp {
        bytes32 sender;
        uint128 vlpAmount;
        uint64 nonce;
    }

    struct SignedBurnVlp {
        BurnVlp tx;
        bytes signature;
        int128 oraclePriceX18;
    }

    struct RebalanceVlp {
        uint32 productId;
        int128 baseAmount;
        int128 quoteAmount;
    }

    struct LinkSigner {
        bytes32 sender;
        bytes32 signer;
        uint64 nonce;
    }

    struct SignedLinkSigner {
        LinkSigner tx;
        bytes signature;
    }

    /// callable by endpoint; no signature verifications needed
    struct PerpTick {
        uint128 time;
        int128[] avgPriceDiffs;
    }

    struct LegacySpotTick {
        uint128 time;
    }

    struct SpotTick {
        uint128 time;
        // utilization ratio across all chains
        int128[] utilizationRatiosX18;
    }

    struct ManualAssert {
        int128[] openInterests;
        int128[] totalDeposits;
        int128[] totalBorrows;
    }

    struct AssertCode {
        string[] contractNames;
        bytes32[] codeHashes;
    }

    struct WithdrawInsurance {
        uint128 amount;
        address sendTo;
    }

    struct DelistProduct {
        uint32 productId;
        int128 priceX18;
        bytes32[] subaccounts;
    }

    struct Rebate {
        bytes32[] subaccounts;
        int128[] amounts;
    }

    struct UpdateFeeRates {
        address user;
        uint32 productId;
        // the absolute value of fee rates can't be larger than 100%,
        // so their X18 values are in the range [-1e18, 1e18], which
        // can be stored by using int64.
        int64 makerRateX18;
        int64 takerRateX18;
    }

    struct ClaimSequencerFees {
        bytes32 subaccount;
    }

    struct RebalanceXWithdraw {
        uint32 productId;
        uint128 amount;
        address sendTo;
    }

    struct UpdateMinDepositRate {
        uint32 productId;
        int128 minDepositRateX18;
    }

    struct UpdatePrice {
        uint32 productId;
        int128 priceX18;
    }

    struct SettlePnl {
        bytes32[] subaccounts;
        uint256[] productIds;
    }

    /// matching
    struct Order {
        bytes32 sender;
        int128 priceX18;
        int128 amount;
        uint64 expiration;
        uint64 nonce;
    }

    struct SignedOrder {
        Order order;
        bytes signature;
    }

    struct LegacyMatchOrders {
        uint32 productId;
        bool amm;
        SignedOrder taker;
        SignedOrder maker;
    }

    struct MatchOrders {
        uint32 productId;
        SignedOrder taker;
        SignedOrder maker;
    }

    struct MatchOrdersWithSigner {
        MatchOrders matchOrders;
        address takerLinkedSigner;
        address makerLinkedSigner;
    }

    // just swap against AMM -- theres no maker order
    struct MatchOrderAMM {
        uint32 productId;
        int128 baseDelta;
        int128 quoteDelta;
        SignedOrder taker;
    }

    struct SwapAMM {
        bytes32 sender;
        uint32 productId;
        int128 amount;
        int128 priceX18;
    }

    struct DepositInsurance {
        uint128 amount;
    }

    struct SlowModeTx {
        uint64 executableAt;
        address sender;
        bytes tx;
    }

    struct SlowModeConfig {
        uint64 timeout;
        uint64 txCount;
        uint64 txUpTo;
    }

    // legacy :(
    struct Prices {
        int128 spotPriceX18;
        int128 perpPriceX18;
    }

    struct BurnLpAndTransfer {
        bytes32 sender;
        uint32 productId;
        uint128 amount;
        bytes32 recipient;
    }

    struct TransferQuote {
        bytes32 sender;
        bytes32 recipient;
        uint128 amount;
        uint64 nonce;
    }

    struct SignedTransferQuote {
        TransferQuote tx;
        bytes signature;
    }

    struct IsolatedOrder {
        bytes32 sender;
        int128 priceX18;
        int128 amount;
        uint64 expiration;
        uint64 nonce;
        int128 margin;
    }

    struct CreateIsolatedSubaccount {
        IsolatedOrder order;
        uint32 productId;
        bytes signature;
    }

    function depositCollateral(
        bytes12 subaccountName,
        uint32 productId,
        uint128 amount
    ) external;

    function depositCollateralWithReferral(
        bytes12 subaccountName,
        uint32 productId,
        uint128 amount,
        string calldata referralCode
    ) external;

    function depositCollateralWithReferral(
        bytes32 subaccount,
        uint32 productId,
        uint128 amount,
        string calldata referralCode
    ) external;

    function submitSlowModeTransaction(bytes calldata transaction) external;

    function getTime() external view returns (uint128);

    function getSequencer() external view returns (address);

    function getNonce(address sender) external view returns (uint64);

    function getOffchainExchange() external view returns (address);

    function getPriceX18(uint32 productId) external view returns (int128);
}
