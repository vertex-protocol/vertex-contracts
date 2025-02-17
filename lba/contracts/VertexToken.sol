// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";

contract VertexToken is Initializable, ERC20Upgradeable, OwnableUpgradeable {
    using EnumerableSet for EnumerableSet.AddressSet;

    event MintAccessGranted(address indexed minter);
    event BurnAccessGranted(address indexed burner);
    event MintAccessRevoked(address indexed minter);
    event BurnAccessRevoked(address indexed burner);

    EnumerableSet.AddressSet private minters;
    EnumerableSet.AddressSet private burners;

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize() external initializer {
        __ERC20_init("Vertex", "VRTX");
        __Ownable_init();
    }

    function mint(address account, uint256 amount) external onlyMinter {
        _mint(account, amount);
    }

    function burn(uint256 amount) external onlyBurner {
        _burn(msg.sender, amount);
    }

    function grantMintRole(address minter) external onlyOwner {
        if (minters.add(minter)) {
            emit MintAccessGranted(minter);
        }
    }

    function grantBurnRole(address burner) external onlyOwner {
        if (burners.add(burner)) {
            emit BurnAccessGranted(burner);
        }
    }

    function revokeMintRole(address minter) external onlyOwner {
        if (minters.remove(minter)) {
            emit MintAccessRevoked(minter);
        }
    }

    function revokeBurnRole(address burner) external onlyOwner {
        if (burners.remove(burner)) {
            emit BurnAccessRevoked(burner);
        }
    }

    function getMinters() external view returns (address[] memory) {
        return minters.values();
    }

    function getBurners() external view returns (address[] memory) {
        return burners.values();
    }

    modifier onlyMinter() {
        require(minters.contains(msg.sender), "only minter can mint tokens.");
        _;
    }

    modifier onlyBurner() {
        require(burners.contains(msg.sender), "only burner can burn tokens.");
        _;
    }
}
