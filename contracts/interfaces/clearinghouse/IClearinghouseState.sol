// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

import "../engine/IProductEngine.sol";
import "../../libraries/RiskHelper.sol";

interface IClearinghouseState {
    struct RiskStore {
        // these weights are all
        // between 0 and 2
        // these integers are the real
        // weights times 1e9
        int48 longWeightInitial;
        int48 shortWeightInitial;
        int48 longWeightMaintenance;
        int48 shortWeightMaintenance;
        int48 largePositionPenalty;
    }

    struct HealthGroup {
        uint32 spotId;
        uint32 perpId;
    }

    struct HealthVars {
        int256 spotAmountX18;
        int256 perpAmountX18;
        // 1 unit of basis amount is 1 unit long spot and 1 unit short perp
        int256 basisAmountX18;
        int256 spotInLpAmountX18;
        int256 perpInLpAmountX18;
        int256 spotPriceX18;
        int256 perpPriceX18;
        RiskHelper.Risk spotRisk;
        RiskHelper.Risk perpRisk;
    }

    function getHealthGroups() external view returns (HealthGroup[] memory);

    /// @notice Retrieve quote ERC20 address
    function getQuote() external view returns (address);

    /// @notice Returns all supported engine types for the clearinghouse
    function getSupportedEngines()
        external
        view
        returns (IProductEngine.EngineType[] memory);

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

    /// @notice Returns the orderbook associated with a product ID
    function getOrderbook(uint32 productId) external view returns (address);

    /// @notice Returns number of registered products
    function getNumProducts() external view returns (uint32);

    /// @notice Returns number of subaccounts created
    function getNumSubaccounts() external view returns (uint64);

    /// @notice Gets the subaccount ID associated with an address
    /// @notice IDs start at 1; errors if the subaccount does not exist
    function getSubaccountId(address owner, string memory subaccountName)
        external
        view
        returns (uint64);

    /// @notice Gets the address associated with a subaccount ID
    /// @notice Null address indicates that the subaccount does not exist
    function getSubaccountOwner(uint64 subaccountId)
        external
        view
        returns (address);

    /// @notice Returns health for the subaccount across all engines
    function getHealthX18(
        uint64 subaccountId,
        IProductEngine.HealthType healthType
    ) external view returns (int256);

    /// @notice Returns the amount of insurance remaining in this clearinghouse
    function getInsuranceX18() external view returns (int256);

    function getRisk(uint32 productId)
        external
        view
        returns (RiskHelper.Risk memory);
}
