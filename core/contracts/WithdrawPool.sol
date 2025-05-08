// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/cryptography/draft-EIP712Upgradeable.sol";
import "./libraries/MathHelper.sol";
import "./interfaces/IEndpoint.sol";
import "./Verifier.sol";
import "./interfaces/engine/ISpotEngine.sol";
import "./interfaces/IERC20Base.sol";
import "./libraries/ERC20Helper.sol";
import "./common/Constants.sol";
import "./BaseWithdrawPool.sol";

contract WithdrawPool is BaseWithdrawPool {
    function initialize(address _clearinghouse, address _verifier) external {
        _initialize(_clearinghouse, _verifier);
    }
}
