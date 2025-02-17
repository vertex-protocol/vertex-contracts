// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

import "./clearinghouse/IClearinghouse.sol";

interface IEndpoint {
    event SubmitTransactions();

    event SubmitSlowModeTransaction(
        uint64 executableAt,
        address sender,
        bytes tx
    );

    // events that we parse transactions into
    enum TransactionType {
        LiquidateSubaccount,
        DepositCollateral,
        WithdrawCollateral,
        UpdateTime,
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
        ClaimSequencerFee
    }

    /// requires signature from sender
    enum LiquidationMode {
        SPREAD,
        SPOT,
        PERP
    }

    struct LiquidateSubaccount {
        address sender;
        string subaccountName;
        uint64 liquidateeId;
        uint8 mode;
        uint32 healthGroup;
        int128 amount;
        uint64 nonce;
    }

    struct SignedLiquidateSubaccount {
        LiquidateSubaccount tx;
        bytes signature;
    }

    struct DepositCollateral {
        address sender;
        string subaccountName;
        uint32 productId;
        uint128 amount;
    }

    struct SignedDepositCollateral {
        DepositCollateral tx;
        bytes signature;
    }

    struct WithdrawCollateral {
        address sender;
        string subaccountName;
        uint32 productId;
        uint128 amount;
        uint64 nonce;
    }

    struct SignedWithdrawCollateral {
        WithdrawCollateral tx;
        bytes signature;
    }

    struct MintLp {
        address sender;
        string subaccountName;
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
        address sender;
        string subaccountName;
        uint32 productId;
        uint128 amount;
        uint64 nonce;
    }

    struct SignedBurnLp {
        BurnLp tx;
        bytes signature;
    }

    /// callable by endpoint; no signature verifications needed
    struct UpdateTime {
        uint128 time;
        int128[] avgPriceDiffs;
    }

    struct UpdatePrice {
        uint32 productId;
        int128 priceX18;
        bool isPerpIndex;
    }

    struct SettlePnl {
        uint64[] subaccountIds;
    }

    /// matching
    struct Order {
        address sender;
        string subaccountName;
        int128 priceX18;
        int128 amount;
        uint64 expiration;
        uint64 nonce;
    }

    struct SignedOrder {
        Order order;
        bytes signature;
    }

    struct Cancellation {
        address sender;
        string subaccountName;
        uint32[] productIds;
        bytes32[] digests;
        uint64 nonce;
    }

    struct SignedCancellation {
        Cancellation cancellation;
        bytes signature;
    }

    struct MatchOrders {
        uint32 productId;
        bool amm; // whether taker order should hit AMM first
        SignedOrder taker;
        SignedOrder maker;
    }

    // just swap against AMM -- theres no maker order
    struct MatchOrderAMM {
        uint32 productId;
        SignedOrder taker;
    }

    struct SwapAMM {
        address sender;
        string subaccountName;
        uint32 productId;
        int128 amount;
        int128 priceX18;
    }

    struct DepositInsurance {
        address sender;
        uint128 amount;
    }

    struct SignedDepositInsurance {
        DepositInsurance tx;
        bytes signature;
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

    struct DumpFees {
        uint32 productId;
    }

    function depositCollateral(
        string calldata subaccountName,
        uint32 productId,
        uint128 amount
    ) external;

    function depositInsurance(uint128 amount) external;

    function setBook(uint32 productId, address book) external;

    function submitTransactions(uint64 idx, bytes[] calldata transactions)
        external;

    function submitSlowModeTransaction(bytes calldata transaction) external;

    function getPriceX18(uint32 productId) external view returns (int128);

    function getPerpIndexPriceX18(uint32 productId)
        external
        view
        returns (int128);

    function getTime() external view returns (uint128);

    function getNonce(address sender) external view returns (uint64);
}
