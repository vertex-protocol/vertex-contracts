// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "./libraries/MathHelper.sol";
import "./interfaces/IEndpoint.sol";
import "./Verifier.sol";
import "./interfaces/engine/ISpotEngine.sol";
import "./interfaces/IERC20Base.sol";
import "./libraries/ERC20Helper.sol";
import "./common/Constants.sol";
import "./BaseWithdrawPool.sol";
import "./VertexGateway.sol";

contract WithdrawPoolRipple is BaseWithdrawPool {
    using ERC20Helper for IERC20Base;
    address internal vertexGateway;

    function initialize(
        address _clearinghouse,
        address _verifier,
        address _vertexGateway
    ) external {
        _initialize(_clearinghouse, _verifier);
        vertexGateway = _vertexGateway;
    }

    function handleWithdrawTransfer(
        IERC20Base token,
        address to,
        uint128 amount
    ) internal override {
        if (VertexGateway(vertexGateway).isNativeWallet(to)) {
            token.safeTransfer(to, uint256(amount));
        } else {
            token.approve(vertexGateway, uint256(amount));
            VertexGateway(vertexGateway).withdraw(token, to, uint256(amount));
        }
    }
}
