// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/cryptography/draft-EIP712Upgradeable.sol";
import "./Endpoint.sol";
import "./interfaces/IOffchainExchange.sol";
import "./interfaces/clearinghouse/IClearinghouse.sol";
import "./common/Errors.sol";
import "./common/Constants.sol";
import "./libraries/ERC20Helper.sol";
import "./libraries/MathHelper.sol";
import "./libraries/RippleBase58.sol";
import "./interfaces/engine/ISpotEngine.sol";
import "./interfaces/engine/IPerpEngine.sol";
import "./interfaces/IEndpoint.sol";
import "./interfaces/IERC20Base.sol";

import {IAxelarGateway} from "@axelar-network/axelar-gmp-sdk-solidity/contracts/interfaces/IAxelarGateway.sol";
import {IInterchainTokenService} from "@axelar-network/interchain-token-service/contracts/interfaces/IInterchainTokenService.sol";

contract VertexGateway is EIP712Upgradeable, OwnableUpgradeable {
    bytes32 internal constant EXECUTE_SUCCESS =
        keccak256("its-execute-success");
    using ERC20Helper for IERC20Base;
    using RippleBase58 for bytes;

    struct Config {
        bytes32 tokenId;
        address token;
    }

    address internal endpoint;
    address internal axelarGateway;
    address internal axelarGasService;
    address payable internal interchainTokenService;
    string public sourceChain;

    mapping(uint32 => Config) public configs;
    mapping(address => bytes32) internal tokenIds;
    mapping(address => bytes) public rippleAddresses;

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(
        address _endpoint,
        address _axelarGateway,
        address _axelarGasService,
        address payable _interchainTokenService,
        string calldata _sourceChain
    ) external initializer {
        __Ownable_init();
        endpoint = _endpoint;
        axelarGateway = _axelarGateway;
        axelarGasService = _axelarGasService;
        interchainTokenService = _interchainTokenService;
        sourceChain = _sourceChain;
    }

    modifier onlyIts() {
        require(
            msg.sender == interchainTokenService,
            "Not InterchainTokenService"
        );
        _;
    }

    function equal(string memory a, string memory b)
        internal
        pure
        returns (bool)
    {
        return
            bytes(a).length == bytes(b).length &&
            keccak256(bytes(a)) == keccak256(bytes(b));
    }

    function addProduct(
        uint32 productId,
        bytes32 tokenId,
        address token
    ) external onlyOwner {
        configs[productId] = Config({tokenId: tokenId, token: token});
        tokenIds[token] = tokenId;
    }

    function execute(
        bytes32 commandId,
        string calldata _sourceChain,
        string calldata sourceAddress,
        bytes calldata payload
    ) external {
        require(equal(sourceChain, _sourceChain), "Not authored sourceChain");
        bytes32 payloadHash = keccak256(payload);
        require(
            IAxelarGateway(axelarGateway).validateContractCall(
                commandId,
                _sourceChain,
                sourceAddress,
                payloadHash
            ),
            "Not approved by gateway."
        );
        address sender = bytes(sourceAddress).decodeFromRippleAddress();
        bytes12 subaccountName;
        address signer;
        (subaccountName, signer) = abi.decode(payload, (bytes12, address));
        bytes32 subaccount = bytes32(abi.encodePacked(sender, subaccountName));

        linkSigner(subaccount, signer);
    }

    function executeWithInterchainToken(
        bytes32 commandId,
        string calldata _sourceChain,
        bytes calldata sourceAddress,
        bytes calldata payload,
        bytes32 tokenId,
        address token,
        uint256 amount
    ) external onlyIts returns (bytes32) {
        require(equal(sourceChain, _sourceChain), "Not authored sourceChain");
        address sender = sourceAddress.decodeFromRippleAddress();
        rippleAddresses[sender] = sourceAddress;
        bytes12 subaccountName;
        address signer;
        uint32 productId;
        (subaccountName, productId, signer) = abi.decode(
            payload,
            (bytes12, uint32, address)
        );
        bytes32 subaccount = bytes32(abi.encodePacked(sender, subaccountName));
        require(configs[productId].token == token, "product mismatched");
        IERC20Base(token).approve(endpoint, amount);
        IEndpoint(endpoint).depositCollateralWithReferral(
            subaccount,
            productId,
            uint128(amount),
            "VertexGateway"
        );

        if (signer != address(0)) {
            linkSigner(subaccount, signer);
        }

        return EXECUTE_SUCCESS;
    }

    function linkSigner(bytes32 sender, address signer) internal {
        bytes32 signerSubaccount = bytes32(uint256(uint160(signer)) << 96);
        IEndpoint.LinkSigner memory linkSigner = IEndpoint.LinkSigner(
            sender,
            signerSubaccount,
            IEndpoint(endpoint).getNonce(signer)
        );
        bytes memory linkSignerTx = abi.encodePacked(
            uint8(19),
            abi.encode(linkSigner)
        );
        Endpoint(endpoint).submitSlowModeTransaction(linkSignerTx);
    }

    function isNativeWallet(address wallet) external view returns (bool) {
        return rippleAddresses[wallet].length == 0;
    }

    function withdraw(
        IERC20Base token,
        address to,
        uint256 amount
    ) external {
        token.safeTransferFrom(msg.sender, address(this), amount);
        token.approve(interchainTokenService, amount);
        bytes32 tokenId = tokenIds[address(token)];
        bytes memory rippleAddress = rippleAddresses[to];
        IInterchainTokenService(interchainTokenService).interchainTransfer{
            value: uint256(uint128(ONE))
        }(
            tokenId,
            sourceChain,
            rippleAddress,
            amount,
            "",
            uint256(uint128(ONE))
        );
    }
}
