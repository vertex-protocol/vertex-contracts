// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

import "prb-math/contracts/PRBMathSD59x18.sol";
import "@openzeppelin/contracts/utils/Base64.sol";
import "./Clearinghouse.sol";

contract FClearinghouse is Clearinghouse {
    using PRBMathSD59x18 for int256;
    // token => balance
    mapping(address => uint256) public tokenBalances;

    function handleDepositTransfer(
        IERC20Base token,
        address,
        uint256 amount
    ) internal override {
        tokenBalances[address(token)] += amount;
    }

    function handleWithdrawTransfer(
        IERC20Base token,
        address,
        uint256 amount
    ) internal override {
        require(tokenBalances[address(token)] >= amount, "balance is too low");
        tokenBalances[address(token)] -= amount;
    }

    function createSubaccount(
        address owner,
        string calldata subaccountName
    ) external {
        _loadSubaccount(owner, subaccountName);
    }

    function setInsurance(int256 amount) external {
        insuranceX18 = PRBMathSD59x18.fromInt(amount);
    }

    function setTokenBalance(address token, uint256 amount) external {
        tokenBalances[token] = amount;
    }

    struct Delta {
        uint32 productId;
        int256 priceX18;
        int256 baseDeltaX18;
        int256 quoteDeltaX18;
    }

    function getHealthX18WithDelta(
        uint64 subaccountId,
        IProductEngine.HealthType healthType,
        Delta memory delta
    ) public {
        IProductEngine.ProductDelta[]
            memory quoteDelta = new IProductEngine.ProductDelta[](1);

        quoteDelta[0] = IProductEngine.ProductDelta({
            productId: QUOTE_PRODUCT_ID,
            subaccountId: subaccountId,
            amountDeltaX18: delta.quoteDeltaX18,
            vQuoteDeltaX18: 0
        });

        engineByType[IProductEngine.EngineType.SPOT].applyDeltas(quoteDelta);

        IProductEngine.ProductDelta[]
            memory baseDelta = new IProductEngine.ProductDelta[](1);

        baseDelta[0] = IProductEngine.ProductDelta({
            productId: delta.productId,
            subaccountId: subaccountId,
            amountDeltaX18: delta.baseDeltaX18,
            vQuoteDeltaX18: 0
        });

        productToEngine[delta.productId].applyDeltas(baseDelta);

        if (delta.priceX18 != 0) {
            address endpoint = getEndpoint();
            IEndpoint(endpoint).setPriceX18(delta.productId, delta.priceX18);
        }

        revert(
            Base64.encode(
                abi.encode(this.getHealthX18(subaccountId, healthType))
            )
        );
    }
}
