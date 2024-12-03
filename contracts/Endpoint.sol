// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/cryptography/draft-EIP712Upgradeable.sol";
import "./interfaces/IEndpoint.sol";
import "./interfaces/IOffchainExchange.sol";
import "./interfaces/clearinghouse/IClearinghouse.sol";
import "./EndpointGated.sol";
import "./common/Errors.sol";
import "./libraries/ERC20Helper.sol";
import "./libraries/MathHelper.sol";
import "./libraries/Logger.sol";
import "./interfaces/engine/ISpotEngine.sol";
import "./interfaces/engine/IPerpEngine.sol";
import "./interfaces/IERC20Base.sol";
import "./interfaces/IVerifier.sol";

interface ISanctionsList {
    function isSanctioned(address addr) external view returns (bool);
}

contract Endpoint is IEndpoint, EIP712Upgradeable, OwnableUpgradeable {
    using ERC20Helper for IERC20Base;

    IERC20Base private quote; // deprecated
    IClearinghouse public clearinghouse;
    ISpotEngine private spotEngine;
    IPerpEngine private perpEngine;
    ISanctionsList private sanctions;

    address internal sequencer;
    int128 private sequencerFees;

    mapping(bytes32 => uint64) internal subaccountIds;
    mapping(uint64 => bytes32) internal subaccounts;
    uint64 internal numSubaccounts;

    // healthGroup -> (spotPriceX18, perpPriceX18)
    mapping(uint32 => Prices) private pricesX18; // deprecated
    mapping(uint32 => address) private books; // deprecated
    mapping(address => uint64) internal nonces;

    uint64 public nSubmissions;

    SlowModeConfig internal slowModeConfig;
    mapping(uint64 => SlowModeTx) internal slowModeTxs;

    struct Times {
        uint128 perpTime;
        uint128 spotTime;
    }

    Times internal times;

    mapping(uint32 => int128) internal sequencerFee;

    mapping(bytes32 => address) internal linkedSigners;

    int128 private slowModeFees;

    // invitee -> referralCode
    mapping(address => string) public referralCodes;

    // address -> whether can call `BurnLpAndTransfer`.
    mapping(address => bool) internal transferableWallets;

    mapping(uint32 => int128) internal priceX18;
    address internal offchainExchange;

    string internal constant LIQUIDATE_SUBACCOUNT_SIGNATURE =
        "LiquidateSubaccount(bytes32 sender,bytes32 liquidatee,uint32 productId,bool isEncodedSpread,int128 amount,uint64 nonce)";
    string internal constant TRANSFER_QUOTE_SIGNATURE =
        "TransferQuote(bytes32 sender,bytes32 recipient,uint128 amount,uint64 nonce)";
    string internal constant WITHDRAW_COLLATERAL_SIGNATURE =
        "WithdrawCollateral(bytes32 sender,uint32 productId,uint128 amount,uint64 nonce)";
    string internal constant MINT_LP_SIGNATURE =
        "MintLp(bytes32 sender,uint32 productId,uint128 amountBase,uint128 quoteAmountLow,uint128 quoteAmountHigh,uint64 nonce)";
    string internal constant BURN_LP_SIGNATURE =
        "BurnLp(bytes32 sender,uint32 productId,uint128 amount,uint64 nonce)";
    string internal constant LINK_SIGNER_SIGNATURE =
        "LinkSigner(bytes32 sender,bytes32 signer,uint64 nonce)";

    IVerifier private verifier;

    mapping(address => bool) public depositors;

    function _updatePrice(uint32 productId, int128 _priceX18) internal {
        require(_priceX18 > 0, ERR_INVALID_PRICE);
        address engine = clearinghouse.getEngineByProduct(productId);
        if (engine != address(0)) {
            priceX18[productId] = _priceX18;
            IProductEngine(engine).updatePrice(productId, _priceX18);
        }
    }

    function initialize(
        address _sanctions,
        address _sequencer,
        address _offchainExchange,
        IClearinghouse _clearinghouse,
        address _verifier,
        int128[] memory initialPrices
    ) external initializer {
        __Ownable_init();
        __EIP712_init("Vertex", "0.0.1");
        sequencer = _sequencer;
        clearinghouse = _clearinghouse;
        offchainExchange = _offchainExchange;
        verifier = IVerifier(_verifier);
        sanctions = ISanctionsList(_sanctions);
        spotEngine = ISpotEngine(
            clearinghouse.getEngineByType(IProductEngine.EngineType.SPOT)
        );

        perpEngine = IPerpEngine(
            clearinghouse.getEngineByType(IProductEngine.EngineType.PERP)
        );

        quote = IERC20Base(clearinghouse.getQuote());

        slowModeConfig = SlowModeConfig({timeout: 0, txCount: 0, txUpTo: 0});

        for (uint32 i = 0; i < initialPrices.length; i++) {
            priceX18[i] = initialPrices[i];
        }
    }

    // NOTE: we want DepositCollateral to be the first action anybody takes on Vertex
    // so we can record the existence of their subaccount on-chain
    // unfortunately, there are some edge cases where an empty account can place an order
    // or do an AMM swap that passes health checks without going through a deposit, so
    // we block those functions unless there has been a deposit first
    function _recordSubaccount(bytes32 subaccount) internal {
        if (subaccountIds[subaccount] == 0) {
            subaccountIds[subaccount] = ++numSubaccounts;
            subaccounts[numSubaccounts] = subaccount;
        }
    }

    function requireSubaccount(bytes32 subaccount) private view {
        require(
            subaccount == X_ACCOUNT || (subaccountIds[subaccount] != 0),
            ERR_REQUIRES_DEPOSIT
        );
    }

    function validateNonce(bytes32 sender, uint64 nonce) internal virtual {
        require(
            nonce == nonces[address(uint160(bytes20(sender)))]++,
            ERR_WRONG_NONCE
        );
    }

    function chargeFee(bytes32 sender, int128 fee) internal {
        chargeFee(sender, fee, QUOTE_PRODUCT_ID);
    }

    function chargeFee(
        bytes32 sender,
        int128 fee,
        uint32 productId
    ) internal {
        spotEngine.updateBalance(productId, sender, -fee);
        sequencerFee[productId] += fee;
    }

    function chargeSlowModeFee(IERC20Base token, address from)
        internal
        virtual
    {
        require(address(token) != address(0));
        token.safeTransferFrom(
            from,
            address(this),
            clearinghouse.getSlowModeFee()
        );
    }

    function getLinkedSigner(bytes32 subaccount)
        public
        view
        virtual
        returns (address)
    {
        // if (RiskHelper.isFrontendAccount(subaccount)) {
        //     return linkedSigners[RiskHelper.defaultFrontendAccount(subaccount)];
        // } else {
        //     return linkedSigners[subaccount];
        // }
        // NOTE: temp fix to unblock frontend.
        return linkedSigners[subaccount];
    }

    function validateSignature(
        bytes32 sender,
        bytes32 digest,
        bytes memory signature
    ) internal view virtual {
        address recovered = ECDSA.recover(digest, signature);
        require(
            (recovered != address(0)) &&
                ((recovered == address(uint160(bytes20(sender)))) ||
                    (recovered == getLinkedSigner(sender))),
            ERR_INVALID_SIGNATURE
        );
    }

    function safeTransferFrom(
        IERC20Base token,
        address from,
        uint256 amount
    ) internal virtual {
        token.safeTransferFrom(from, address(this), amount);
    }

    function safeTransferTo(
        IERC20Base token,
        address to,
        uint256 amount
    ) internal virtual {
        token.safeTransfer(to, amount);
    }

    function handleDepositTransfer(
        IERC20Base token,
        address from,
        uint256 amount
    ) internal {
        require(address(token) != address(0));
        safeTransferFrom(token, from, amount);
        safeTransferTo(token, address(clearinghouse), amount);
    }

    function validateSender(bytes32 txSender, address sender) internal view {
        require(
            address(uint160(bytes20(txSender))) == sender ||
                sender == address(this),
            ERR_SLOW_MODE_WRONG_SENDER
        );
    }

    function setReferralCode(address sender, string memory referralCode)
        internal
    {
        if (bytes(referralCodes[sender]).length == 0) {
            referralCodes[sender] = referralCode;
        }
    }

    function depositCollateral(
        bytes12 subaccountName,
        uint32 productId,
        uint128 amount
    ) external {
        depositCollateralWithReferral(
            bytes32(abi.encodePacked(msg.sender, subaccountName)),
            productId,
            amount,
            DEFAULT_REFERRAL_CODE
        );
    }

    function depositCollateralWithReferral(
        bytes12 subaccountName,
        uint32 productId,
        uint128 amount,
        string calldata referralCode
    ) external {
        depositCollateralWithReferral(
            bytes32(abi.encodePacked(msg.sender, subaccountName)),
            productId,
            amount,
            referralCode
        );
    }

    function depositCollateralWithReferral(
        bytes32 subaccount,
        uint32 productId,
        uint128 amount,
        string memory referralCode
    ) public {
        require(bytes(referralCode).length != 0, ERR_INVALID_REFERRAL_CODE);

        require(depositors[msg.sender], ERR_DEPOSITOR_NOT_ENABLED);

        address sender = address(bytes20(subaccount));

        // depositor / depositee need to be unsanctioned
        requireUnsanctioned(msg.sender);
        requireUnsanctioned(sender);

        // no referral code allowed for remote deposit
        setReferralCode(
            sender,
            sender == msg.sender ? referralCode : DEFAULT_REFERRAL_CODE
        );

        if (subaccount != X_ACCOUNT && (subaccountIds[subaccount] == 0)) {
            clearinghouse.requireMinDeposit(productId, amount);
        }

        handleDepositTransfer(
            IERC20Base(spotEngine.getToken(productId)),
            msg.sender,
            uint256(amount)
        );
        // copy from submitSlowModeTransaction
        SlowModeConfig memory _slowModeConfig = slowModeConfig;

        slowModeTxs[_slowModeConfig.txCount++] = SlowModeTx({
            executableAt: uint64(block.timestamp) + 259200, // hardcoded to three days
            sender: sender,
            tx: abi.encodePacked(
                uint8(TransactionType.DepositCollateral),
                abi.encode(
                    DepositCollateral({
                        sender: subaccount,
                        productId: productId,
                        amount: amount
                    })
                )
            )
        });
        slowModeConfig = _slowModeConfig;
    }

    function requireUnsanctioned(address sender) internal view virtual {
        require(!sanctions.isSanctioned(sender), ERR_WALLET_SANCTIONED);
    }

    function submitSlowModeTransaction(bytes calldata transaction) external {
        TransactionType txType = TransactionType(uint8(transaction[0]));

        // special case for DepositCollateral because upon
        // slow mode submission we must take custody of the
        // actual funds

        address sender = msg.sender;

        if (txType == TransactionType.DepositCollateral) {
            revert();
        } else if (txType == TransactionType.DepositInsurance) {
            DepositInsurance memory txn = abi.decode(
                transaction[1:],
                (DepositInsurance)
            );
            handleDepositTransfer(_getQuote(), sender, uint256(txn.amount));
        } else if (txType == TransactionType.UpdateProduct) {
            require(sender == owner());
        } else if (txType == TransactionType.BurnLpAndTransfer) {
            require(transferableWallets[sender], ERR_WALLET_NOT_TRANSFERABLE);
            BurnLpAndTransfer memory txn = abi.decode(
                transaction[1:],
                (BurnLpAndTransfer)
            );
            setReferralCode(
                address(uint160(bytes20(txn.recipient))),
                DEFAULT_REFERRAL_CODE
            );
        } else if (txType == TransactionType.WithdrawInsurance) {
            require(sender == owner());
        } else {
            chargeSlowModeFee(_getQuote(), sender);
            slowModeFees += SLOW_MODE_FEE;
        }

        SlowModeConfig memory _slowModeConfig = slowModeConfig;
        requireUnsanctioned(sender);
        slowModeTxs[_slowModeConfig.txCount++] = SlowModeTx({
            executableAt: uint64(block.timestamp) + 259200, // hardcoded to three days
            sender: sender,
            tx: transaction
        });
        // TODO: to save on costs we could potentially just emit something
        // for now, we can just create a separate loop in the engine that queries the remote
        // sequencer for slow mode transactions, and ignore the possibility of a reorgy attack
        slowModeConfig = _slowModeConfig;
    }

    function _executeSlowModeTransaction(
        SlowModeConfig memory _slowModeConfig,
        bool fromSequencer
    ) internal {
        require(
            _slowModeConfig.txUpTo < _slowModeConfig.txCount,
            ERR_NO_SLOW_MODE_TXS_REMAINING
        );
        SlowModeTx memory txn = slowModeTxs[_slowModeConfig.txUpTo];
        delete slowModeTxs[_slowModeConfig.txUpTo++];

        require(
            fromSequencer || (txn.executableAt <= block.timestamp),
            ERR_SLOW_TX_TOO_RECENT
        );

        uint256 gasRemaining = gasleft();
        try this.processSlowModeTransaction(txn.sender, txn.tx) {} catch {
            // we need to differentiate between a revert and an out of gas
            // the issue is that in evm every inner call only 63/64 of the
            // remaining gas in the outer frame is forwarded. as a result
            // the amount of gas left for execution is (63/64)**len(stack)
            // and you can get an out of gas while spending an arbitrarily
            // low amount of gas in the final frame. we use a heuristic
            // here that isn't perfect but covers our cases.
            // having gasleft() <= gasRemaining / 2 buys us 44 nested calls
            // before we miss out of gas errors; 1/2 ~= (63/64)**44
            // this is good enough for our purposes

            if (gasleft() <= 250000 || gasleft() <= gasRemaining / 2) {
                assembly {
                    invalid()
                }
            }

            // try return funds now removed
        }
    }

    function executeSlowModeTransaction() external {
        SlowModeConfig memory _slowModeConfig = slowModeConfig;
        _executeSlowModeTransaction(_slowModeConfig, false);
        slowModeConfig = _slowModeConfig;
    }

    // TODO: these do not need senders or nonces
    // we can save some gas by creating new structs
    function processSlowModeTransaction(
        address sender,
        bytes calldata transaction
    ) public {
        require(msg.sender == address(this));
        TransactionType txType = TransactionType(uint8(transaction[0]));
        if (txType == TransactionType.LiquidateSubaccount) {
            LiquidateSubaccount memory txn = abi.decode(
                transaction[1:],
                (LiquidateSubaccount)
            );
            validateSender(txn.sender, sender);
            requireSubaccount(txn.sender);
            clearinghouse.liquidateSubaccount(txn);
        } else if (txType == TransactionType.DepositCollateral) {
            DepositCollateral memory txn = abi.decode(
                transaction[1:],
                (DepositCollateral)
            );
            validateSender(txn.sender, sender);
            _recordSubaccount(txn.sender);
            clearinghouse.depositCollateral(txn);
        } else if (txType == TransactionType.WithdrawCollateral) {
            WithdrawCollateral memory txn = abi.decode(
                transaction[1:],
                (WithdrawCollateral)
            );

            validateSender(txn.sender, sender);
            clearinghouse.withdrawCollateral(
                txn.sender,
                txn.productId,
                txn.amount,
                address(0),
                nSubmissions
            );
        } else if (txType == TransactionType.SettlePnl) {
            clearinghouse.settlePnl(transaction);
        } else if (txType == TransactionType.DepositInsurance) {
            clearinghouse.depositInsurance(transaction);
        } else if (txType == TransactionType.MintLp) {
            MintLp memory txn = abi.decode(transaction[1:], (MintLp));
            require(
                clearinghouse.getEngineByProduct(txn.productId) ==
                    clearinghouse.getEngineByType(
                        IProductEngine.EngineType.SPOT
                    ),
                ERR_INVALID_PRODUCT
            );
            validateSender(txn.sender, sender);
            clearinghouse.mintLp(txn);
        } else if (txType == TransactionType.BurnLp) {
            BurnLp memory txn = abi.decode(transaction[1:], (BurnLp));
            validateSender(txn.sender, sender);
            clearinghouse.burnLp(txn);
        } else if (txType == TransactionType.SwapAMM) {
            SwapAMM memory txn = abi.decode(transaction[1:], (SwapAMM));
            validateSender(txn.sender, sender);
            requireSubaccount(txn.sender);
            IOffchainExchange(offchainExchange).swapAMM(txn);
        } else if (txType == TransactionType.UpdateProduct) {
            UpdateProduct memory txn = abi.decode(
                transaction[1:],
                (UpdateProduct)
            );
            IProductEngine(txn.engine).updateProduct(txn.tx);
        } else if (txType == TransactionType.LinkSigner) {
            LinkSigner memory txn = abi.decode(transaction[1:], (LinkSigner));
            validateSender(txn.sender, sender);
            requireSubaccount(txn.sender);
            linkedSigners[txn.sender] = address(uint160(bytes20(txn.signer)));
        } else if (txType == TransactionType.BurnLpAndTransfer) {
            BurnLpAndTransfer memory txn = abi.decode(
                transaction[1:],
                (BurnLpAndTransfer)
            );
            validateSender(txn.sender, sender);
            _recordSubaccount(txn.recipient);
            clearinghouse.burnLpAndTransfer(txn);
        } else if (txType == TransactionType.WithdrawInsurance) {
            clearinghouse.withdrawInsurance(transaction, nSubmissions);
        } else {
            revert();
        }
    }

    function processTransaction(bytes calldata transaction) internal {
        TransactionType txType = TransactionType(uint8(transaction[0]));
        if (txType == TransactionType.LiquidateSubaccount) {
            SignedLiquidateSubaccount memory signedTx = abi.decode(
                transaction[1:],
                (SignedLiquidateSubaccount)
            );
            validateNonce(signedTx.tx.sender, signedTx.tx.nonce);
            validateSignature(
                signedTx.tx.sender,
                _hashTypedDataV4(
                    keccak256(
                        abi.encode(
                            keccak256(bytes(LIQUIDATE_SUBACCOUNT_SIGNATURE)),
                            signedTx.tx.sender,
                            signedTx.tx.liquidatee,
                            signedTx.tx.productId,
                            signedTx.tx.isEncodedSpread,
                            signedTx.tx.amount,
                            signedTx.tx.nonce
                        )
                    )
                ),
                signedTx.signature
            );
            requireSubaccount(signedTx.tx.sender);
            chargeFee(signedTx.tx.sender, LIQUIDATION_FEE);
            clearinghouse.liquidateSubaccount(signedTx.tx);
        } else if (txType == TransactionType.WithdrawCollateral) {
            SignedWithdrawCollateral memory signedTx = abi.decode(
                transaction[1:],
                (SignedWithdrawCollateral)
            );
            validateNonce(signedTx.tx.sender, signedTx.tx.nonce);
            validateSignature(
                signedTx.tx.sender,
                _hashTypedDataV4(
                    keccak256(
                        abi.encode(
                            keccak256(bytes(WITHDRAW_COLLATERAL_SIGNATURE)),
                            signedTx.tx.sender,
                            signedTx.tx.productId,
                            signedTx.tx.amount,
                            signedTx.tx.nonce
                        )
                    )
                ),
                signedTx.signature
            );
            chargeFee(
                signedTx.tx.sender,
                spotEngine.getWithdrawFee(signedTx.tx.productId),
                signedTx.tx.productId
            );
            clearinghouse.withdrawCollateral(
                signedTx.tx.sender,
                signedTx.tx.productId,
                signedTx.tx.amount,
                address(0),
                nSubmissions
            );
        } else if (txType == TransactionType.SpotTick) {
            SpotTick memory txn = abi.decode(transaction[1:], (SpotTick));
            Times memory t = times;
            uint128 dt = t.spotTime == 0 ? 0 : txn.time - t.spotTime;
            spotEngine.updateStates(dt);
            t.spotTime = txn.time;
            times = t;
        } else if (txType == TransactionType.PerpTick) {
            PerpTick memory txn = abi.decode(transaction[1:], (PerpTick));
            Times memory t = times;
            uint128 dt = t.perpTime == 0 ? 0 : txn.time - t.perpTime;
            perpEngine.updateStates(dt, txn.avgPriceDiffs);
            t.perpTime = txn.time;
            times = t;
        } else if (txType == TransactionType.UpdatePrice) {
            UpdatePrice memory txn = abi.decode(transaction[1:], (UpdatePrice));
            _updatePrice(txn.productId, txn.priceX18);
        } else if (txType == TransactionType.SettlePnl) {
            clearinghouse.settlePnl(transaction);
        } else if (
            txType == TransactionType.MatchOrders ||
            txType == TransactionType.MatchOrdersRFQ
        ) {
            MatchOrders memory txn = abi.decode(transaction[1:], (MatchOrders));
            requireSubaccount(txn.taker.order.sender);
            requireSubaccount(txn.maker.order.sender);
            MatchOrdersWithSigner memory txnWithSigner = MatchOrdersWithSigner({
                matchOrders: txn,
                takerLinkedSigner: getLinkedSigner(txn.taker.order.sender),
                makerLinkedSigner: getLinkedSigner(txn.maker.order.sender)
            });
            IOffchainExchange(offchainExchange).matchOrders(txnWithSigner);
        } else if (txType == TransactionType.MatchOrderAMM) {
            MatchOrderAMM memory txn = abi.decode(
                transaction[1:],
                (MatchOrderAMM)
            );
            requireSubaccount(txn.taker.order.sender);
            IOffchainExchange(offchainExchange).matchOrderAMM(
                txn,
                getLinkedSigner(txn.taker.order.sender)
            );
        } else if (txType == TransactionType.ExecuteSlowMode) {
            SlowModeConfig memory _slowModeConfig = slowModeConfig;
            _executeSlowModeTransaction(_slowModeConfig, true);
            slowModeConfig = _slowModeConfig;
        } else if (txType == TransactionType.MintLp) {
            SignedMintLp memory signedTx = abi.decode(
                transaction[1:],
                (SignedMintLp)
            );
            validateNonce(signedTx.tx.sender, signedTx.tx.nonce);
            validateSignature(
                signedTx.tx.sender,
                _hashTypedDataV4(
                    keccak256(
                        abi.encode(
                            keccak256(bytes(MINT_LP_SIGNATURE)),
                            signedTx.tx.sender,
                            signedTx.tx.productId,
                            signedTx.tx.amountBase,
                            signedTx.tx.quoteAmountLow,
                            signedTx.tx.quoteAmountHigh,
                            signedTx.tx.nonce
                        )
                    )
                ),
                signedTx.signature
            );
            chargeFee(signedTx.tx.sender, HEALTHCHECK_FEE);
            clearinghouse.mintLp(signedTx.tx);
        } else if (txType == TransactionType.BurnLp) {
            SignedBurnLp memory signedTx = abi.decode(
                transaction[1:],
                (SignedBurnLp)
            );
            validateNonce(signedTx.tx.sender, signedTx.tx.nonce);
            validateSignature(
                signedTx.tx.sender,
                _hashTypedDataV4(
                    keccak256(
                        abi.encode(
                            keccak256(bytes(BURN_LP_SIGNATURE)),
                            signedTx.tx.sender,
                            signedTx.tx.productId,
                            signedTx.tx.amount,
                            signedTx.tx.nonce
                        )
                    )
                ),
                signedTx.signature
            );
            chargeFee(signedTx.tx.sender, HEALTHCHECK_FEE);
            clearinghouse.burnLp(signedTx.tx);
        } else if (txType == TransactionType.DumpFees) {
            IOffchainExchange(offchainExchange).dumpFees();
        } else if (txType == TransactionType.ClaimSequencerFees) {
            ClaimSequencerFees memory txn = abi.decode(
                transaction[1:],
                (ClaimSequencerFees)
            );
            uint32[] memory spotIds = spotEngine.getProductIds();
            int128[] memory fees = new int128[](spotIds.length);
            for (uint256 i = 0; i < spotIds.length; i++) {
                fees[i] = sequencerFee[spotIds[i]];
                sequencerFee[spotIds[i]] = 0;
            }
            requireSubaccount(txn.subaccount);
            clearinghouse.claimSequencerFees(txn, fees);
        } else if (txType == TransactionType.ManualAssert) {
            clearinghouse.manualAssert(transaction);
        } else if (txType == TransactionType.LinkSigner) {
            SignedLinkSigner memory signedTx = abi.decode(
                transaction[1:],
                (SignedLinkSigner)
            );
            validateNonce(signedTx.tx.sender, signedTx.tx.nonce);
            validateSignature(
                signedTx.tx.sender,
                _hashTypedDataV4(
                    keccak256(
                        abi.encode(
                            keccak256(bytes(LINK_SIGNER_SIGNATURE)),
                            signedTx.tx.sender,
                            signedTx.tx.signer,
                            signedTx.tx.nonce
                        )
                    )
                ),
                signedTx.signature
            );
            linkedSigners[signedTx.tx.sender] = address(
                uint160(bytes20(signedTx.tx.signer))
            );
        } else if (txType == TransactionType.UpdateFeeRates) {
            UpdateFeeRates memory txn = abi.decode(
                transaction[1:],
                (UpdateFeeRates)
            );
            IOffchainExchange(offchainExchange).updateFeeRates(
                txn.user,
                txn.productId,
                txn.makerRateX18,
                txn.takerRateX18
            );
        } else if (txType == TransactionType.TransferQuote) {
            SignedTransferQuote memory signedTx = abi.decode(
                transaction[1:],
                (SignedTransferQuote)
            );
            _recordSubaccount(signedTx.tx.recipient);
            validateSignature(
                signedTx.tx.sender,
                _hashTypedDataV4(
                    keccak256(
                        abi.encode(
                            keccak256(bytes(TRANSFER_QUOTE_SIGNATURE)),
                            signedTx.tx.sender,
                            signedTx.tx.recipient,
                            signedTx.tx.amount,
                            signedTx.tx.nonce
                        )
                    )
                ),
                signedTx.signature
            );
            validateNonce(signedTx.tx.sender, signedTx.tx.nonce);
            chargeFee(signedTx.tx.sender, HEALTHCHECK_FEE);
            clearinghouse.transferQuote(signedTx.tx);
        } else if (txType == TransactionType.RebalanceXWithdraw) {
            RebalanceXWithdraw memory txn = abi.decode(
                transaction[1:],
                (RebalanceXWithdraw)
            );

            clearinghouse.withdrawCollateral(
                X_ACCOUNT,
                txn.productId,
                txn.amount,
                txn.sendTo,
                nSubmissions
            );
        } else if (txType == TransactionType.UpdateMinDepositRate) {
            UpdateMinDepositRate memory txn = abi.decode(
                transaction[1:],
                (UpdateMinDepositRate)
            );

            spotEngine.updateMinDepositRate(
                txn.productId,
                txn.minDepositRateX18
            );
        } else if (txType == TransactionType.AssertCode) {
            clearinghouse.assertCode(transaction);
        } else {
            revert();
        }
    }

    function submitTransactionsChecked(
        uint64 idx,
        bytes[] calldata transactions,
        bytes32 e,
        bytes32 s,
        uint8 signerBitmask
    ) external {
        require(idx == nSubmissions, ERR_INVALID_SUBMISSION_INDEX);
        require(msg.sender == sequencer);
        // TODO: if one of these transactions fails this means the sequencer is in an error state
        // we should probably record this, and engage some sort of recovery mode

        bytes32 digest = keccak256(abi.encode(idx));
        for (uint256 i = 0; i < transactions.length; ++i) {
            digest = keccak256(abi.encodePacked(digest, transactions[i]));
        }
        verifier.requireValidSignature(digest, e, s, signerBitmask);

        for (uint256 i = 0; i < transactions.length; i++) {
            bytes calldata transaction = transactions[i];
            processTransaction(transaction);
            nSubmissions += 1;
        }
    }

    function submitTransactionsCheckedWithGasLimit(
        uint64 idx,
        bytes[] calldata transactions,
        uint256 gasLimit
    ) external {
        uint256 gasUsed = gasleft();
        require(idx == nSubmissions, ERR_INVALID_SUBMISSION_INDEX);
        for (uint256 i = 0; i < transactions.length; i++) {
            bytes calldata transaction = transactions[i];
            processTransaction(transaction);
            if (gasUsed - gasleft() > gasLimit) {
                verifier.revertGasInfo(i, gasUsed);
            }
        }
        verifier.revertGasInfo(transactions.length, gasUsed - gasleft());
    }

    function getSubaccountId(bytes32 subaccount)
        external
        view
        returns (uint64)
    {
        return subaccountIds[subaccount];
    }

    function _getQuote() internal view returns (IERC20Base) {
        return IERC20Base(spotEngine.getToken(QUOTE_PRODUCT_ID));
    }

    function getPriceX18(uint32 productId)
        public
        view
        returns (int128 _priceX18)
    {
        _priceX18 = priceX18[productId];
        require(_priceX18 != 0, ERR_INVALID_PRODUCT);
    }

    function getTime() external view returns (uint128) {
        Times memory t = times;
        uint128 _time = t.spotTime > t.perpTime ? t.spotTime : t.perpTime;
        require(_time != 0, ERR_INVALID_TIME);
        return _time;
    }

    function getOffchainExchange() external view returns (address) {
        return offchainExchange;
    }

    function getSequencer() external view returns (address) {
        return sequencer;
    }

    function getSlowModeTx(uint64 idx)
        external
        view
        returns (
            SlowModeTx memory,
            uint64,
            uint64
        )
    {
        return (
            slowModeTxs[idx],
            slowModeConfig.txUpTo,
            slowModeConfig.txCount
        );
    }

    function getNonce(address sender) external view returns (uint64) {
        return nonces[sender];
    }

    function updateSanctions(address _sanctions) external onlyOwner {
        sanctions = ISanctionsList(_sanctions);
    }

    function updateDepositor(address _depositor, bool _enabled) external onlyOwner {
        depositors[_depositor] = _enabled;
    }
}
