// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;
import "./MathSD21x18.sol";
import "../interfaces/engine/IProductEngine.sol";
import "../common/Constants.sol";
import "../common/Errors.sol";
import "./MathHelper.sol";

/// @title RiskHelper
/// @dev Provides basic math functions
library RiskHelper {
    using MathSD21x18 for int128;

    struct RiskStore {
        // these weights are all
        // between 0 and 2
        // these integers are the real
        // weights times 1e9
        int32 longWeightInitial;
        int32 shortWeightInitial;
        int32 longWeightMaintenance;
        int32 shortWeightMaintenance;
        int128 priceX18;
    }

    struct Risk {
        int128 longWeightInitialX18;
        int128 shortWeightInitialX18;
        int128 longWeightMaintenanceX18;
        int128 shortWeightMaintenanceX18;
        int128 priceX18;
    }

    function _getSpreadHealthRebateAmount(
        Risk memory perpRisk,
        int128 basisAmount,
        int128 priceSumX18,
        IProductEngine.HealthType healthType
    ) internal pure returns (int128) {
        // 5x more leverage than the standard perp
        // by refunding 4/5 of the health penalty
        int128 rebateRateX18 = ((ONE - _getWeightX18(perpRisk, 1, healthType)) *
            4) / 5;
        return rebateRateX18.mul(priceSumX18).mul(basisAmount);
    }

    function _getLpRawValue(
        int128 baseAmount,
        int128 quoteAmount,
        int128 priceX18
    ) internal pure returns (int128) {
        // naive way: value an LP token by value of the raw components 2 * arithmetic mean of base value and quote value
        // price manipulation proof way: use the geometric mean
        return
            2 *
            int128(
                MathHelper.sqrt256(
                    int256(baseAmount.mul(priceX18)) * quoteAmount
                )
            );
    }

    function _getWeightX18(
        Risk memory risk,
        int128 amount,
        IProductEngine.HealthType healthType
    ) internal pure returns (int128) {
        // (1 + imf * sqrt(amount))
        if (healthType == IProductEngine.HealthType.PNL) {
            return ONE;
        }

        int128 weight;
        if (amount >= 0) {
            weight = healthType == IProductEngine.HealthType.INITIAL
                ? risk.longWeightInitialX18
                : risk.longWeightMaintenanceX18;
        } else {
            weight = healthType == IProductEngine.HealthType.INITIAL
                ? risk.shortWeightInitialX18
                : risk.shortWeightMaintenanceX18;
        }

        return weight;
    }

    function isoGroup(uint32 productId) internal pure returns (uint32) {
        require(productId < 256, "unimplemented");
        // return productId >= 256 ? productId : 0;
        return 0;
    }

    function canTrade(bytes32 subaccount, uint32 productId)
        internal
        pure
        returns (bool)
    {
        require(
            isoGroup(subaccount) == 0 && isoGroup(productId) == 0,
            "unimplemented"
        );
        // if (productId == QUOTE_PRODUCT_ID) {
        //   return true;
        // }
        // return isoGroup(subaccount) == isoGroup(productId);
        return true;
    }

    // subaccount names encoding:
    // if endswith "iso" -> isolated margin account
    // productId a u32 specified by the 4 bytes before "iso"
    // i.e. |5 bytes| 4 byte product id| 'iso' |

    // frontend accounts are identified by starting with "defau"
    // if you are a frontend account, we use the linked signer
    // of the default frontend cross margin account:
    // |default| 0 0 0 0 0|

    function isoGroup(bytes32 subaccount) internal pure returns (uint32) {
        uint256 s = uint256(subaccount);
        // int.from_bytes(b'iso', byteorder='big')
        if (uint24(s) == 6910831) {
            return uint32(s >> 24);
        }
        return 0;
    }

    // if its a default frontend subaccount
    function isFrontendAccount(bytes32 subaccount)
        internal
        pure
        returns (bool)
    {
        /// int.from_bytes(b'defau', byteorder='big') << 56
        return
            (uint256(subaccount) & 31071085969061750775199301632) ==
            31071085969061750775199301632;
    }

    function defaultFrontendAccount(bytes32 sender)
        internal
        pure
        returns (bytes32)
    {
        uint256 s = uint256(sender);
        // (((1 << 21) - 1) << 96) | (int.from_bytes(b'default', byteorder='big') << 40)
        s &= 166153451316037938940915905023967232;
        // int.from_bytes(b'default', byteorder='big') << 40
        s |= 31071085969092277616032874496;
        return bytes32(s);
    }
}
