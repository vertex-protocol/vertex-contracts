// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

import "./interfaces/IStaking.sol";
import "./interfaces/ISanctionsList.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";

contract Staking is IStaking, OwnableUpgradeable {
    uint32 constant BOOST_LENGTH = 3600 * 24 * 183; // 183 days
    uint256 constant BASE_SCORE_MULTIPLIER = 2;
    uint256 constant BOOST_SCORE_MULTIPLIER = 3;
    uint32 constant INF = type(uint32).max;

    address vrtxToken;
    address usdcToken;
    address sanctions;
    State globalState;
    QueueIndex segIndex;
    uint64 numCheckpoints;
    uint64 withdrawLockingTime;

    mapping(uint64 => Segment) toApplySegments;
    // whenever `account` withdraws VRTX, its version gets increased by one.
    // so that all previous segments will be outdated and canceled.
    mapping(address => uint32) versions;
    mapping(address => State) states;
    mapping(address => QueueIndex) releaseScheduleIndexes;
    mapping(address => mapping(uint64 => ReleaseSchedule)) releaseSchedules;
    mapping(address => mapping(uint64 => uint256)) rewardsBreakdowns;
    mapping(address => uint64) toClaimCheckpoint;
    mapping(address => uint64) checkpointIndexes;
    mapping(uint64 => Checkpoint) checkpoints;
    mapping(address => LastActionTimes) lastActionTimes;

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(
        address _vrtxToken,
        address _usdcToken,
        address _sanctions,
        uint32 _withdrawLockingTime
    ) external initializer {
        __Ownable_init();
        vrtxToken = _vrtxToken;
        usdcToken = _usdcToken;
        sanctions = _sanctions;
        withdrawLockingTime = _withdrawLockingTime;
    }

    function _updateStates(Segment memory segment) internal {
        address owner = segment.owner;
        // the segment is already outdated.
        if (versions[owner] != segment.version) {
            return;
        }
        _processAllCheckpoints(owner);
        states[owner].sumSize += segment.vrtxSize;
        states[owner].sumSizeXTime +=
            segment.vrtxSize *
            int64(segment.startTime);
        globalState.sumSize += segment.vrtxSize;
        globalState.sumSizeXTime += segment.vrtxSize * int64(segment.startTime);
    }

    function _applySegment(
        QueueIndex memory _segIndex
    ) internal returns (bool) {
        if (_segIndex.upTo >= _segIndex.count) {
            return false;
        }
        Segment memory segment = toApplySegments[_segIndex.upTo];
        if (segment.startTime > uint64(block.timestamp)) {
            return false;
        }
        delete toApplySegments[_segIndex.upTo++];
        _updateStates(segment);
        return true;
    }

    function _applySegments(
        QueueIndex memory _segIndex,
        uint32 maxSegments
    ) internal {
        for (uint32 i = 0; i < maxSegments; i++) {
            if (!_applySegment(_segIndex)) {
                break;
            }
        }
    }

    function _processAllSegments() internal {
        QueueIndex memory _segIndex = segIndex;
        _applySegments(_segIndex, INF);
        segIndex = _segIndex;
    }

    function _processAllCheckpoints(address account) internal {
        uint256[] memory rewardsBreakdown = getRewardsBreakdown(account);
        for (uint64 i = checkpointIndexes[account]; i < numCheckpoints; i++) {
            rewardsBreakdowns[account][i] = rewardsBreakdown[i];
        }
        checkpointIndexes[account] = numCheckpoints;
    }

    // in case there are too many segments to be applied that they can't be applied
    // within a single tx, we can manually apply them by using this through multiple txs.
    function processSegments(uint32 count) external {
        QueueIndex memory _segIndex = segIndex;
        _applySegments(_segIndex, count);
        segIndex = _segIndex;
    }

    function stake(uint256 amount) external {
        require(amount > 0, "Trying to stake 0 tokens.");
        address sender = msg.sender;
        require(
            !ISanctionsList(sanctions).isSanctioned(sender),
            "address is sanctioned."
        );
        _processAllSegments();
        _processAllCheckpoints(sender);
        SafeERC20.safeTransferFrom(
            IERC20(vrtxToken),
            sender,
            address(this),
            amount
        );
        states[sender].vrtxStaked += amount;
        globalState.vrtxStaked += amount;

        uint64 currentTime = uint64(block.timestamp);
        uint32 userVersion = versions[sender];
        _updateStates(
            Segment({
                startTime: currentTime,
                vrtxSize: int256(amount),
                owner: sender,
                version: userVersion
            })
        );
        toApplySegments[segIndex.count++] = Segment({
            startTime: currentTime + BOOST_LENGTH,
            vrtxSize: -int256(amount),
            owner: sender,
            version: userVersion
        });
        lastActionTimes[sender].lastStakeTime = currentTime;
    }

    function withdraw(uint256 amount) external {
        require(amount > 0, "Trying to withdraw 0 staked tokens");
        address sender = msg.sender;
        require(
            !ISanctionsList(sanctions).isSanctioned(sender),
            "address is sanctioned."
        );
        _processAllSegments();
        _processAllCheckpoints(sender);
        require(
            amount <= states[sender].vrtxStaked,
            "Trying to withdraw more VRTX than staked."
        );
        states[sender].vrtxStaked -= amount;
        globalState.vrtxStaked -= amount;

        // clear legacy states.
        uint64 currentTime = uint64(block.timestamp);
        globalState.sumSize -= states[sender].sumSize;
        globalState.sumSizeXTime -= states[sender].sumSizeXTime;
        states[sender].sumSize = 0;
        states[sender].sumSizeXTime = 0;
        versions[sender] += 1;

        // apply new states.
        uint32 userVersion = versions[sender];
        uint256 newAmount = states[sender].vrtxStaked;
        _updateStates(
            Segment({
                startTime: currentTime,
                vrtxSize: int256(newAmount),
                owner: sender,
                version: userVersion
            })
        );

        toApplySegments[segIndex.count++] = Segment({
            startTime: currentTime + BOOST_LENGTH,
            vrtxSize: -int256(newAmount),
            owner: sender,
            version: userVersion
        });

        releaseSchedules[sender][
            releaseScheduleIndexes[sender].count++
        ] = ReleaseSchedule({
            releaseTime: currentTime + withdrawLockingTime,
            amount: amount
        });
        lastActionTimes[sender].lastWithdrawTime = currentTime;
    }

    function claimVrtx() external {
        address sender = msg.sender;
        require(
            !ISanctionsList(sanctions).isSanctioned(sender),
            "address is sanctioned."
        );
        _processAllSegments();
        _processAllCheckpoints(sender);
        QueueIndex memory index = releaseScheduleIndexes[sender];
        uint64 currentTime = uint64(block.timestamp);
        uint256 vrtxClaimable = 0;
        while (index.upTo < index.count) {
            ReleaseSchedule memory schedule = releaseSchedules[sender][
                index.upTo
            ];
            if (currentTime >= schedule.releaseTime) {
                vrtxClaimable += schedule.amount;
                delete releaseSchedules[sender][index.upTo++];
            } else {
                break;
            }
        }
        releaseScheduleIndexes[sender] = index;
        require(vrtxClaimable > 0, "No VRTX to claim.");
        SafeERC20.safeTransfer(IERC20(vrtxToken), sender, vrtxClaimable);
    }

    function claimUsdc() external {
        address sender = msg.sender;
        require(
            !ISanctionsList(sanctions).isSanctioned(sender),
            "address is sanctioned."
        );
        _processAllSegments();
        _processAllCheckpoints(sender);
        uint256 unclaimedRewards = 0;
        for (uint64 i = toClaimCheckpoint[sender]; i < numCheckpoints; i++) {
            unclaimedRewards += rewardsBreakdowns[sender][i];
        }
        toClaimCheckpoint[sender] = numCheckpoints;
        require(unclaimedRewards > 0, "No USDC to claim.");
        SafeERC20.safeTransfer(IERC20(usdcToken), sender, unclaimedRewards);
    }

    function distributeRewards(uint256 amount) external onlyOwner {
        require(amount > 0, "must distribute non-zero rewards.");
        _processAllSegments();
        uint64 currentTime = uint64(block.timestamp);
        address sender = msg.sender;
        SafeERC20.safeTransferFrom(
            IERC20(usdcToken),
            sender,
            address(this),
            amount
        );
        checkpoints[numCheckpoints++] = Checkpoint({
            time: currentTime,
            vrtxStaked: globalState.vrtxStaked,
            sumSize: globalState.sumSize,
            sumSizeXTime: globalState.sumSizeXTime,
            rewards: amount
        });
    }

    function getWithdrawnVrtxStates(
        address account
    ) external view returns (WithdrawnVrtxStates memory withdrawnVrtxStates) {
        QueueIndex memory index = releaseScheduleIndexes[account];
        uint64 currentTime = uint64(block.timestamp);
        while (index.upTo < index.count) {
            ReleaseSchedule memory schedule = releaseSchedules[account][
                index.upTo
            ];
            if (currentTime >= schedule.releaseTime) {
                withdrawnVrtxStates.vrtxClaimable += schedule.amount;
            } else {
                withdrawnVrtxStates.vrtxPendingUnlock += schedule.amount;
            }
            index.upTo += 1;
        }
    }

    function getUsdcClaimable(
        address account
    ) external view returns (uint256 usdcClaimable) {
        uint256[] memory rewardsBreakdown = getRewardsBreakdown(account);
        for (uint64 i = toClaimCheckpoint[account]; i < numCheckpoints; i++) {
            usdcClaimable += rewardsBreakdown[i];
        }
    }

    function getRewardsBreakdown(
        address account
    ) public view returns (uint256[] memory) {
        uint256[] memory rewardsBreakdown = new uint256[](numCheckpoints);
        for (uint64 i = 0; i < numCheckpoints; i++) {
            if (i < checkpointIndexes[account]) {
                rewardsBreakdown[i] = rewardsBreakdowns[account][i];
            } else {
                Checkpoint memory checkpoint = checkpoints[i];
                uint256 accountScore = _getScoreAtTime(
                    states[account],
                    checkpoint.time
                );
                uint256 totalScore = _getScoreAtTime(
                    State({
                        vrtxStaked: checkpoint.vrtxStaked,
                        sumSize: checkpoint.sumSize,
                        sumSizeXTime: checkpoint.sumSizeXTime
                    }),
                    checkpoint.time
                );
                rewardsBreakdown[i] =
                    (accountScore * checkpoint.rewards) /
                    totalScore;
            }
        }
        return rewardsBreakdown;
    }

    function getGlobalRewardsBreakdown()
        external
        view
        returns (GlobalRewardsBreakdown[] memory)
    {
        GlobalRewardsBreakdown[]
            memory globalRewardsBreakdown = new GlobalRewardsBreakdown[](
                numCheckpoints
            );
        for (uint64 i = 0; i < numCheckpoints; i++) {
            globalRewardsBreakdown[i].distributionTime = checkpoints[i].time;
            globalRewardsBreakdown[i].rewardsAmount = checkpoints[i].rewards;
        }
        return globalRewardsBreakdown;
    }

    function getVrtxStaked(address account) external view returns (uint256) {
        return states[account].vrtxStaked;
    }

    function getTotalVrtxStaked() external view returns (uint256) {
        return globalState.vrtxStaked;
    }

    function _getScoreAtTime(
        State memory _state,
        uint64 currentTime
    ) internal pure returns (uint256) {
        uint256 baseScore = _state.vrtxStaked * BASE_SCORE_MULTIPLIER;
        uint256 boostScore = (uint256(
            (int256(int64(currentTime)) * _state.sumSize - _state.sumSizeXTime)
        ) * BOOST_SCORE_MULTIPLIER) / BOOST_LENGTH;
        return baseScore + boostScore;
    }

    function getScore(address account) external view returns (uint256) {
        uint64 currentTime = uint64(block.timestamp);
        return _getScoreAtTime(states[account], currentTime) / 2;
    }

    function getTotalScore() external view returns (uint256) {
        uint64 currentTime = uint64(block.timestamp);
        return _getScoreAtTime(globalState, currentTime) / 2;
    }

    function getLastActionTimes(
        address account
    ) external view returns (LastActionTimes memory) {
        return lastActionTimes[account];
    }

    function getWithdrawLockingTime() external view returns (uint64) {
        return withdrawLockingTime;
    }

    function updateConfig(uint64 _withdrawLockingTime) external onlyOwner {
        withdrawLockingTime = _withdrawLockingTime;
    }
}
