// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "../clearinghouse/IClearinghouse.sol";
import "./IProductEngineState.sol";

interface IProductEngine is IProductEngineState {
    event AddProduct(uint32 productId);
    event ProductUpdate(uint32 indexed productId);
    event SocializeProduct(
        uint32 indexed productId,
        int256 amountSocializedX18
    );

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
        uint64 subaccountId;
        int256 amountDeltaX18;
        int256 vQuoteDeltaX18;
    }

    /// @notice Initializes the engine
    function initialize(
        address _clearinghouse,
        address _quote,
        address _endpoint,
        address _admin,
        address _fees
    ) external;

    /// @notice updates internal balances; given tuples of (product, subaccount, delta)
    /// since tuples aren't a thing in solidity, params specify the transpose
    function applyDeltas(ProductDelta[] calldata deltas) external;

    function swapLp(
        uint32 productId,
        uint64 subaccountId,
        // maximum to swap
        int256 amount,
        int256 priceX18,
        int256 sizeIncrement,
        int256 lpSpreadX18
    ) external returns (int256, int256);

    function mintLp(
        uint32 productId,
        uint64 subaccountId,
        int256 amountBaseX18,
        int256 quoteAmountLowX18,
        int256 quoteAmountHighX18
    ) external;

    function burnLp(
        uint32 productId,
        uint64 subaccountId,
        // passing 0 here means to burn all
        int256 amountLpX18
    ) external;

    function socializeSubaccount(
        uint64 subaccountId,
        int256 insuranceX18
    ) external returns (int256);

    function decomposeLps(uint64 liquidateeId, uint64 liquidatorId) external;

    function updateStates(uint256 dt) external;
}
