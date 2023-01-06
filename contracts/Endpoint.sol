// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/cryptography/draft-EIP712Upgradeable.sol";
import "./interfaces/IEndpoint.sol";
import "./interfaces/clearinghouse/IClearinghouse.sol";
import "./interfaces/IOffchainBook.sol";
import "./EndpointGated.sol";
import "./common/Errors.sol";
import "./libraries/ERC20Helper.sol";
import "./interfaces/IEndpoint.sol";
import "./interfaces/engine/ISpotEngine.sol";
import "./interfaces/IERC20Base.sol";

contract Endpoint is IEndpoint, EIP712Upgradeable, OwnableUpgradeable {
    using ERC20Helper for IERC20Base;

    IClearinghouse public clearinghouse;
    address sequencer;
    uint256 private time;

    // engine -> last time updateStates was called
    mapping(address => uint256) lastUpdated;
    mapping(uint32 => int256) prices;
    mapping(uint32 => address) books;
    mapping(address => uint64) nonces;

    uint64 public nSubmissions;

    SlowModeConfig public slowModeConfig;
    mapping(uint64 => SlowModeTx) public slowModeTxs;

    string constant LIQUIDATE_SUBACCOUNT_SIGNATURE =
        "LiquidateSubaccount(address sender,string subaccountName,uint64 liquidateeId,uint8 mode,uint32 healthGroup,int256 amount,uint64 nonce)";
    string constant WITHDRAW_COLLATERAL_SIGNATURE =
        "WithdrawCollateral(address sender,string subaccountName,uint32 productId,uint256 amount,uint64 nonce)";
    string constant DEPOSIT_INSURANCE_SIGNATURE =
        "DepositInsurance(address sender,uint256 amount,uint64 nonce)";
    string constant MINT_LP_SIGNATURE =
        "MintLp(address sender,string subaccountName,uint32 productId,uint256 amountBase,uint256 quoteAmountLow,uint256 quoteAmountHigh,uint64 nonce)";
    string constant BURN_LP_SIGNATURE =
        "BurnLp(address sender,string subaccountName,uint32 productId,uint256 amount,uint64 nonce)";

    function initialize(
        address _sequencer,
        IClearinghouse _clearinghouse,
        uint64 slowModeTimeout,
        uint256 _time,
        int256[] memory _prices
    ) external initializer {
        __Ownable_init();
        __EIP712_init("Vertex", "0.0.1");
        sequencer = _sequencer;
        clearinghouse = _clearinghouse;
        slowModeConfig = SlowModeConfig({
            timeout: slowModeTimeout,
            txCount: 0,
            txUpTo: 0
        });
        time = _time;
        for (uint32 i = 0; i < _prices.length; i++) {
            prices[i + 1] = _prices[i];
        }
    }

    function validateNonce(address sender, uint64 nonce) internal {
        require(nonce == nonces[sender]++, "Invalid nonce");
    }

    function validateSignature(
        address signer,
        bytes32 digest,
        bytes memory signature
    ) internal view virtual {
        address recovered = ECDSA.recover(digest, signature);
        require(
            (recovered != address(0)) && (recovered == signer),
            ERR_INVALID_SIGNATURE
        );
    }

    function handleDepositTransfer(
        IERC20Base token,
        address from,
        uint256 amount
    ) internal virtual {
        token.increaseAllowance(address(clearinghouse), amount);
        token.safeTransferFrom(from, address(this), amount);
    }

    function validateSender(address txSender, address sender) internal view {
        require(
            txSender == sender || txSender == address(this),
            "cannot send slow mode transaction for another address"
        );
    }

    function depositCollateral(
        string calldata subaccountName,
        uint32 productId,
        uint256 amount
    ) external {
        require(bytes(subaccountName).length <= 12, ERR_LONG_NAME);
        DepositCollateral memory txn = DepositCollateral({
            sender: msg.sender,
            subaccountName: subaccountName,
            productId: productId,
            amount: amount
        });

        bytes memory encodedTx = abi.encode(txn);
        bytes memory transaction = abi.encodePacked(
            uint8(TransactionType.DepositCollateral),
            encodedTx
        );

        this.submitSlowModeTransaction(transaction);
    }

    function depositInsurance(uint256 amount) external {
        DepositInsurance memory txn = DepositInsurance({
            sender: msg.sender,
            amount: amount
        });

        bytes memory encodedTx = abi.encode(txn);
        bytes memory transaction = abi.encodePacked(
            uint8(TransactionType.DepositInsurance),
            encodedTx
        );

        this.submitSlowModeTransaction(transaction);
    }

    function submitSlowModeTransaction(bytes calldata transaction) external {
        // TODO: require a bond from the sender except in the case of a deposit
        // this bond is returned to the executor of the slow mode transaction
        TransactionType txType = TransactionType(uint8(transaction[0]));

        // special case for DepositCollateral because upon
        // slow mode submission we must take custody of the
        // actual funds

        address sender = msg.sender;

        if (txType == TransactionType.DepositCollateral) {
            DepositCollateral memory txn = abi.decode(
                transaction[1:],
                (DepositCollateral)
            );
            sender = txn.sender;
            validateSender(msg.sender, sender);
            // TODO: probably save spotEngine in state directly
            // so the gas is less retarded
            ISpotEngine spotEngine = ISpotEngine(
                clearinghouse.getEngineByType(IProductEngine.EngineType.SPOT)
            );
            // transfer tokens from tx sender to here
            IERC20Base token = IERC20Base(
                spotEngine.getConfig(txn.productId).token
            );
            handleDepositTransfer(token, sender, txn.amount);
        } else if (txType == TransactionType.DepositInsurance) {
            DepositInsurance memory txn = abi.decode(
                transaction[1:],
                (DepositInsurance)
            );
            sender = txn.sender;
            validateSender(msg.sender, sender);
            ISpotEngine spotEngine = ISpotEngine(
                clearinghouse.getEngineByType(IProductEngine.EngineType.SPOT)
            );
            IERC20Base token = IERC20Base(clearinghouse.getQuote());
            handleDepositTransfer(token, sender, txn.amount);
        }

        SlowModeConfig memory _slowModeConfig = slowModeConfig;
        uint64 executableAt = uint64(block.timestamp) + _slowModeConfig.timeout;
        slowModeTxs[_slowModeConfig.txCount++] = SlowModeTx({
            executableAt: executableAt,
            sender: sender,
            tx: transaction
        });
        // TODO: to save on costs we could potentially just emit something

        // for now, we can just create a separate loop in the engine that queries the remote
        // sequencer for slow mode transactions, and ignore the possibility of a reorgy attack
        slowModeConfig = _slowModeConfig;

        emit SubmitSlowModeTransaction(executableAt, sender, transaction);
    }

    function _executeSlowModeTransaction(
        SlowModeConfig memory _slowModeConfig,
        bool fromSequencer
    ) internal {
        require(
            _slowModeConfig.txUpTo < _slowModeConfig.txCount,
            "no slow mode transactions remaining"
        );
        SlowModeTx memory txn = slowModeTxs[_slowModeConfig.txUpTo];
        delete slowModeTxs[_slowModeConfig.txUpTo++];

        require(
            fromSequencer || (txn.executableAt <= block.timestamp),
            "oldest slow mode tx cannot be executed yet"
        );

        try this.processSlowModeTransaction(txn.sender, txn.tx) {} catch {
            try this.processSlowModeTransaction(txn.sender, txn.tx) {} catch {}
        }
    }

    function executeSlowModeTransactions(uint32 count) external {
        SlowModeConfig memory _slowModeConfig = slowModeConfig;
        require(
            count <= _slowModeConfig.txCount - _slowModeConfig.txUpTo,
            "invalid count provided"
        );

        while (count > 0) {
            _executeSlowModeTransaction(_slowModeConfig, false);
            --count;
        }
        slowModeConfig = _slowModeConfig;
    }

    // TODO: these do not need senders or nonces
    // we can save some gas by creating new structs
    function processSlowModeTransaction(
        address sender,
        bytes calldata transaction
    ) public {
        require(
            msg.sender == address(this),
            "only callable to execute slow mode txs"
        );
        TransactionType txType = TransactionType(uint8(transaction[0]));
        if (txType == TransactionType.LiquidateSubaccount) {
            LiquidateSubaccount memory txn = abi.decode(
                transaction[1:],
                (LiquidateSubaccount)
            );
            validateSender(txn.sender, sender);
            clearinghouse.liquidateSubaccount(txn);
        } else if (txType == TransactionType.DepositCollateral) {
            DepositCollateral memory txn = abi.decode(
                transaction[1:],
                (DepositCollateral)
            );
            validateSender(txn.sender, sender);
            clearinghouse.depositCollateral(txn);
        } else if (txType == TransactionType.WithdrawCollateral) {
            WithdrawCollateral memory txn = abi.decode(
                transaction[1:],
                (WithdrawCollateral)
            );
            validateSender(txn.sender, sender);
            clearinghouse.withdrawCollateral(txn);
        } else if (txType == TransactionType.SettlePnl) {
            SettlePnl memory txn = abi.decode(transaction[1:], (SettlePnl));
            clearinghouse.settlePnl(txn);
        } else if (txType == TransactionType.DepositInsurance) {
            DepositInsurance memory txn = abi.decode(
                transaction[1:],
                (DepositInsurance)
            );
            validateSender(txn.sender, sender);
            clearinghouse.depositInsurance(txn);
        } else if (txType == TransactionType.MintLp) {
            MintLp memory txn = abi.decode(transaction[1:], (MintLp));
            validateSender(txn.sender, sender);
            clearinghouse.mintLp(txn);
        } else if (txType == TransactionType.BurnLp) {
            BurnLp memory txn = abi.decode(transaction[1:], (BurnLp));
            validateSender(txn.sender, sender);
            clearinghouse.burnLp(txn);
        } else if (txType == TransactionType.SwapAMM) {
            SwapAMM memory txn = abi.decode(transaction[1:], (SwapAMM));
            validateSender(txn.sender, sender);
            IOffchainBook(books[txn.productId]).swapAMM(txn);
        } else {
            revert("Invalid transaction type");
        }
    }

    function processTransaction(bytes calldata transaction) internal {
        TransactionType txType = TransactionType(uint8(transaction[0]));
        if (txType == TransactionType.LiquidateSubaccount) {
            SignedLiquidateSubaccount memory signedTx = abi.decode(
                transaction[1:],
                (SignedLiquidateSubaccount)
            );
            bytes32 digest = _hashTypedDataV4(
                keccak256(
                    abi.encode(
                        keccak256(bytes(LIQUIDATE_SUBACCOUNT_SIGNATURE)),
                        signedTx.tx.sender,
                        keccak256(bytes(signedTx.tx.subaccountName)),
                        signedTx.tx.liquidateeId,
                        signedTx.tx.mode,
                        signedTx.tx.healthGroup,
                        signedTx.tx.amount,
                        signedTx.tx.nonce
                    )
                )
            );
            validateNonce(signedTx.tx.sender, signedTx.tx.nonce);
            validateSignature(signedTx.tx.sender, digest, signedTx.signature);
            clearinghouse.liquidateSubaccount(signedTx.tx);
        } else if (txType == TransactionType.WithdrawCollateral) {
            SignedWithdrawCollateral memory signedTx = abi.decode(
                transaction[1:],
                (SignedWithdrawCollateral)
            );
            bytes32 digest = _hashTypedDataV4(
                keccak256(
                    abi.encode(
                        keccak256(bytes(WITHDRAW_COLLATERAL_SIGNATURE)),
                        signedTx.tx.sender,
                        keccak256(bytes(signedTx.tx.subaccountName)),
                        signedTx.tx.productId,
                        signedTx.tx.amount,
                        signedTx.tx.nonce
                    )
                )
            );
            validateNonce(signedTx.tx.sender, signedTx.tx.nonce);
            validateSignature(signedTx.tx.sender, digest, signedTx.signature);
            clearinghouse.withdrawCollateral(signedTx.tx);
        } else if (txType == TransactionType.UpdateTime) {
            UpdateTime memory txn = abi.decode(transaction[1:], (UpdateTime));
            time = txn.time;
            IClearinghouse _clearinghouse = clearinghouse;
            IProductEngine.EngineType[] memory engineTypes = _clearinghouse
                .getSupportedEngines();
            for (uint256 i = 0; i < engineTypes.length; i++) {
                if ((txn.updateMask >> uint8(engineTypes[i])) & 1 == 1) {
                    IProductEngine engine = IProductEngine(
                        _clearinghouse.getEngineByType(engineTypes[i])
                    );
                    uint256 dt = txn.time - lastUpdated[address(engine)];
                    lastUpdated[address(engine)] = txn.time;
                    engine.updateStates(dt);
                }
            }
        } else if (txType == TransactionType.UpdatePrice) {
            UpdatePrice memory txn = abi.decode(transaction[1:], (UpdatePrice));
            this.setPriceX18(txn.productId, txn.priceX18);
        } else if (txType == TransactionType.SettlePnl) {
            SettlePnl memory txn = abi.decode(transaction[1:], (SettlePnl));
            clearinghouse.settlePnl(txn);
        } else if (txType == TransactionType.MatchOrders) {
            MatchOrders memory txn = abi.decode(transaction[1:], (MatchOrders));
            IOffchainBook(books[txn.productId]).matchOrders(txn);
        } else if (txType == TransactionType.MatchOrderAMM) {
            MatchOrderAMM memory txn = abi.decode(
                transaction[1:],
                (MatchOrderAMM)
            );
            IOffchainBook(books[txn.productId]).matchOrderAMM(txn);
        } else if (txType == TransactionType.ExecuteSlowMode) {
            SlowModeConfig memory _slowModeConfig = slowModeConfig;
            _executeSlowModeTransaction(_slowModeConfig, true);
            slowModeConfig = _slowModeConfig;
        } else if (txType == TransactionType.MintLp) {
            SignedMintLp memory signedTx = abi.decode(
                transaction[1:],
                (SignedMintLp)
            );
            bytes32 digest = _hashTypedDataV4(
                keccak256(
                    abi.encode(
                        keccak256(bytes(MINT_LP_SIGNATURE)),
                        signedTx.tx.sender,
                        keccak256(bytes(signedTx.tx.subaccountName)),
                        signedTx.tx.productId,
                        signedTx.tx.amountBase,
                        signedTx.tx.quoteAmountLow,
                        signedTx.tx.quoteAmountHigh,
                        signedTx.tx.nonce
                    )
                )
            );
            validateNonce(signedTx.tx.sender, signedTx.tx.nonce);
            validateSignature(signedTx.tx.sender, digest, signedTx.signature);
            clearinghouse.mintLp(signedTx.tx);
        } else if (txType == TransactionType.BurnLp) {
            SignedBurnLp memory signedTx = abi.decode(
                transaction[1:],
                (SignedBurnLp)
            );
            bytes32 digest = _hashTypedDataV4(
                keccak256(
                    abi.encode(
                        keccak256(bytes(BURN_LP_SIGNATURE)),
                        signedTx.tx.sender,
                        keccak256(bytes(signedTx.tx.subaccountName)),
                        signedTx.tx.productId,
                        signedTx.tx.amount,
                        signedTx.tx.nonce
                    )
                )
            );
            validateNonce(signedTx.tx.sender, signedTx.tx.nonce);
            validateSignature(signedTx.tx.sender, digest, signedTx.signature);
            clearinghouse.burnLp(signedTx.tx);
        } else if (txType == TransactionType.DumpFees) {
            DumpFees memory txn = abi.decode(transaction[1:], (DumpFees));
            IOffchainBook(books[txn.productId]).dumpFees();
        } else {
            revert("Invalid transaction type");
        }
    }

    function fSubmitTransactions(bytes[] calldata transactions) external {
        require(
            msg.sender == sequencer,
            "Only the sequencer can submit transactions"
        );
        for (uint256 i = 0; i < transactions.length; i++) {
            bytes calldata transaction = transactions[i];
            processTransaction(transaction);
        }
        nSubmissions += uint64(transactions.length);
        emit SubmitTransactions();
    }

    function submitTransactions(uint64 idx, bytes[] calldata transactions)
        external
    {
        // TODO: if one of these transactions fails this means the sequencer is in an error state
        // we should probably record this, and engage some sort of recovery mode
        require(
            msg.sender == sequencer,
            "Only the sequencer can submit transactions"
        );
        require(idx == nSubmissions, "Invalid submission index");
        for (uint256 i = 0; i < transactions.length; i++) {
            bytes calldata transaction = transactions[i];
            processTransaction(transaction);
        }
        nSubmissions += uint64(transactions.length);
        emit SubmitTransactions();
    }

    function setBook(uint32 productId, address book) external {
        require(
            msg.sender == address(clearinghouse),
            "Only the clearinghouse can set the book"
        );
        books[productId] = book;
    }

    function getPriceX18(uint32 productId) external view returns (int256) {
        require(prices[productId] != 0, ERR_INVALID_PRODUCT);
        return prices[productId];
    }

    function setPriceX18(uint32 productId, int256 priceX18) external virtual {
        require(
            msg.sender == address(this),
            "Only the endpoint can set oracle price"
        );
        prices[productId] = priceX18;
    }

    function getTime() external view returns (uint256) {
        require(time != 0, "bad timing");
        return time;
    }

    function setSequencer(address _sequencer) external onlyOwner {
        sequencer = _sequencer;
    }

    function getSequencer() external view returns (address) {
        return sequencer;
    }

    function getNonce(address sender) external view returns (uint64) {
        return nonces[sender];
    }
}
