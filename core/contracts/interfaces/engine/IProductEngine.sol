// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "../clearinghouse/IClearinghouse.sol";
import "../../libraries/RiskHelper.sol";

interface IProductEngine {
    event AddProduct(uint32 productId);

    enum EngineType {
        SPOT,
        PERP
    }

    enum HealthType {
        INITIAL,
        MAINTENANCE,
        PNL
    }

    struct ProductDelta {
        uint32 productId;
        bytes32 subaccount;
        int128 amountDelta;
        int128 vQuoteDelta;
    }

    struct CoreRisk {
        int128 amount;
        int128 price;
        int128 longWeight;
    }

    /// @notice Initializes the engine
    function initialize(
        address _clearinghouse,
        address _offchainExchange,
        address _quote,
        address _endpoint,
        address _admin
    ) external;

    function getHealthContribution(
        bytes32 subaccount,
        IProductEngine.HealthType healthType
    ) external view returns (int128);

    function getCoreRisk(
        bytes32 subaccount,
        uint32 productId,
        IProductEngine.HealthType healthType
    ) external view returns (IProductEngine.CoreRisk memory);

    function updateProduct(bytes calldata txn) external;

    function swapLp(
        uint32 productId,
        int128 baseDelta,
        int128 quoteDelta
    ) external returns (int128, int128);

    function mintLp(
        uint32 productId,
        bytes32 subaccount,
        int128 amountBase,
        int128 quoteAmountLow,
        int128 quoteAmountHigh
    ) external;

    function burnLp(
        uint32 productId,
        bytes32 subaccount,
        // passing 0 here means to burn all
        int128 amountLp
    ) external returns (int128, int128);

    function decomposeLps(bytes32 liquidatee, bytes32 liquidator)
        external
        returns (int128);

    /// @notice return clearinghouse addr
    function getClearinghouse() external view returns (address);

    /// @notice return productIds associated with engine
    function getProductIds() external view returns (uint32[] memory);

    function getRisk(uint32 productId)
        external
        view
        returns (RiskHelper.Risk memory);

    /// @notice return the type of engine
    function getEngineType() external pure returns (IProductEngine.EngineType);

    function updatePrice(uint32 productId, int128 priceX18) external;
}
