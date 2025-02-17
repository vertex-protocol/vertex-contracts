// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

import "./interfaces/ILBA.sol";
import "./interfaces/IVesting.sol";
import "./interfaces/IStaking.sol";
import "./interfaces/IStakingV2.sol";
import "./interfaces/IAirdrop.sol";
import "./interfaces/ISanctionsList.sol";
import "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

contract Airdrop is OwnableUpgradeable, IAirdrop {
    address token;
    address lba;
    address sanctions;
    uint32 airdropEpoch;
    uint32 pastEpochs;

    mapping(uint32 => bytes32) merkleRoots;

    // tokens will not be claimed after deadline.
    uint64[] public claimingDeadlines;
    mapping(uint32 => mapping(address => uint256)) claimed;

    address staking;
    address stakingV2;

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(
        address _token,
        address _lba,
        address _sanctions,
        uint32 _airdropEpoch
    ) external initializer {
        __Ownable_init();
        token = _token;
        lba = _lba;
        airdropEpoch = _airdropEpoch;
        pastEpochs = airdropEpoch - 1;
        sanctions = _sanctions;
        for (uint32 i = 0; i < airdropEpoch; i++) {
            claimingDeadlines.push(0);
        }
    }

    function registerStakingV2(address _stakingV2) external onlyOwner {
        require(stakingV2 == address(0), "already registered.");
        stakingV2 = _stakingV2;
    }

    function registerStaking(address _staking) external onlyOwner {
        require(staking == address(0), "already registered.");
        staking = _staking;
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
        require(
            !ISanctionsList(sanctions).isSanctioned(sender),
            "address is sanctioned."
        );

        bytes32 leaf = keccak256(
            bytes.concat(keccak256(abi.encode(sender, totalAmount)))
        );
        bool isValidLeaf = MerkleProof.verify(proof, merkleRoots[epoch], leaf);
        require(isValidLeaf, "Invalid proof.");

        claimed[epoch][sender] += amount;
        emit ClaimVrtx(sender, epoch, amount);
    }

    function claimToLBA(
        uint256 amount,
        uint256 totalAmount,
        bytes32[] calldata proof
    ) external {
        _verifyProof(airdropEpoch, msg.sender, amount, totalAmount, proof);
        require(
            ILBA(lba).getStage() == ILBA.Stage.DepositingTokens,
            "Not at Depositing to LBA stage."
        );
        SafeERC20.safeApprove(IERC20(token), lba, amount);
        ILBA(lba).depositVrtx(msg.sender, amount);
    }

    function claim(
        uint32 epoch,
        uint256 amount,
        uint256 totalAmount,
        bytes32[] calldata proof
    ) public {
        _verifyProof(epoch, msg.sender, amount, totalAmount, proof);
        if (epoch == airdropEpoch) {
            // airdrop phase
            require(
                ILBA(lba).getStage() >= ILBA.Stage.LpMinted,
                "LBA hasn't finished, can't claim to wallet."
            );
        }
        SafeERC20.safeTransfer(IERC20(token), msg.sender, amount);
    }

    function claimAndStake(
        uint32 epoch,
        uint256 amount,
        uint256 totalAmount,
        bytes32[] calldata proof
    ) external {
        _verifyProof(epoch, msg.sender, amount, totalAmount, proof);
        if (epoch == airdropEpoch) {
            // airdrop phase
            require(
                ILBA(lba).getStage() >= ILBA.Stage.LpMinted,
                "LBA hasn't finished, can't claim to wallet."
            );
        }
        uint64 v2StartTime = IStaking(staking).getV2StartTime();
        if (v2StartTime == 0 || block.timestamp < v2StartTime) {
            SafeERC20.safeApprove(IERC20(token), staking, amount);
            IStaking(staking).stakeAs(msg.sender, amount);
        } else {
            SafeERC20.safeApprove(IERC20(token), stakingV2, amount);
            IStakingV2(stakingV2).stakeAs(msg.sender, uint128(amount));
        }
    }

    function distributeRewards(uint256 amount) external onlyOwner {
        SafeERC20.safeApprove(IERC20(token), lba, amount);
        ILBA(lba).distributeRewards(amount);
    }

    function getClaimed(
        address account
    ) external view returns (uint256[] memory) {
        uint256[] memory result = new uint256[](pastEpochs + 1);
        for (uint32 epoch = airdropEpoch; epoch <= pastEpochs; epoch++) {
            result[epoch] = claimed[epoch][account];
        }
        return result;
    }

    function getClaimingDeadlines() external view returns (uint64[] memory) {
        return claimingDeadlines;
    }

    function setClaimingDeadline(
        uint32 epoch,
        uint64 claimingDeadline
    ) external onlyOwner {
        require(
            epoch < claimingDeadlines.length,
            "epoch hasn't been registered."
        );
        claimingDeadlines[epoch] = claimingDeadline;
    }
}
