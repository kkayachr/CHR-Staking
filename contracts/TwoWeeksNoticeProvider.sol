/**
 *Submitted for verification at BscScan.com on 2021-08-20
 */

// SPDX-License-Identifier: MIT

pragma solidity ^0.8.17;

import '@openzeppelin/contracts/token/ERC20/IERC20.sol';

contract TwoWeeksNoticeProvider {
    struct StakeChange {
        uint128 timePoint;
        uint128 balance;
    }

    struct StakeState {
        uint64 balance;
        uint64 delegationRewards;
        uint128 processed;
        uint128 rewardFraction; // E.g. If this number is 10, the provider will get 1/10 of the user reward
        uint64 unlockPeriod; // time it takes from requesting withdraw to being able to withdraw
        uint64 lockedUntil; // 0 if withdraw is not requested
        uint64 since;
        uint128 accumulated; // token-days staked
        uint128 accumulatedStrict; // token-days staked sans withdraw periods
        StakeChange[] stakeTimeline;
    }

    event StakeUpdate(address indexed from, uint64 balance);
    event WithdrawRequest(address indexed from, uint64 until);

    mapping(address => StakeState) internal _states;
    mapping(address => bool) internal providerWhitelisted;

    uint64 public rewardPerDayPerTokenProvider;
    IERC20 internal token;
    address public owner;

    constructor(IERC20 _token, address _owner, uint64 _rewardPerDayPerTokenProvider) {
        token = _token;
        owner = _owner;
        rewardPerDayPerTokenProvider = _rewardPerDayPerTokenProvider;
    }

    function setProviderRewardRate(uint64 rewardRate) external {
        require(msg.sender == owner);
        rewardPerDayPerTokenProvider = rewardRate;
    }

    function getStakeState(address account) external view returns (uint64, uint64, uint64, uint64, uint64, uint128) {
        StakeState storage ss = _states[account];
        return (ss.balance, ss.delegationRewards, ss.unlockPeriod, ss.lockedUntil, ss.since, ss.processed);
    }

    function getAccumulated(address account) external view returns (uint128, uint128) {
        StakeState storage ss = _states[account];
        return (ss.accumulated, ss.accumulatedStrict);
    }

    function estimateAccumulated(address account) public view returns (uint128, uint128) {
        StakeState storage ss = _states[account];
        uint128 sum = ss.accumulated;
        uint128 sumStrict = ss.accumulatedStrict;
        if (ss.balance > 0) {
            uint256 until = block.timestamp;
            if (ss.lockedUntil > 0 && ss.lockedUntil < block.timestamp) {
                until = ss.lockedUntil;
            }
            if (until > ss.since) {
                uint128 delta = uint128((uint256(ss.balance) * (until - ss.since)) / 86400);
                sum += delta;
                if (ss.lockedUntil == 0) {
                    sumStrict += delta;
                }
            }
        }
        return (sum, sumStrict);
    }

    function updateAccumulated(StakeState storage ss) private {
        if (ss.balance > 0) {
            uint256 until = block.timestamp;
            if (ss.lockedUntil > 0 && ss.lockedUntil < block.timestamp) {
                until = ss.lockedUntil;
            }
            if (until > ss.since) {
                uint128 delta = uint128((uint256(ss.balance) * (until - ss.since)) / 86400);
                ss.accumulated += delta;
                if (ss.lockedUntil == 0) {
                    ss.accumulatedStrict += delta;
                }
            }
        }
    }

    function stake(uint64 amount, uint64 unlockPeriod) external {
        StakeState storage ss = _states[msg.sender];
        require(amount > 0, 'amount must be positive');
        require(ss.balance <= amount, 'cannot decrease balance');
        require(unlockPeriod <= 1000 days, 'unlockPeriod cannot be higher than 1000 days');
        require(ss.unlockPeriod <= unlockPeriod, 'cannot decrease unlock period');
        require(unlockPeriod >= 2 weeks, "unlock period can't be less than 2 weeks");

        updateAccumulated(ss);

        uint128 delta = amount - ss.balance;
        if (delta > 0) {
            require(token.transferFrom(msg.sender, address(this), delta), 'transfer unsuccessful');
        }

        ss.balance = amount;
        ss.unlockPeriod = unlockPeriod;
        ss.lockedUntil = 0;
        ss.since = uint64(block.timestamp);
        ss.stakeTimeline.push(StakeChange(uint128(block.timestamp), amount));
        emit StakeUpdate(msg.sender, amount);
    }

    function requestWithdraw() external {
        StakeState storage ss = _states[msg.sender];
        require(ss.balance > 0);
        updateAccumulated(ss);
        ss.since = uint64(block.timestamp);
        ss.lockedUntil = uint64(block.timestamp + ss.unlockPeriod);
    }

    function withdraw(address to) external {
        StakeState storage ss = _states[msg.sender];
        require(ss.balance > 0, 'must have tokens to withdraw');
        // require(ss.lockedUntil != 0, 'unlock not requested');
        // require(ss.lockedUntil < block.timestamp, 'still locked');
        updateAccumulated(ss);
        uint128 balance = ss.balance;
        ss.balance = 0;
        ss.unlockPeriod = 0;
        ss.lockedUntil = 0;
        ss.since = 0;
        ss.stakeTimeline.push(StakeChange(uint128(block.timestamp), 0));
        require(token.transfer(to, balance), 'transfer unsuccessful');
        emit StakeUpdate(msg.sender, 0);
    }

    function addDelegationReward(uint64 amount, address provider) internal {
        StakeState storage ss = _states[provider];
        require(amount > 0, 'amount must be positive');

        ss.delegationRewards += amount;
    }

    function claimDelegationReward() public {
        uint128 reward = _states[msg.sender].delegationRewards;
        require(reward > 0, 'reward is 0');
        _states[msg.sender].delegationRewards = 0;
        token.transfer(msg.sender, reward);
    }

    function estimateProviderYield(address account) public view returns (uint128 reward) {
        uint128 prevPaid = _states[msg.sender].processed;
        (uint128 acc, ) = estimateAccumulated(account);
        if (acc > prevPaid) {
            uint128 delta = acc - prevPaid;
            reward = (1 * delta) / 1000000; // TODO: ADD A RATIO
        }
    }

    function claimProviderYield() public {
        uint128 reward = estimateProviderYield(msg.sender);
        require(reward > 0, 'reward is 0');
        (uint128 acc, ) = estimateAccumulated(msg.sender);
        _states[msg.sender].processed = acc;
        token.transfer(msg.sender, reward);
    }

    function claimAllProviderRewards() public {
        uint128 reward = _states[msg.sender].delegationRewards;
        reward += estimateProviderYield(msg.sender);
        require(reward > 0, 'reward is 0');
        (uint128 acc, ) = estimateAccumulated(msg.sender);
        _states[msg.sender].processed = acc;
        _states[msg.sender].delegationRewards = 0;
        token.transfer(msg.sender, reward);
    }
}
