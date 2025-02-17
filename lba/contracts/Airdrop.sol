// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

import "./interfaces/ILBA.sol";
import "./interfaces/IVesting.sol";
import "./interfaces/IAirdrop.sol";
import "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

contract Airdrop is OwnableUpgradeable, IAirdrop {
    uint32 constant AIRDROP_EPOCH = 6;

    address token;
    address lba;

    uint32 pastEpochs;

    mapping(uint32 => bytes32) merkleRoots;

    // tokens will not be claimed after deadline.
    uint64[] public claimingDeadlines;
    mapping(uint32 => mapping(address => uint256)) claimed;

    function initialize(address _token, address _lba) external initializer {
        __Ownable_init();
        token = _token;
        lba = _lba;
        pastEpochs = AIRDROP_EPOCH - 1;
        for (uint32 i = 0; i < AIRDROP_EPOCH; i++) {
            claimingDeadlines.push(0);
        }
    }

    function registerMerkleRoot(
        uint32 epoch,
        uint64 deadline,
        bytes32 merkleRoot
    ) external onlyOwner {
        pastEpochs += 1;
        require(epoch == pastEpochs, "Invalid epoch provided.");
        claimingDeadlines.push(deadline);
        merkleRoots[epoch] = merkleRoot;
    }

    function _verifyProof(
        uint32 epoch,
        address sender,
        uint256 amount,
        uint256 totalAmount,
        bytes32[] calldata proof
    ) internal {
        require(amount > 0, "Trying to claim zero rewards.");
        require(
            claimed[epoch][sender] + amount <= totalAmount,
            "Trying to claim more rewards than unclaimed rewards."
        );
        require(
            merkleRoots[epoch] != bytes32(0),
            "Epoch hasn't been registered."
        );
        require(block.timestamp < claimingDeadlines[epoch], "deadline passed.");

        bytes32 leaf = keccak256(
            bytes.concat(keccak256(abi.encode(sender, totalAmount)))
        );
        bool isValidLeaf = MerkleProof.verify(proof, merkleRoots[epoch], leaf);
        require(isValidLeaf, "Invalid proof.");

        claimed[epoch][sender] += amount;
    }

    function claimToLBA(
        uint256 amount,
        uint256 totalAmount,
        bytes32[] calldata proof
    ) external {
        _verifyProof(AIRDROP_EPOCH, msg.sender, amount, totalAmount, proof);
        require(
            ILBA(lba).getStage() == ILBA.Stage.DepositingTokens,
            "Depositing to LBA has ended."
        );
        SafeERC20.safeApprove(IERC20(token), lba, amount);
        ILBA(lba).depositVrtx(msg.sender, amount);
    }

    function claim(
        uint32 epoch,
        uint256 amount,
        uint256 totalAmount,
        bytes32[] calldata proof
    ) external {
        _verifyProof(epoch, msg.sender, amount, totalAmount, proof);
        if (epoch == AIRDROP_EPOCH) {
            // airdrop phase
            require(
                ILBA(lba).getStage() == ILBA.Stage.LpMinted,
                "LBA hasn't finished, can't claim to wallet."
            );
        }
        SafeERC20.safeTransfer(IERC20(token), msg.sender, amount);
    }

    function distributeRewards(uint256 amount) external onlyOwner {
        SafeERC20.safeApprove(IERC20(token), lba, amount);
        ILBA(lba).distributeRewards(amount);
    }

    function getClaimed(
        address account
    ) external view returns (uint256[] memory) {
        uint256[] memory result = new uint256[](pastEpochs + 1);
        for (uint32 epoch = AIRDROP_EPOCH; epoch <= pastEpochs; epoch++) {
            result[epoch] = claimed[epoch][account];
        }
        return result;
    }

    function getClaimingDeadlines() external view returns (uint64[] memory) {
        return claimingDeadlines;
    }
}
