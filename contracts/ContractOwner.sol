pragma solidity ^0.8.0;

import "@openzeppelin/contracts-upgradeable/utils/cryptography/EIP712Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "./interfaces/engine/ISpotEngine.sol";
import "./interfaces/engine/IPerpEngine.sol";
import "./interfaces/engine/IProductEngine.sol";
import {SpotEngine} from "./SpotEngine.sol";
import "./PerpEngine.sol";
import "./Endpoint.sol";
import "./Verifier.sol";
import "./WithdrawPool.sol";

contract ContractOwner is EIP712Upgradeable, OwnableUpgradeable {
    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(
        address multisig,
        address _deployer,
        address _spotEngine,
        address _perpEngine,
        address _endpoint,
        address _clearinghouse,
        address _verifier
    ) external initializer {
        require(_deployer == msg.sender, "expected deployed to initialize");
        __Ownable_init();
        transferOwnership(multisig);
        deployer = _deployer;
        spotEngine = SpotEngine(_spotEngine);
        perpEngine = PerpEngine(_perpEngine);
        endpoint = Endpoint(_endpoint);
        clearinghouse = IClearinghouse(_clearinghouse);
        verifier = Verifier(_verifier);
    }

    address deployer;
    SpotEngine spotEngine;
    PerpEngine perpEngine;
    Endpoint endpoint;
    IClearinghouse clearinghouse;
    Verifier verifier;
    LegacySpotAddProductCall[] spotAddProductCalls; // deprecated
    PerpAddProductCall[] perpAddProductCalls; // deprecated
    bytes[] internal updateProductTxs;

    // using `bytes[]` in case we will change the layout of the calls.
    bytes[] internal rawSpotAddProductCalls;
    bytes[] internal rawPerpAddProductCalls;

    modifier onlyDeployer() {
        require(msg.sender == deployer, "sender must be deployer");
        _;
    }

    struct LegacySpotAddProductCall {
        uint32 productId;
        address book;
        int128 sizeIncrement;
        int128 minSize;
        int128 lpSpreadX18;
        ISpotEngine.Config config;
        RiskHelper.RiskStore riskStore;
    }

    struct SpotAddProductCall {
        uint32 productId;
        uint32 quoteId;
        address book;
        int128 sizeIncrement;
        int128 minSize;
        int128 lpSpreadX18;
        ISpotEngine.Config config;
        RiskHelper.RiskStore riskStore;
    }

    struct PerpAddProductCall {
        uint32 productId;
        address book;
        int128 sizeIncrement;
        int128 minSize;
        int128 lpSpreadX18;
        RiskHelper.RiskStore riskStore;
    }

    function submitSpotAddProductCall(
        uint32 productId,
        uint32 quoteId,
        address book,
        int128 sizeIncrement,
        int128 minSize,
        int128 lpSpreadX18,
        ISpotEngine.Config calldata config,
        RiskHelper.RiskStore calldata riskStore
    ) external onlyDeployer {
        uint32[] memory pendingIds = pendingSpotAddProductIds();
        for (uint256 i = 0; i < pendingIds.length; i++) {
            require(
                productId != pendingIds[i],
                "trying to add a spot product twice."
            );
        }
        rawSpotAddProductCalls.push(
            abi.encode(
                SpotAddProductCall(
                    productId,
                    quoteId,
                    book,
                    sizeIncrement,
                    minSize,
                    lpSpreadX18,
                    config,
                    riskStore
                )
            )
        );
    }

    function submitPerpAddProductCall(
        uint32 productId,
        address book,
        int128 sizeIncrement,
        int128 minSize,
        int128 lpSpreadX18,
        RiskHelper.RiskStore calldata riskStore
    ) external onlyDeployer {
        uint32[] memory pendingIds = pendingPerpAddProductIds();
        for (uint256 i = 0; i < pendingIds.length; i++) {
            require(
                productId != pendingIds[i],
                "trying to add a perp product twice."
            );
        }
        rawPerpAddProductCalls.push(
            abi.encode(
                PerpAddProductCall(
                    productId,
                    book,
                    sizeIncrement,
                    minSize,
                    lpSpreadX18,
                    riskStore
                )
            )
        );
    }

    function clearSpotAddProductCalls() external onlyDeployer {
        delete rawSpotAddProductCalls;
    }

    function clearPerpAddProductCalls() external onlyDeployer {
        delete rawPerpAddProductCalls;
    }

    function addProducts(uint32[] memory spotIds, uint32[] memory perpIds)
        external
        onlyOwner
    {
        for (uint256 i = 0; i < rawSpotAddProductCalls.length; i++) {
            SpotAddProductCall memory call = abi.decode(
                rawSpotAddProductCalls[i],
                (SpotAddProductCall)
            );
            require(spotIds[i] == call.productId, "spot id doesn't match.");
            spotEngine.addProduct(
                call.productId,
                call.quoteId,
                call.book,
                call.sizeIncrement,
                call.minSize,
                call.lpSpreadX18,
                call.config,
                call.riskStore
            );
        }
        delete rawSpotAddProductCalls;

        for (uint256 i = 0; i < rawPerpAddProductCalls.length; i++) {
            PerpAddProductCall memory call = abi.decode(
                rawPerpAddProductCalls[i],
                (PerpAddProductCall)
            );
            require(perpIds[i] == call.productId, "perp id doesn't match.");
            perpEngine.addProduct(
                call.productId,
                call.book,
                call.sizeIncrement,
                call.minSize,
                call.lpSpreadX18,
                call.riskStore
            );
        }
        delete rawPerpAddProductCalls;
    }

    function pendingSpotAddProductIds() public view returns (uint32[] memory) {
        uint32[] memory productIds = new uint32[](
            rawSpotAddProductCalls.length
        );
        for (uint256 i = 0; i < rawSpotAddProductCalls.length; i++) {
            SpotAddProductCall memory call = abi.decode(
                rawSpotAddProductCalls[i],
                (SpotAddProductCall)
            );
            productIds[i] = call.productId;
        }
        return productIds;
    }

    function pendingPerpAddProductIds() public view returns (uint32[] memory) {
        uint32[] memory productIds = new uint32[](
            rawPerpAddProductCalls.length
        );
        for (uint256 i = 0; i < rawPerpAddProductCalls.length; i++) {
            SpotAddProductCall memory call = abi.decode(
                rawPerpAddProductCalls[i],
                (SpotAddProductCall)
            );
            productIds[i] = call.productId;
        }
        return productIds;
    }

    function hasPendingAddProductCalls() public view returns (bool) {
        return
            rawPerpAddProductCalls.length > 0 ||
            rawSpotAddProductCalls.length > 0;
    }

    function submitUpdateProductTx(bytes calldata slowModeTx)
        external
        onlyDeployer
    {
        updateProductTxs.push(slowModeTx);
    }

    function clearUpdateProductTxs() external onlyDeployer {
        delete updateProductTxs;
    }

    function batchSubmitUpdateProductTxs(bytes[] calldata slowModeTxs)
        external
        onlyDeployer
    {
        for (uint256 i = 0; i < slowModeTxs.length; i++) {
            bytes memory txn = slowModeTxs[i];
            updateProductTxs.push(txn);
        }
    }

    function updateProducts() external onlyOwner {
        for (uint256 i = 0; i < updateProductTxs.length; i++) {
            bytes memory txn = updateProductTxs[i];
            endpoint.submitSlowModeTransaction(txn);
        }
        delete updateProductTxs;
    }

    function hasPendingUpdateProductTxs() public view returns (bool) {
        return updateProductTxs.length > 0;
    }

    function addEngine(
        address engine,
        address offchainExchange,
        IProductEngine.EngineType engineType
    ) external onlyOwner {
        clearinghouse.addEngine(engine, offchainExchange, engineType);
    }

    function assignPubKey(
        uint256 i,
        uint256 x,
        uint256 y
    ) public onlyOwner {
        verifier.assignPubKey(i, x, y);
    }

    function deletePubkey(uint256 index) public onlyOwner {
        verifier.deletePubkey(index);
    }

    function spotUpdateRisk(
        uint32 productId,
        RiskHelper.RiskStore memory riskStore
    ) external onlyOwner {
        spotEngine.updateRisk(productId, riskStore);
    }

    function perpUpdateRisk(
        uint32 productId,
        RiskHelper.RiskStore memory riskStore
    ) external onlyOwner {
        perpEngine.updateRisk(productId, riskStore);
    }

    function setWithdrawPool(address _withdrawPool) external onlyOwner {
        clearinghouse.setWithdrawPool(_withdrawPool);
    }

    function removeWithdrawPoolLiquidity(
        uint32 productId,
        uint128 amount,
        address sendTo
    ) external onlyOwner {
        WithdrawPool withdrawPool = WithdrawPool(
            clearinghouse.getWithdrawPool()
        );
        withdrawPool.removeLiquidity(productId, amount, sendTo);
    }
}
