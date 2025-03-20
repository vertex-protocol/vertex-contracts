// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "hardhat/console.sol";

import "./common/Constants.sol";
import "./common/Errors.sol";
import "./libraries/MathHelper.sol";
import "./libraries/MathSD21x18.sol";
import "./interfaces/clearinghouse/IClearinghouse.sol";
import "./interfaces/engine/IProductEngine.sol";
import "./interfaces/IOffchainExchange.sol";
import "./interfaces/IEndpoint.sol";
import "./EndpointGated.sol";
import "./libraries/Logger.sol";

abstract contract BaseEngine is IProductEngine, EndpointGated {
    using MathSD21x18 for int128;

    IClearinghouse internal _clearinghouse;
    address internal _fees; // deprecated
    uint32[] internal productIds;

    mapping(uint32 => address) internal markets; // deprecated

    // Whether an address can apply deltas - all orderbooks and clearinghouse is whitelisted
    mapping(address => bool) internal canApplyDeltas;

    bytes32 internal constant RISK_STORAGE = keccak256("vertex.protocol.risk");

    event BalanceUpdate(uint32 productId, bytes32 subaccount);
    event ProductUpdate(uint32 productId);

    function _productUpdate(uint32 productId) internal virtual {}

    struct Uint256Slot {
        uint256 value;
    }

    struct RiskStoreMappingSlot {
        mapping(uint32 => RiskHelper.RiskStore) value;
    }

    function _risk() internal pure returns (RiskStoreMappingSlot storage r) {
        bytes32 slot = RISK_STORAGE;
        assembly {
            r.slot := slot
        }
    }

    function _risk(uint32 productId, RiskStoreMappingSlot storage rmap)
        internal
        view
        returns (RiskHelper.Risk memory r)
    {
        RiskHelper.RiskStore memory s = rmap.value[productId];
        r.longWeightInitialX18 = int128(s.longWeightInitial) * 1e9;
        r.shortWeightInitialX18 = int128(s.shortWeightInitial) * 1e9;
        r.longWeightMaintenanceX18 = int128(s.longWeightMaintenance) * 1e9;
        r.shortWeightMaintenanceX18 = int128(s.shortWeightMaintenance) * 1e9;
        r.priceX18 = s.priceX18;
    }

    function _risk(uint32 productId)
        internal
        view
        returns (RiskHelper.Risk memory)
    {
        return _risk(productId, _risk());
    }

    function getRisk(uint32 productId)
        external
        view
        returns (RiskHelper.Risk memory)
    {
        return _risk(productId);
    }

    function _getInLpBalance(uint32 productId, bytes32 subaccount)
        internal
        view
        virtual
        returns (
            // baseAmount, quoteAmount, quoteDeltaAmount (funding)
            int128,
            int128,
            int128
        );

    function _getBalance(uint32 productId, bytes32 subaccount)
        internal
        view
        virtual
        returns (int128, int128);

    function getHealthContribution(
        bytes32 subaccount,
        IProductEngine.HealthType healthType
    ) public view returns (int128 health) {
        uint32[] memory _productIds = getProductIds();
        RiskStoreMappingSlot storage r = _risk();

        for (uint32 i = 0; i < _productIds.length; i++) {
            uint32 productId = _productIds[i];
            RiskHelper.Risk memory risk = _risk(productId, r);
            {
                (int128 amount, int128 quoteAmount) = _getBalance(
                    productId,
                    subaccount
                );
                int128 weight = RiskHelper._getWeightX18(
                    risk,
                    amount,
                    healthType
                );
                health += quoteAmount;
                if (amount != 0) {
                    // anything with a short weight of 2 is a spot that
                    // should not count towards health and exists out of the risk system
                    // if we're getting a weight of 2 it means this is attempting to short
                    // the spot, so we should error out
                    if (weight == 2 * ONE) {
                        return type(int128).min;
                    }

                    health += amount.mul(weight).mul(risk.priceX18);
                }
            }

            {
                (
                    int128 baseAmount,
                    int128 quoteAmount,
                    int128 quoteDeltaAmount
                ) = _getInLpBalance(productId, subaccount);
                if (baseAmount != 0) {
                    int128 lpValue = RiskHelper._getLpRawValue(
                        baseAmount,
                        quoteAmount,
                        risk.priceX18
                    );
                    health +=
                        lpValue.mul(
                            RiskHelper._getWeightX18(risk, 1, healthType)
                        ) +
                        quoteDeltaAmount;
                }
            }
        }
    }

    function getCoreRisk(
        bytes32 subaccount,
        uint32 productId,
        IProductEngine.HealthType healthType
    ) external view returns (IProductEngine.CoreRisk memory) {
        RiskHelper.Risk memory risk = _risk(productId);
        (int128 amount, ) = _getBalance(productId, subaccount);
        return
            IProductEngine.CoreRisk(
                amount,
                risk.priceX18,
                RiskHelper._getWeightX18(risk, 1, healthType)
            );
    }

    function _balanceUpdate(uint32 productId, bytes32 subaccount)
        internal
        virtual
    {}

    function _assertInternal() internal view virtual {
        require(canApplyDeltas[msg.sender], ERR_UNAUTHORIZED);
    }

    function _initialize(
        address _clearinghouseAddr,
        address _offchainExchangeAddr,
        address _endpointAddr,
        address _admin
    ) internal initializer {
        __Ownable_init();
        setEndpoint(_endpointAddr);
        transferOwnership(_admin);

        _clearinghouse = IClearinghouse(_clearinghouseAddr);

        canApplyDeltas[_endpointAddr] = true;
        canApplyDeltas[_clearinghouseAddr] = true;
        canApplyDeltas[_offchainExchangeAddr] = true;
    }

    function getClearinghouse() external view returns (address) {
        return address(_clearinghouse);
    }

    function getProductIds() public view returns (uint32[] memory) {
        return productIds;
    }

    function _addProductForId(
        uint32 productId,
        uint32 quoteId,
        address virtualBook,
        int128 sizeIncrement,
        int128 minSize,
        int128 lpSpreadX18,
        RiskHelper.RiskStore memory riskStore
    ) internal {
        require(virtualBook != address(0));
        require(
            riskStore.longWeightInitial <= riskStore.longWeightMaintenance &&
                riskStore.longWeightMaintenance <= 10**9 &&
                riskStore.shortWeightInitial >=
                riskStore.shortWeightMaintenance &&
                riskStore.shortWeightMaintenance >= 10**9,
            ERR_BAD_PRODUCT_CONFIG
        );

        _risk().value[productId] = riskStore;

        // register product with clearinghouse
        _clearinghouse.registerProduct(productId);

        productIds.push(productId);
        // product ids are in ascending order
        for (uint256 i = productIds.length - 1; i > 0; i--) {
            if (productIds[i] < productIds[i - 1]) {
                uint32 t = productIds[i];
                productIds[i] = productIds[i - 1];
                productIds[i - 1] = t;
            } else {
                break;
            }
        }

        _exchange().updateMarket(
            productId,
            quoteId,
            virtualBook,
            sizeIncrement,
            minSize,
            lpSpreadX18
        );

        emit AddProduct(productId);
    }

    function _exchange() internal view returns (IOffchainExchange) {
        return
            IOffchainExchange(IEndpoint(getEndpoint()).getOffchainExchange());
    }

    function updatePrice(uint32 productId, int128 priceX18) external {
        require(msg.sender == address(_clearinghouse), ERR_UNAUTHORIZED);
        _risk().value[productId].priceX18 = priceX18;
    }

    function updateRisk(uint32 productId, RiskHelper.RiskStore memory riskStore)
        external
        onlyOwner
    {
        require(
            riskStore.longWeightInitial <= riskStore.longWeightMaintenance &&
                riskStore.shortWeightInitial >=
                riskStore.shortWeightMaintenance,
            ERR_BAD_PRODUCT_CONFIG
        );

        _risk().value[productId] = riskStore;
    }
}
