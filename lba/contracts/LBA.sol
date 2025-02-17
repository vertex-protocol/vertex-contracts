// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "./interfaces/ILBA.sol";
import "./interfaces/IEndpoint.sol";
import "./interfaces/ISanctionsList.sol";

library X18Math {
    uint256 private constant ONE_X18 = 1000000000000000000;

    function mul(uint256 x, uint256 y) internal pure returns (uint256) {
        return (x * y) / ONE_X18;
    }

    function div(uint256 x, uint256 y) internal pure returns (uint256) {
        return (x * ONE_X18) / y;
    }
}

contract LBA is ILBA, OwnableUpgradeable {
    using X18Math for uint256;

    uint32 constant QUOTE_PRODUCT_ID = 0;
    uint256 constant SLOW_MODE_FEE = 1_000_000_000_000_000_000; // $1
    bytes12 constant DEFAULT_SUBACCOUNT = bytes12(bytes("default"));
    uint64 constant SECONDS_PER_DAY = 3600 * 24;

    uint8 constant DECIMALS = 18;

    address vrtxToken;
    address usdcToken;
    address airdrop;
    address vertexEndpoint;
    address sanctions;

    uint32 vrtxProductId;

    Config config;
    State state;

    uint256 vrtxMultiplier;
    uint256 usdcMultiplier;
    bool depositedToVertex;

    mapping(address => bool) withdrawnUsdc;
    mapping(address => uint256) vrtxDeposited;
    mapping(address => uint256) usdcDeposited;
    mapping(address => uint256) lpWithdrawn;
    mapping(address => uint256) lastCumulativeRewardsPerShareX18;
    mapping(address => uint256) unclaimedRewards;
    mapping(address => uint256) claimedRewards;

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(
        address _vrtxToken,
        address _usdcToken,
        address _airdrop,
        address _vertexEndpoint,
        address _sanctions,
        uint64 _depositStartTime,
        uint64 _depositEndTime,
        uint64 _withdrawEndTime,
        uint64 _lpVestStartTime,
        uint64 _lpVestEndTime,
        uint32 _vrtxProductId
    ) external initializer {
        __Ownable_init();
        vrtxToken = _vrtxToken;
        usdcToken = _usdcToken;
        airdrop = _airdrop;
        vertexEndpoint = _vertexEndpoint;
        sanctions = _sanctions;

        vrtxProductId = _vrtxProductId;
        Config memory _config = Config(
            _depositStartTime,
            _depositEndTime,
            _withdrawEndTime,
            _lpVestStartTime,
            _lpVestEndTime
        );
        _verifyConfig(_config);
        config = _config;

        vrtxMultiplier = uint256(
            10 ** (DECIMALS - IERC20Metadata(vrtxToken).decimals())
        );
        usdcMultiplier = uint256(
            10 ** (DECIMALS - IERC20Metadata(usdcToken).decimals())
        );
    }

    function getStage() public view returns (Stage stage) {
        uint64 currentTime = uint64(block.timestamp);
        if (currentTime < config.depositStartTime) {
            stage = Stage.NotStarted;
        } else if (currentTime < config.depositEndTime) {
            stage = Stage.DepositingTokens;
        } else if (currentTime < config.withdrawEndTime) {
            stage = Stage.WithdrawingUsdc;
        } else if (currentTime < config.lpVestStartTime) {
            if (!depositedToVertex) {
                stage = Stage.LBAFinished;
            } else if (state.totalLpMinted == 0) {
                stage = Stage.DepositedToVertex;
            } else {
                stage = Stage.LpMinted;
            }
        } else if (currentTime < config.lpVestEndTime) {
            stage = Stage.LpVesting;
        } else {
            stage = Stage.LpVested;
        }
    }

    function depositVrtx(address account, uint256 amount) external {
        require(msg.sender == airdrop, "Unauthorized.");
        require(
            getStage() == Stage.DepositingTokens,
            "Not in depositing stage."
        );
        SafeERC20.safeTransferFrom(
            IERC20(vrtxToken),
            msg.sender,
            address(this),
            amount
        );
        vrtxDeposited[account] += amount;
        state.totalVrtxDeposited += amount;
    }

    function depositUsdc(uint256 amount) external {
        require(
            getStage() == Stage.DepositingTokens,
            "Not in depositing stage."
        );
        address sender = msg.sender;
        require(
            !ISanctionsList(sanctions).isSanctioned(sender),
            "address is sanctioned."
        );
        SafeERC20.safeTransferFrom(
            IERC20(usdcToken),
            sender,
            address(this),
            amount
        );
        usdcDeposited[sender] += amount;
        state.totalUsdcDeposited += amount;
    }

    function getDepositedVrtx(address account) external view returns (uint256) {
        return vrtxDeposited[account];
    }

    function getDepositedUsdc(address account) external view returns (uint256) {
        return usdcDeposited[account];
    }

    function _maxWithdrawableUsdc(
        address account,
        Stage stage
    ) internal view returns (uint256 maxWithdrawableUsdc) {
        if (stage == Stage.DepositingTokens) {
            maxWithdrawableUsdc = usdcDeposited[account];
        } else if (stage == Stage.WithdrawingUsdc) {
            if (!withdrawnUsdc[account]) {
                uint64 currentTime = uint64(block.timestamp);
                uint64 midTime = (config.depositEndTime +
                    config.withdrawEndTime) / 2;
                if (currentTime < midTime) {
                    maxWithdrawableUsdc = usdcDeposited[account] / 2;
                } else {
                    uint64 elpased = currentTime - midTime;
                    uint64 total = config.withdrawEndTime - midTime;
                    maxWithdrawableUsdc =
                        (usdcDeposited[account] * (total - elpased)) /
                        total /
                        2;
                }
            }
        }
    }

    function getMaxWithdrawableUsdc(
        address account
    ) external view returns (uint256) {
        return _maxWithdrawableUsdc(account, getStage());
    }

    function withdrawUsdc(uint256 amount) external {
        address sender = msg.sender;
        require(amount > 0, "Cannot withdraw zero amount.");
        require(
            !ISanctionsList(sanctions).isSanctioned(sender),
            "address is sanctioned."
        );
        Stage stage = getStage();
        require(
            amount <= _maxWithdrawableUsdc(sender, stage),
            "Trying to withdraw more USDC than max withdrawable amount."
        );
        usdcDeposited[sender] -= amount;
        state.totalUsdcDeposited -= amount;
        if (stage == Stage.WithdrawingUsdc) {
            withdrawnUsdc[sender] = true;
        }
        SafeERC20.safeTransfer(IERC20(usdcToken), sender, amount);
    }

    function getVrtxInitialPriceX18() public view returns (uint256 priceX18) {
        if (state.totalVrtxDeposited != 0) {
            priceX18 = (state.totalUsdcDeposited * usdcMultiplier).div(
                state.totalVrtxDeposited * vrtxMultiplier
            );
        }
    }

    function depositToVertex() external onlyOwner {
        require(getStage() == Stage.LBAFinished, "Not in LBAFinished stage.");
        depositedToVertex = true;

        // deposit all VRTX into vertex.
        SafeERC20.safeApprove(
            IERC20(vrtxToken),
            vertexEndpoint,
            uint128(state.totalVrtxDeposited)
        );
        IEndpoint(vertexEndpoint).depositCollateral(
            DEFAULT_SUBACCOUNT,
            vrtxProductId,
            uint128(state.totalVrtxDeposited)
        );

        // deposit all USDC into vertex.
        SafeERC20.safeApprove(
            IERC20(usdcToken),
            vertexEndpoint,
            state.totalUsdcDeposited
        );
        IEndpoint(vertexEndpoint).depositCollateral(
            DEFAULT_SUBACCOUNT,
            QUOTE_PRODUCT_ID,
            uint128(state.totalUsdcDeposited)
        );
    }

    function mintLpInVertex() external onlyOwner {
        require(
            getStage() == Stage.DepositedToVertex,
            "Not in DepositedToVertex stage."
        );

        uint256 vrtxInitialPriceX18 = getVrtxInitialPriceX18();
        require(
            IEndpoint(vertexEndpoint).getPriceX18(vrtxProductId) ==
                int128(int256(vrtxInitialPriceX18)),
            "VRTX price on vertex doesn't match with initial price."
        );

        uint256 amountBase = state.totalVrtxDeposited * vrtxMultiplier;
        uint256 amountQuote = amountBase.mul(vrtxInitialPriceX18);
        require(state.totalUsdcDeposited * usdcMultiplier >= amountQuote);
        state.totalLpMinted = amountBase + amountQuote;

        SafeERC20.safeTransferFrom(
            IERC20(usdcToken),
            msg.sender,
            address(this),
            SLOW_MODE_FEE / usdcMultiplier
        );

        SafeERC20.safeApprove(
            IERC20(usdcToken),
            vertexEndpoint,
            SLOW_MODE_FEE / usdcMultiplier
        );

        IEndpoint(vertexEndpoint).submitSlowModeTransaction(
            abi.encodePacked(
                uint8(IEndpoint.TransactionType.MintLp),
                abi.encode(
                    IEndpoint.MintLp({
                        sender: bytes32(
                            abi.encodePacked(address(this), DEFAULT_SUBACCOUNT)
                        ),
                        productId: vrtxProductId,
                        amountBase: uint128(amountBase),
                        quoteAmountLow: uint128(amountQuote),
                        quoteAmountHigh: uint128(amountQuote),
                        nonce: 0
                    })
                )
            )
        );
    }

    function _initialLpBalance(
        address account
    ) internal view returns (uint256 initialLpBalance) {
        uint256 vrtxInitialPriceX18 = getVrtxInitialPriceX18();
        uint256 accountValue = usdcDeposited[account] *
            usdcMultiplier +
            (vrtxDeposited[account] * vrtxMultiplier).mul(vrtxInitialPriceX18);
        uint256 totalValue = state.totalUsdcDeposited *
            usdcMultiplier +
            (state.totalVrtxDeposited * vrtxMultiplier).mul(
                vrtxInitialPriceX18
            );
        if (totalValue != 0) {
            initialLpBalance =
                (accountValue * state.totalLpMinted) /
                totalValue;
        }
    }

    function getLpBalance(address account) public view returns (uint256) {
        return _initialLpBalance(account) - lpWithdrawn[account];
    }

    function getLockedLpBalance(
        address account
    ) public view returns (uint256 lockedLpBalance) {
        Stage stage = getStage();
        if (stage < Stage.LpVesting) {
            lockedLpBalance = _initialLpBalance(account);
        } else if (stage == Stage.LpVesting) {
            uint64 elpased = uint64(block.timestamp) - config.lpVestStartTime;
            uint64 total = config.lpVestEndTime - config.lpVestStartTime;
            uint64 elpasedInDay = elpased / SECONDS_PER_DAY;
            uint64 totalInDay = total / SECONDS_PER_DAY;

            // LPs are unlocked by day instead of seconds, because unlocking LP
            // requires submitting slow mode tx to vertex, which isn't charged for
            // SLOW_MODE_FEE for UX consideration. we want to reduce the amount of
            // LP unlocking transactions to save gas.
            lockedLpBalance =
                (_initialLpBalance(account) * (totalInDay - elpasedInDay) * 2) /
                (totalInDay * 3);
        }
    }

    function getWithdrawableLpBalance(
        address account
    ) public view returns (uint256) {
        return getLpBalance(account) - getLockedLpBalance(account);
    }

    function withdrawLiquidity(uint256 lpAmount) external {
        require(lpAmount > 0, "Can't withdraw zero liquidity.");
        address sender = msg.sender;
        require(
            !ISanctionsList(sanctions).isSanctioned(sender),
            "address is sanctioned."
        );
        require(
            getWithdrawableLpBalance(sender) >= lpAmount,
            "Withdrawing more LPs than max withdrawable amount."
        );
        _updateRewards(sender);
        lpWithdrawn[sender] += lpAmount;
        state.totalLpWithdrawn += lpAmount;

        IEndpoint(vertexEndpoint).submitSlowModeTransaction(
            abi.encodePacked(
                uint8(IEndpoint.TransactionType.BurnLpAndTransfer),
                abi.encode(
                    IEndpoint.BurnLpAndTransfer({
                        sender: bytes32(
                            abi.encodePacked(address(this), DEFAULT_SUBACCOUNT)
                        ),
                        productId: vrtxProductId,
                        amount: uint128(lpAmount),
                        recipient: bytes32(
                            abi.encodePacked(sender, DEFAULT_SUBACCOUNT)
                        )
                    })
                )
            )
        );
    }

    function getConfig() external view returns (Config memory) {
        return config;
    }

    function getState() external view returns (State memory) {
        return state;
    }

    function _updateRewards(address account) internal {
        uint256 diff = state.cumulativeRewardsPerShareX18 -
            lastCumulativeRewardsPerShareX18[account];
        if (diff > 0) {
            unclaimedRewards[account] += getLpBalance(account).mul(diff);
            lastCumulativeRewardsPerShareX18[account] = state
                .cumulativeRewardsPerShareX18;
        }
    }

    function getClaimedRewards(
        address account
    ) external view returns (uint256) {
        return claimedRewards[account];
    }

    function getClaimableRewards(
        address account
    ) external view returns (uint256 claimableRewards) {
        claimableRewards = unclaimedRewards[account];
        uint256 diff = state.cumulativeRewardsPerShareX18 -
            lastCumulativeRewardsPerShareX18[account];
        if (diff > 0) {
            claimableRewards += getLpBalance(account).mul(diff);
        }
    }

    function distributeRewards(uint256 amount) external {
        require(msg.sender == airdrop, "Unauthorized.");
        SafeERC20.safeTransferFrom(
            IERC20(vrtxToken),
            msg.sender,
            address(this),
            amount
        );
        uint256 totalLp = state.totalLpMinted - state.totalLpWithdrawn;
        state.cumulativeRewardsPerShareX18 += amount.div(totalLp);
    }

    function claimRewards() external {
        address sender = msg.sender;
        require(
            !ISanctionsList(sanctions).isSanctioned(sender),
            "address is sanctioned."
        );
        _updateRewards(sender);
        claimedRewards[sender] += unclaimedRewards[sender];
        SafeERC20.safeTransfer(
            IERC20(vrtxToken),
            sender,
            unclaimedRewards[sender]
        );
        unclaimedRewards[sender] = 0;
    }

    function _verifyConfig(Config memory _config) internal pure {
        require(
            _config.depositStartTime < _config.depositEndTime,
            "Invalid config: depositStartTime >= depositEndTime."
        );
        require(
            _config.depositEndTime < _config.withdrawEndTime,
            "Invalid config: depositEndTime >= withdrawEndTime"
        );
        require(
            _config.withdrawEndTime < _config.lpVestStartTime,
            "Invalid config: withdrawEndTime >= lpVestStartTime"
        );
        require(
            _config.lpVestStartTime < _config.lpVestEndTime,
            "Invalid config: lpVestStartTime >= lpVestEndTime"
        );
    }
}
