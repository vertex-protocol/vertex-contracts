// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

import "./Endpoint.sol";

contract FEndpoint is Endpoint {
    function validateSignature(
        address signer,
        bytes32 digest,
        bytes memory signature
    ) internal view override {}

    function handleDepositTransfer(
        IERC20Base token,
        address from,
        uint256 amount
    ) internal override {}

    function setPriceX18(uint32 productId, int256 priceX18) external override {
        prices[productId] = priceX18;
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
    function updateTime(
        UpdateTime calldata p
    ) external pure returns (UpdateTime memory) {
        return p;
    }

    function updatePrice(
        UpdatePrice calldata p
    ) external pure returns (UpdatePrice memory) {
        return p;
    }

    function settlePnl(
        SettlePnl calldata p
    ) external pure returns (SettlePnl memory) {
        return p;
    }

    function matchOrders(
        MatchOrders calldata p
    ) external pure returns (MatchOrders memory) {
        return p;
    }

    function dumpFees(
        DumpFees calldata p
    ) external pure returns (DumpFees memory) {
        return p;
    }

    function signedOrder(
        SignedOrder calldata p
    ) external pure returns (SignedOrder memory) {
        return p;
    }

    function signedCancellation(
        SignedCancellation calldata p
    ) external pure returns (SignedCancellation memory) {
        return p;
    }

    function unsignedDepositCollateral(
        DepositCollateral calldata p
    ) external pure returns (DepositCollateral memory) {
        return p;
    }

    function unsignedDepositInsurance(
        DepositInsurance calldata p
    ) external pure returns (DepositInsurance memory) {
        return p;
    }

    function signedLiquidateSubaccount(
        SignedLiquidateSubaccount calldata p
    ) external pure returns (SignedLiquidateSubaccount memory) {
        return p;
    }

    function signedWithdrawCollateral(
        SignedWithdrawCollateral calldata p
    ) external pure returns (SignedWithdrawCollateral memory) {
        return p;
    }

    function signedMintLp(
        SignedMintLp calldata p
    ) external pure returns (SignedMintLp memory) {
        return p;
    }

    function signedBurnLp(
        SignedBurnLp calldata p
    ) external pure returns (SignedBurnLp memory) {
        return p;
    }
}
