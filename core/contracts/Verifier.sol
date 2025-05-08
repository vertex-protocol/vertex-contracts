// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/cryptography/draft-EIP712Upgradeable.sol";
import "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import "./common/Errors.sol";
import "./libraries/MathHelper.sol";
import "./interfaces/IVerifier.sol";
import "./interfaces/IEndpoint.sol";

contract Verifier is EIP712Upgradeable, OwnableUpgradeable, IVerifier {
    Point[8] internal pubkeys;
    Point[256] internal aggregatePubkey;
    bool[256] internal isAggregatePubkeyLatest;
    uint256 internal nSigner;

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
    string internal constant MINT_VLP_SIGNATURE =
        "MintVlp(bytes32 sender,uint128 quoteAmount,uint64 nonce)";
    string internal constant BURN_VLP_SIGNATURE =
        "BurnVlp(bytes32 sender,uint128 vlpAmount,uint64 nonce)";
    string internal constant LINK_SIGNER_SIGNATURE =
        "LinkSigner(bytes32 sender,bytes32 signer,uint64 nonce)";

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(Point[8] memory initialSet) external initializer {
        __Ownable_init();
        for (uint256 i = 0; i < 8; ++i) {
            if (!isPointNone(initialSet[i])) {
                _assignPubkey(i, initialSet[i].x, initialSet[i].y);
            }
        }
    }

    function revertGasInfo(uint256 i, uint256 gasUsed) external pure {
        revert(
            string.concat(
                "G ",
                MathHelper.uint2str(uint128(i)),
                " ",
                MathHelper.uint2str(uint128(gasUsed))
            )
        );
    }

    function assignPubKey(
        uint256 i,
        uint256 x,
        uint256 y
    ) public onlyOwner {
        _assignPubkey(i, x, y);
    }

    function _assignPubkey(
        uint256 i,
        uint256 x,
        uint256 y
    ) internal {
        require(i < 8);
        if (isPointNone(pubkeys[i])) {
            nSigner += 1;
        }
        pubkeys[i] = Point(x, y);
        for (uint256 s = (1 << i); s < 256; s = (s + 1) | (1 << i)) {
            isAggregatePubkeyLatest[s] = false;
        }
    }

    function deletePubkey(uint256 index) public onlyOwner {
        if (!isPointNone(pubkeys[index])) {
            nSigner -= 1;
            delete pubkeys[index];
        }
    }

    function getPubkey(uint8 index) public view returns (Point memory) {
        return pubkeys[index];
    }

    function getPubkeyAddress(uint8 index) public view returns (address) {
        Point memory p = getPubkey(index);
        return address(uint160(uint256(keccak256(abi.encode(p.x, p.y)))));
    }

    function getAggregatePubkey(uint8 signerBitmask)
        internal
        returns (Point memory)
    {
        if (signerBitmask == 0 || isAggregatePubkeyLatest[signerBitmask])
            return aggregatePubkey[signerBitmask];
        Point memory res;
        for (uint256 i = 0; i < 8; ++i) {
            if ((signerBitmask >> i) % 2 == 1) {
                require(!isPointNone(pubkeys[i]));
                res = pointAdd(
                    getAggregatePubkey(signerBitmask ^ uint8(1 << i)),
                    pubkeys[i]
                );
                break;
            }
        }
        aggregatePubkey[signerBitmask] = res;
        isAggregatePubkeyLatest[signerBitmask] = true;
        return res;
    }

    // determine if 2/3 of the signers are included in this signing mask
    // and if the keys are present
    function checkQuorum(uint8 signerBitmask) internal view returns (bool) {
        uint256 nSigned = 0;
        for (uint256 i = 0; i < 8; ++i) {
            bool signed = ((signerBitmask >> i) & 1) == 1;
            if (signed) {
                if (isPointNone(pubkeys[i])) {
                    return false;
                }
                nSigned += 1;
            }
        }
        return nSigned * 2 > nSigner;
    }

    function requireValidSignature(
        bytes32 message,
        bytes32 e,
        bytes32 s,
        uint8 signerBitmask
    ) public {
        require(checkQuorum(signerBitmask));
        Point memory pubkey = getAggregatePubkey(signerBitmask);
        require(
            verify(
                pubkey.y % 2 == 0 ? 27 : 28,
                bytes32(pubkey.x),
                message,
                e,
                s
            ),
            "Verification failed"
        );
    }

    /// SCHNORR IMPLEMENTATION BELOW
    // secp256k1 group order
    uint256 public constant Q =
        0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141;

    // parity := public key y-coord parity (27 or 28)
    // px := public key x-coord
    // message := 32-byte message
    // e := schnorr signature challenge
    // s := schnorr signature
    function verify(
        uint8 parity,
        bytes32 px,
        bytes32 message,
        bytes32 e,
        bytes32 s
    ) internal pure returns (bool) {
        // ecrecover = (m, v, r, s);
        bytes32 sp = bytes32(Q - mulmod(uint256(s), uint256(px), Q));
        bytes32 ep = bytes32(Q - mulmod(uint256(e), uint256(px), Q));

        require(sp != 0);
        // the ecrecover precompile implementation checks that the `r` and `s`
        // inputs are non-zero (in this case, `px` and `ep`), thus we don't need to
        // check if they're zero.
        address R = ecrecover(sp, parity, px, ep);
        require(R != address(0), "ecrecover failed");
        return e == keccak256(abi.encodePacked(R, uint8(parity), px, message));
    }

    uint256 public constant _P =
        0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEFFFFFC2F;

    struct Point {
        uint256 x;
        uint256 y;
    }

    function pow(
        uint256 a,
        uint256 b,
        uint256 mod
    ) internal pure returns (uint256) {
        // a ^ b % mod
        uint256 res = 1;
        while (b > 0) {
            if (b % 2 == 1) {
                res = mulmod(res, a, mod);
            }
            a = mulmod(a, a, mod);
            b /= 2;
        }
        return res;
    }

    function isPointNone(Point memory u) internal pure returns (bool) {
        return u.x == 0 && u.y == 0;
    }

    function pointAdd(Point memory u, Point memory v)
        internal
        pure
        returns (Point memory)
    {
        if (isPointNone(u)) return v;
        if (isPointNone(v)) return u;
        uint256 lam = 0;
        if (u.x == v.x) {
            if (u.y != v.y) return Point(0, 0);
            lam = mulmod(3, u.x, _P);
            lam = mulmod(lam, u.x, _P);
            lam = mulmod(lam, pow(mulmod(2, v.y, _P), _P - 2, _P), _P);
        } else {
            lam = mulmod(
                addmod(v.y, _P - u.y, _P),
                pow(addmod(v.x, _P - u.x, _P), _P - 2, _P),
                _P
            );
        }
        uint256 x3 = mulmod(lam, lam, _P);
        x3 = addmod(x3, _P - u.x, _P);
        x3 = addmod(x3, _P - v.x, _P);
        uint256 y3 = addmod(u.x, _P - x3, _P);
        y3 = mulmod(y3, lam, _P);
        y3 = addmod(y3, _P - u.y, _P);
        return Point(x3, y3);
    }

    function checkIndividualSignature(
        bytes32 digest,
        bytes memory signature,
        uint8 signerIndex
    ) public view returns (bool) {
        address expectedAddress = getPubkeyAddress(signerIndex);
        address recovered = ECDSA.recover(digest, signature);
        return expectedAddress == recovered;
    }

    function requireValidTxSignatures(
        bytes calldata txn,
        uint64 idx,
        bytes[] calldata signatures
    ) public view {
        bytes32 data = keccak256(
            abi.encodePacked(uint256(block.chainid), uint256(idx), txn)
        );
        bytes32 hashedMsg = keccak256(
            abi.encodePacked("\x19Ethereum Signed Message:\n32", data)
        );

        uint256 nSignatures = 0;
        for (uint256 i = 0; i < signatures.length; i++) {
            if (signatures[i].length > 0) {
                nSignatures += 1;
                require(
                    checkIndividualSignature(
                        hashedMsg,
                        signatures[i],
                        uint8(i)
                    ),
                    "invalid signature"
                );
            }
        }
        require(nSignatures == nSigner, "not enough signatures");
    }

    function validateSignature(
        bytes32 sender,
        address linkedSigner,
        bytes32 digest,
        bytes memory signature
    ) public pure {
        address recovered = ECDSA.recover(digest, signature);
        require(
            (recovered != address(0)) &&
                ((recovered == address(uint160(bytes20(sender)))) ||
                    (recovered == linkedSigner)),
            ERR_INVALID_SIGNATURE
        );
    }

    function computeDigest(
        IEndpoint.TransactionType txType,
        bytes calldata transactionBody
    ) public pure returns (bytes32) {
        bytes32 digest;

        if (txType == IEndpoint.TransactionType.LiquidateSubaccount) {
            IEndpoint.SignedLiquidateSubaccount memory signedTx = abi.decode(
                transactionBody,
                (IEndpoint.SignedLiquidateSubaccount)
            );
            digest = keccak256(
                abi.encode(
                    keccak256(bytes(LIQUIDATE_SUBACCOUNT_SIGNATURE)),
                    signedTx.tx.sender,
                    signedTx.tx.liquidatee,
                    signedTx.tx.productId,
                    signedTx.tx.isEncodedSpread,
                    signedTx.tx.amount,
                    signedTx.tx.nonce
                )
            );
        } else if (txType == IEndpoint.TransactionType.WithdrawCollateral) {
            IEndpoint.SignedWithdrawCollateral memory signedTx = abi.decode(
                transactionBody,
                (IEndpoint.SignedWithdrawCollateral)
            );
            digest = keccak256(
                abi.encode(
                    keccak256(bytes(WITHDRAW_COLLATERAL_SIGNATURE)),
                    signedTx.tx.sender,
                    signedTx.tx.productId,
                    signedTx.tx.amount,
                    signedTx.tx.nonce
                )
            );
        } else if (txType == IEndpoint.TransactionType.MintLp) {
            IEndpoint.SignedMintLp memory signedTx = abi.decode(
                transactionBody,
                (IEndpoint.SignedMintLp)
            );
            digest = keccak256(
                abi.encode(
                    keccak256(bytes(MINT_LP_SIGNATURE)),
                    signedTx.tx.sender,
                    signedTx.tx.productId,
                    signedTx.tx.amountBase,
                    signedTx.tx.quoteAmountLow,
                    signedTx.tx.quoteAmountHigh,
                    signedTx.tx.nonce
                )
            );
        } else if (txType == IEndpoint.TransactionType.BurnLp) {
            IEndpoint.SignedBurnLp memory signedTx = abi.decode(
                transactionBody,
                (IEndpoint.SignedBurnLp)
            );
            digest = keccak256(
                abi.encode(
                    keccak256(bytes(BURN_LP_SIGNATURE)),
                    signedTx.tx.sender,
                    signedTx.tx.productId,
                    signedTx.tx.amount,
                    signedTx.tx.nonce
                )
            );
        } else if (txType == IEndpoint.TransactionType.MintVlp) {
            IEndpoint.SignedMintVlp memory signedTx = abi.decode(
                transactionBody,
                (IEndpoint.SignedMintVlp)
            );
            digest = keccak256(
                abi.encode(
                    keccak256(bytes(MINT_VLP_SIGNATURE)),
                    signedTx.tx.sender,
                    signedTx.tx.quoteAmount,
                    signedTx.tx.nonce
                )
            );
        } else if (txType == IEndpoint.TransactionType.BurnVlp) {
            IEndpoint.SignedBurnVlp memory signedTx = abi.decode(
                transactionBody,
                (IEndpoint.SignedBurnVlp)
            );
            digest = keccak256(
                abi.encode(
                    keccak256(bytes(BURN_VLP_SIGNATURE)),
                    signedTx.tx.sender,
                    signedTx.tx.vlpAmount,
                    signedTx.tx.nonce
                )
            );
        } else if (txType == IEndpoint.TransactionType.LinkSigner) {
            IEndpoint.SignedLinkSigner memory signedTx = abi.decode(
                transactionBody,
                (IEndpoint.SignedLinkSigner)
            );
            digest = keccak256(
                abi.encode(
                    keccak256(bytes(LINK_SIGNER_SIGNATURE)),
                    signedTx.tx.sender,
                    signedTx.tx.signer,
                    signedTx.tx.nonce
                )
            );
        } else if (txType == IEndpoint.TransactionType.TransferQuote) {
            IEndpoint.SignedTransferQuote memory signedTx = abi.decode(
                transactionBody,
                (IEndpoint.SignedTransferQuote)
            );
            digest = keccak256(
                abi.encode(
                    keccak256(bytes(TRANSFER_QUOTE_SIGNATURE)),
                    signedTx.tx.sender,
                    signedTx.tx.recipient,
                    signedTx.tx.amount,
                    signedTx.tx.nonce
                )
            );
        } else {
            revert();
        }

        return digest;
    }
}
