// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

import "./Endpoint.sol";
import "@openzeppelin/contracts/utils/Strings.sol";

contract FEndpoint is Endpoint {
    struct Cancellation {
        bytes32 sender;
        uint32[] productIds;
        bytes32[] digests;
        uint64 nonce;
    }

    struct SignedCancellation {
        Cancellation cancellation;
        bytes signature;
    }

    struct CancellationProducts {
        bytes32 sender;
        uint32[] productIds;
        uint64 nonce;
    }

    struct SignedCancellationProducts {
        CancellationProducts cancellationProducts;
        bytes signature;
    }

    function validateSignature(
        bytes32 signer,
        bytes32 digest,
        bytes memory signature
    ) internal view override {}

    function increaseAllowance(
        IERC20Base token,
        address to,
        uint256 amount
    ) internal override {}

    function safeTransferFrom(
        IERC20Base token,
        address from,
        uint256 amount
    ) internal override {}

    function requireUnsanctioned(address) internal view override {}

    function requireSequencer() internal view override {}

    function validateNonce(bytes32 sender, uint64 nonce) internal override {
        uint64 expectedNonce = nonces[address(uint160(bytes20(sender)))]++;
        if (nonce != expectedNonce) {
            revert(
                string.concat(
                    "Invalid nonce: expected: ",
                    Strings.toString(uint256(expectedNonce))
                )
            );
        }
    }

    function liquidationStart(bytes calldata transaction) external {
        TransactionType txType = TransactionType(uint8(transaction[0]));
        if (txType == TransactionType.LiquidateSubaccount) {
            SignedLiquidateSubaccount memory signedTx = abi.decode(
                transaction[1:],
                (SignedLiquidateSubaccount)
            );
            validateNonce(signedTx.tx.sender, signedTx.tx.nonce);
            bytes32 digest = _hashTypedDataV4(
                keccak256(
                    abi.encode(
                        keccak256(bytes(LIQUIDATE_SUBACCOUNT_SIGNATURE)),
                        signedTx.tx.sender,
                        signedTx.tx.liquidatee,
                        signedTx.tx.mode,
                        signedTx.tx.healthGroup,
                        signedTx.tx.amount,
                        signedTx.tx.nonce
                    )
                )
            );
            validateSignature(signedTx.tx.sender, digest, signedTx.signature);
            requireSubaccount(signedTx.tx.sender);
            chargeFee(signedTx.tx.sender, LIQUIDATION_FEE);
        } else {
            revert("critical error: expected liquidation");
        }
        nSubmissions++;
    }

    function setPriceX18(uint32 productId, int128 priceX18) external {
        uint32 healthGroup = _getHealthGroup(productId);
        if (productId % 2 == 1) {
            pricesX18[healthGroup].spotPriceX18 = priceX18;
        } else {
            pricesX18[healthGroup].perpPriceX18 = priceX18;
        }
    }

    function setSlowModeConfig(SlowModeConfig memory _slowModeConfig) external {
        slowModeConfig = _slowModeConfig;
    }

    function setSlowModeTx(uint64 idx, SlowModeTx memory txn) external {
        SlowModeConfig memory _slowModeConfig = slowModeConfig;
        require(_slowModeConfig.txCount == idx, "not next tx");
        slowModeTxs[_slowModeConfig.txCount++] = txn;
        //        _executeSlowModeTransaction(_slowModeConfig, true);
        slowModeConfig = _slowModeConfig;
    }

    // abis for the structs are only generated if we use them in a function
    function perpTick(PerpTick calldata p)
        external
        pure
        returns (PerpTick memory)
    {
        return p;
    }

    function spotTick(SpotTick calldata p)
        external
        pure
        returns (SpotTick memory)
    {
        return p;
    }

    function manualAssert(ManualAssert calldata p)
        external
        pure
        returns (ManualAssert memory)
    {
        return p;
    }

    function rebate(Rebate calldata p) external pure returns (Rebate memory) {
        return p;
    }

    function updatePrice(UpdatePrice calldata p)
        external
        pure
        returns (UpdatePrice memory)
    {
        return p;
    }

    function settlePnl(SettlePnl calldata p)
        external
        pure
        returns (SettlePnl memory)
    {
        return p;
    }

    function matchOrders(MatchOrders calldata p)
        external
        pure
        returns (MatchOrders memory)
    {
        return p;
    }

    function signedOrder(SignedOrder calldata p)
        external
        pure
        returns (SignedOrder memory)
    {
        return p;
    }

    function signedCancellation(SignedCancellation calldata p)
        external
        pure
        returns (SignedCancellation memory)
    {
        return p;
    }

    function signedCancellationProducts(SignedCancellationProducts calldata p)
        external
        pure
        returns (SignedCancellationProducts memory)
    {
        return p;
    }

    function unsignedDepositCollateral(DepositCollateral calldata p)
        external
        pure
        returns (DepositCollateral memory)
    {
        return p;
    }

    function unsignedDepositInsurance(DepositInsurance calldata p)
        external
        pure
        returns (DepositInsurance memory)
    {
        return p;
    }

    function unsignedLiquidateSubaccount(LiquidateSubaccount calldata p)
        external
        pure
        returns (LiquidateSubaccount memory)
    {
        return p;
    }

    function signedLiquidateSubaccount(SignedLiquidateSubaccount calldata p)
        external
        pure
        returns (SignedLiquidateSubaccount memory)
    {
        return p;
    }

    function unsignedWithdrawCollateral(WithdrawCollateral calldata p)
        external
        pure
        returns (WithdrawCollateral memory)
    {
        return p;
    }

    function signedWithdrawCollateral(SignedWithdrawCollateral calldata p)
        external
        pure
        returns (SignedWithdrawCollateral memory)
    {
        return p;
    }

    function unsignedMintLp(MintLp calldata p)
        external
        pure
        returns (MintLp memory)
    {
        return p;
    }

    function signedMintLp(SignedMintLp calldata p)
        external
        pure
        returns (SignedMintLp memory)
    {
        return p;
    }

    function unsignedBurnLp(BurnLp calldata p)
        external
        pure
        returns (BurnLp memory)
    {
        return p;
    }

    function signedBurnLp(SignedBurnLp calldata p)
        external
        pure
        returns (SignedBurnLp memory)
    {
        return p;
    }

    function swapAMM(SwapAMM calldata p)
        external
        pure
        returns (SwapAMM memory)
    {
        return p;
    }

    function matchOrderAMM(MatchOrderAMM calldata p)
        external
        pure
        returns (MatchOrderAMM memory)
    {
        return p;
    }

    function getHealthCheckFee() external pure returns (int128) {
        return HEALTHCHECK_FEE;
    }

    function getLiquidationFee() external pure returns (int128) {
        return LIQUIDATION_FEE;
    }

    function getTakerSequencerFee() external pure returns (int128) {
        return TAKER_SEQUENCER_FEE;
    }
}
