// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "../clearinghouse/IClearinghouse.sol";
import "./IProductEngineState.sol";

interface IProductEngine is IProductEngineState {
    event AddProduct(uint32 productId);
    event ProductUpdate(uint32 indexed productId);
    event SocializeProduct(uint32 indexed productId, int128 amountSocialized);

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
        int128 amountDelta;
        int128 vQuoteDelta;
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
        int128 amount,
        int128 priceX18,
        int128 sizeIncrement,
        int128 lpSpreadX18
    ) external returns (int128, int128);

    function mintLp(
        uint32 productId,
        uint64 subaccountId,
        int128 amountBase,
        int128 quoteAmountLow,
        int128 quoteAmountHigh
    ) external;

    function burnLp(
        uint32 productId,
        uint64 subaccountId,
        // passing 0 here means to burn all
        int128 amountLp
    ) external;

    function socializeSubaccount(uint64 subaccountId, int128 insurance)
        external
        returns (int128);

    function decomposeLps(uint64 liquidateeId, uint64 liquidatorId) external;
}
