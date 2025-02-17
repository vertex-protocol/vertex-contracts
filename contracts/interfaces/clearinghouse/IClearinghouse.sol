// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

import "./IClearinghouseEventEmitter.sol";
import "../engine/IProductEngine.sol";
import "../IEndpoint.sol";
import "../IEndpointGated.sol";
import "../IVersion.sol";
import "../../libraries/RiskHelper.sol";

interface IClearinghouse is
    IClearinghouseEventEmitter,
    IEndpointGated,
    IVersion
{
    function addEngine(
        address engine,
        address offchainExchange,
        IProductEngine.EngineType engineType
    ) external;

    function registerProduct(uint32 productId) external;

    function transferQuote(IEndpoint.TransferQuote calldata tx) external;

    function depositCollateral(IEndpoint.DepositCollateral calldata tx)
        external;

    function withdrawCollateral(
        bytes32 sender,
        uint32 productId,
        uint128 amount,
        address sendTo
    ) external;

    function mintLp(IEndpoint.MintLp calldata tx) external;

    function burnLp(IEndpoint.BurnLp calldata tx) external;

    function liquidateSubaccount(IEndpoint.LiquidateSubaccount calldata tx)
        external;

    function depositInsurance(IEndpoint.DepositInsurance calldata tx) external;

    function settlePnl(IEndpoint.SettlePnl calldata tx) external;

    function claimSequencerFees(
        IEndpoint.ClaimSequencerFees calldata tx,
        int128[] calldata fees
    ) external;

    /// @notice Retrieve quote ERC20 address
    function getQuote() external view returns (address);

    /// @notice Returns the registered engine address by type
    function getEngineByType(IProductEngine.EngineType engineType)
        external
        view
        returns (address);

    /// @notice Returns the engine associated with a product ID
    function getEngineByProduct(uint32 productId)
        external
        view
        returns (address);

    /// @notice Returns health for the subaccount across all engines
    function getHealth(bytes32 subaccount, IProductEngine.HealthType healthType)
        external
        view
        returns (int128);

    /// @notice Returns the amount of insurance remaining in this clearinghouse
    function getInsurance() external view returns (int128);

    function getSpreads() external view returns (uint256);

    function upgradeClearinghouseLiq(address _clearinghouseLiq) external;

    function getClearinghouseLiq() external view returns (address);

    function burnLpAndTransfer(IEndpoint.BurnLpAndTransfer calldata txn)
        external;
}
