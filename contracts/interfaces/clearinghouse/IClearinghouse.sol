// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

import "./IClearinghouseState.sol";
import "./IClearinghouseEventEmitter.sol";
import "../engine/IProductEngine.sol";
import "../IEndpoint.sol";
import "../IEndpointGated.sol";

interface IClearinghouse is
    IClearinghouseState,
    IClearinghouseEventEmitter,
    IEndpointGated
{
    function addEngine(address engine, IProductEngine.EngineType engineType)
        external;

    function registerProductForId(
        address book,
        RiskStore memory riskStore,
        uint32 healthGroup
    ) external returns (uint32);

    function depositCollateral(IEndpoint.DepositCollateral calldata tx)
        external;

    function withdrawCollateral(IEndpoint.WithdrawCollateral calldata tx)
        external;

    function mintLp(IEndpoint.MintLp calldata tx) external;

    function burnLp(IEndpoint.BurnLp calldata tx) external;

    function liquidateSubaccount(IEndpoint.LiquidateSubaccount calldata tx)
        external;

    function depositInsurance(IEndpoint.DepositInsurance calldata tx) external;

    function settlePnl(IEndpoint.SettlePnl calldata tx) external;
}
