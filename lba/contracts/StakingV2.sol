// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

import "./interfaces/IStakingV2.sol";
import "./interfaces/IStaking.sol";
import "./interfaces/ISanctionsList.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";

contract StakingV2 is IStakingV2, OwnableUpgradeable {
    uint32 constant INF = type(uint32).max;
    uint128 constant ONE = 10 ** 18;

    address vrtxToken;
    address sanctions;
    address stakingV1;

    Config defaultConfig;
    uint128 totalVrtx;
    uint128 totalLiquid;
    uint128 migrationBonusPool;

    GlobalYieldsBreakdown[] globalYieldsBreakdown;

    mapping(address => LastActionTimes) lastActionTimes;
    mapping(address => uint128) liquidShares;
    mapping(address => ReleaseSchedule) releaseSchedules;
    mapping(address => Config) configs;
    mapping(address => State) states;
    mapping(address => address) tradingWallet;

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    modifier onlyV1() {
        require(msg.sender == stakingV1, "Not V1");
        _;
    }

    function initialize(
        address _vrtxToken,
        address _sanctions,
        address _stakingV1,
        uint32 _withdrawLockingTime
    ) external initializer {
        __Ownable_init();
        vrtxToken = _vrtxToken;
        sanctions = _sanctions;
        stakingV1 = _stakingV1;
        defaultConfig = Config(_withdrawLockingTime, 0, ONE / 10, 0);
    }

    function _stake(address staker, uint128 amount) internal {
        uint128 liquid;
        if (totalVrtx > 0) {
            liquid = uint128((uint256(totalLiquid) * amount) / totalVrtx);
            totalLiquid += liquid;
            totalVrtx += amount;
            liquidShares[staker] += liquid;
        } else {
            require(amount > ONE, "First stake at least 1 VRTX");
            liquid = amount;
            totalLiquid = amount;
            totalVrtx = amount;
            liquidShares[staker] = amount;
        }
        states[staker].cumulativeStakedAmount += amount;
        states[staker].currentStakedAmount += amount;
        uint64 currentTime = uint64(block.timestamp);
        lastActionTimes[staker].lastStakeTime = currentTime;

        emit ModifyStake(staker, int128(amount), int128(liquid));
    }

    // stake as `staker`, but VRTX is transferred from `msg.sender`.
    function stakeAs(address staker, uint128 amount) public {
        require(amount > 0, "Trying to stake 0 tokens.");
        require(
            !ISanctionsList(sanctions).isSanctioned(staker),
            "address is sanctioned."
        );
        SafeERC20.safeTransferFrom(
            IERC20(vrtxToken),
            msg.sender,
            address(this),
            amount
        );
        uint64 currentTime = uint64(block.timestamp);
        uint64 v2BonusDeadline = IStaking(stakingV1).getV2BonusDeadline();
        if (v2BonusDeadline > 0 && currentTime <= v2BonusDeadline) {
            uint128 bonus = amount / 40;
            require(migrationBonusPool >= bonus, "insufficient bonus pool");
            migrationBonusPool -= bonus;
            amount += bonus;
        }
        _stake(staker, amount);
    }

    function stake(uint128 amount) external {
        stakeAs(msg.sender, amount);
    }

    function migrationBonusDeposit(uint128 amount) external onlyOwner {
        require(amount > 0, "Trying to deposit 0 tokens.");
        SafeERC20.safeTransferFrom(
            IERC20(vrtxToken),
            msg.sender,
            address(this),
            amount
        );
        migrationBonusPool += amount;
    }

    function migrationBonusWithdraw() external onlyOwner {
        require(migrationBonusPool > 0, "Trying to withdraw 0 tokens.");
        SafeERC20.safeTransfer(
            IERC20(vrtxToken),
            msg.sender,
            migrationBonusPool
        );
        migrationBonusPool = 0;
    }

    function migrate(
        address staker,
        uint128 amount,
        uint128 bonus
    ) external onlyV1 {
        require(amount > 0, "Trying to migrate 0 tokens.");
        require(
            40 * bonus <= amount * 3,
            "bonus/amount should less or equal to 7.5%"
        );
        require(bonus <= migrationBonusPool, "insufficient bonus pool");
        require(
            !ISanctionsList(sanctions).isSanctioned(staker),
            "address is sanctioned."
        );
        SafeERC20.safeTransferFrom(
            IERC20(vrtxToken),
            stakingV1,
            address(this),
            amount
        );
        migrationBonusPool -= bonus;
        _stake(staker, amount + bonus);
    }

    function _getVrtxBalance(address account) internal view returns (uint128) {
        if (totalLiquid == 0) return 0;
        return
            uint128((uint256(liquidShares[account]) * totalVrtx) / totalLiquid);
    }

    function _withdraw(address account) internal returns (uint128 amount) {
        amount = _getVrtxBalance(account);
        require(amount > 0, "Trying to withdraw 0 staked tokens");
        require(
            !ISanctionsList(sanctions).isSanctioned(account),
            "address is sanctioned."
        );
        uint64 currentTime = uint64(block.timestamp);
        uint64 withdrawableTime = _getWithdrawableTime(account);
        require(currentTime >= withdrawableTime, "not yet time to withdraw");

        uint128 liquid = liquidShares[account];
        totalVrtx -= amount;
        totalLiquid -= liquid;
        delete liquidShares[account];
        states[account].cumulativeWithdrawnAmount += amount;
        states[account].currentStakedAmount = 0;

        lastActionTimes[account].lastWithdrawTime = currentTime;
        emit ModifyStake(account, -int128(amount), -int128(liquid));
    }

    function withdraw() external {
        address sender = msg.sender;
        uint128 amount = _withdraw(sender);

        Config memory config = _getConfig(sender);
        uint128 toDistributeAmount = uint128(
            (uint256(amount) * config.toDistributeRatio) / ONE
        );
        uint128 toTreasuryAmount = uint128(
            (uint256(amount) * config.toTreasuryRatio) / ONE
        );
        uint128 burnAmount = toDistributeAmount + toTreasuryAmount;
        require(burnAmount < amount, "No VRTX after burning");
        uint128 withdrawAmount = amount - burnAmount;

        if (totalLiquid > ONE) {
            totalVrtx += toDistributeAmount;
        } else {
            toTreasuryAmount += toDistributeAmount;
        }
        states[sender].cumulativeBurnedAmount += burnAmount;
        if (toTreasuryAmount > 0) {
            SafeERC20.safeTransfer(
                IERC20(vrtxToken),
                owner(),
                uint256(toTreasuryAmount)
            );
        }

        SafeERC20.safeTransfer(
            IERC20(vrtxToken),
            sender,
            uint256(withdrawAmount)
        );
    }

    function withdrawSlow() external {
        address sender = msg.sender;
        uint128 amount = _withdraw(sender);

        require(
            releaseSchedules[sender].amount == 0,
            "Having Scheduled VRTX Withdraw"
        );
        uint64 currentTime = uint64(block.timestamp);
        Config memory config = _getConfig(sender);
        releaseSchedules[sender] = ReleaseSchedule({
            releaseTime: currentTime + config.withdrawLockingTime,
            amount: amount
        });
    }

    function claimWithdraw() external {
        address sender = msg.sender;
        require(
            !ISanctionsList(sanctions).isSanctioned(sender),
            "address is sanctioned."
        );
        ReleaseSchedule memory schedule = releaseSchedules[sender];
        require(schedule.amount > 0, "No Withdraw scheduled.");
        uint64 currentTime = uint64(block.timestamp);
        require(
            currentTime >= schedule.releaseTime,
            "Scheduled Time Not Arrived"
        );
        uint128 amount = schedule.amount;
        delete releaseSchedules[sender];
        SafeERC20.safeTransfer(IERC20(vrtxToken), sender, uint256(amount));
    }

    function distributeRewards(
        uint128 baseAmount,
        uint128 feesAmount,
        uint128 usdcAmount
    ) external onlyOwner {
        uint128 amount = baseAmount + feesAmount;
        require(amount > 0, "must distribute non-zero rewards.");
        require(totalVrtx > ONE, "cannot distribute if no VRTX staked");
        address sender = msg.sender;
        SafeERC20.safeTransferFrom(
            IERC20(vrtxToken),
            sender,
            address(this),
            uint256(amount)
        );
        globalYieldsBreakdown.push(
            GlobalYieldsBreakdown({
                distributionTime: uint64(block.timestamp),
                baseYieldAmount: baseAmount,
                feesYieldAmount: feesAmount,
                totalVrtxBalance: totalVrtx,
                usdcAmount: usdcAmount
            })
        );
        totalVrtx += amount;
    }

    function connectTradingWallet(address wallet) external {
        tradingWallet[msg.sender] = wallet;
        emit ConnectTradingWallet(msg.sender, wallet);
    }

    function getTradingWallet(address account) public view returns (address) {
        address wallet = tradingWallet[account];
        if (wallet == address(0)) {
            wallet = account;
        }
        return wallet;
    }

    function getReleaseSchedule(
        address account
    ) external view returns (ReleaseSchedule memory releaseSchedule) {
        releaseSchedule = releaseSchedules[account];
    }

    function getVrtxBalance(address account) external view returns (uint128) {
        return _getVrtxBalance(account);
    }

    function getTotalVrtxBalance() external view returns (uint128) {
        return totalVrtx;
    }

    function getLastActionTimes(
        address account
    ) external view returns (LastActionTimes memory) {
        return lastActionTimes[account];
    }

    function getTotalLiquid() external view returns (uint128) {
        return totalLiquid;
    }

    function _getConfig(address account) internal view returns (Config memory) {
        Config memory config = configs[account];
        if (config.withdrawLockingTime == 0)
            config.withdrawLockingTime = defaultConfig.withdrawLockingTime;
        if (config.minimumStakingPeriod == 0)
            config.minimumStakingPeriod = defaultConfig.minimumStakingPeriod;
        if (config.toDistributeRatio == 0)
            config.toDistributeRatio = defaultConfig.toDistributeRatio;
        if (config.toTreasuryRatio == 0)
            config.toTreasuryRatio = defaultConfig.toTreasuryRatio;
        return config;
    }

    function getConfig(address account) external view returns (Config memory) {
        return _getConfig(account);
    }

    function getDefaultConfig() external view returns (Config memory) {
        return defaultConfig;
    }

    function getState(address account) external view returns (State memory) {
        return states[account];
    }

    function _getWithdrawableTime(
        address account
    ) internal view returns (uint64) {
        return
            _getConfig(account).minimumStakingPeriod +
            lastActionTimes[account].lastStakeTime;
    }

    function getWithdrawableTime(
        address account
    ) external view returns (uint64) {
        return _getWithdrawableTime(account);
    }

    function getMigrationBonusPool() external view returns (uint128) {
        return migrationBonusPool;
    }

    function updateConfig(
        address account,
        Config memory config
    ) external onlyOwner {
        configs[account] = config;
    }

    function updateDefaultConfig(Config memory config) external onlyOwner {
        defaultConfig = config;
    }

    function getGlobalYieldsBreakdown()
        external
        view
        returns (GlobalYieldsBreakdown[] memory)
    {
        return globalYieldsBreakdown;
    }
}
