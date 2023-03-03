/**
 *Submitted for verification at BscScan.com on 2021-08-20
 */

// SPDX-License-Identifier: MIT

pragma solidity ^0.8.17;

import '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import 'hardhat/console.sol';

// TODO: change name of this struct
struct StakeChange {
    uint128 balance;
    uint128 extraReward;
    uint128 totalDelegations;
    uint128 delegationsIncrease;
    uint128 delegationsDecrease;
    bool totalDelegationsSet;
    bool balanceChanged;
}

contract TwoWeeksNoticeProvider {
    struct StakeState {
        uint128 accumulated; // token-days staked
        uint128 accumulatedStrict; // token-days staked sans withdraw periods
        uint128 processed;
        uint64 unlockPeriod; // time it takes from requesting withdraw to being able to withdraw
        uint64 lockedUntil; // 0 if withdraw is not requested
        uint64 since;
        uint64 balance;
        uint32 claimedEpochReward;
        mapping(uint32 => StakeChange) stakeTimeline; // TODO: change name
    }

    event StakeUpdate(address indexed from, uint64 balance);
    event WithdrawRequest(address indexed from, uint64 until);

    mapping(address => StakeState) internal _states;
    mapping(address => bool) internal providerWhitelisted;

    uint64 public rewardPerDayPerTokenProvider;
    IERC20 internal token;
    address public owner;
    uint internal startTime = block.timestamp;
    uint public epochLength = 1 weeks;

    constructor(IERC20 _token, address _owner, uint64 _rewardPerDayPerTokenProvider) {
        token = _token;
        owner = _owner;
        rewardPerDayPerTokenProvider = _rewardPerDayPerTokenProvider;
    }

    function setProviderRewardRate(uint64 rewardRate) external {
        require(msg.sender == owner);
        rewardPerDayPerTokenProvider = rewardRate;
    }

    function getStakeState(address account) external view returns (uint64, uint64, uint64, uint64, uint128) {
        StakeState storage ss = _states[account];
        return (ss.balance, ss.unlockPeriod, ss.lockedUntil, ss.since, ss.processed);
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
        StakeChange memory nextStakeChange = ss.stakeTimeline[getCurrentEpoch() + 1];
        nextStakeChange.balanceChanged = true;
        nextStakeChange.balance = amount;
        emit StakeUpdate(msg.sender, amount);
    }

    function requestWithdrawProvider() external {
        StakeState storage ss = _states[msg.sender];
        require(ss.balance > 0);
        updateAccumulated(ss);
        ss.since = uint64(block.timestamp);
        ss.lockedUntil = uint64(block.timestamp + ss.unlockPeriod);
    }

    function withdrawProvider(address to) external {
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

        StakeChange storage nextStakeChange = ss.stakeTimeline[getCurrentEpoch() + 1];
        nextStakeChange.balanceChanged = true;
        nextStakeChange.balance = 0;
        require(token.transfer(to, balance), 'transfer unsuccessful');
        emit StakeUpdate(msg.sender, 0);
    }

    function calculateTotalDelegation(uint32 epoch, address account) public view returns (uint128 latestTotalDelegations) {
        StakeChange memory stakeChange;
        uint32 latestTotalDelegationsEpoch;
        for (uint32 i = epoch; i >= 0; i--) {
            stakeChange = _states[account].stakeTimeline[i];
            if (stakeChange.totalDelegationsSet) {
                latestTotalDelegations = stakeChange.totalDelegations;
                latestTotalDelegationsEpoch = i;
                break;
            }
            if (i == 0) break;
        }
        for (uint32 i = latestTotalDelegationsEpoch + 1; i <= epoch; i++) {
            stakeChange = _states[account].stakeTimeline[i];
            latestTotalDelegations = latestTotalDelegations + stakeChange.delegationsIncrease - stakeChange.delegationsDecrease;
        }
        return latestTotalDelegations;
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

    function estimateProviderDelegationReward() public returns (uint128 reward) {
        StakeState storage providerState = _states[msg.sender];
        uint32 claimedEpochReward = providerState.claimedEpochReward;
        uint32 currentEpoch = getCurrentEpoch();

        uint128 totalDelegations;
        uint128 prevTotalDelegations;
        if (currentEpoch - 1 > claimedEpochReward) {
            for (uint32 i = claimedEpochReward + 1; i < currentEpoch; i++) {
                totalDelegations = calculateTotalDelegation(i, msg.sender);
                if (totalDelegations != prevTotalDelegations) {
                    providerState.stakeTimeline[i].totalDelegations = totalDelegations;
                    providerState.stakeTimeline[i].totalDelegationsSet = true;
                }
                reward += uint128(1 * totalDelegations * epochLength); // TODO: Set a correct percentage - what will provider earn on total that is delegated to them
            }

            if (reward == 0) return 0;
            reward /= 1000000 * 86400;
        }
    }

    function claimProviderDelegationReward() public {
        uint128 reward = estimateProviderDelegationReward();
        require(reward > 0, 'reward is 0');
        _states[msg.sender].claimedEpochReward = getCurrentEpoch() - 1;
        token.transfer(msg.sender, reward);
    }

    function claimAllProviderRewards() public {
        uint128 reward = estimateProviderDelegationReward();
        reward += estimateProviderYield(msg.sender);
        require(reward > 0, 'reward is 0');
        (uint128 acc, ) = estimateAccumulated(msg.sender);
        _states[msg.sender].processed = acc;
        _states[msg.sender].claimedEpochReward = getCurrentEpoch() - 1;
        token.transfer(msg.sender, reward);
    }

    function getCurrentEpoch() public view returns (uint32) {
        return getEpoch(block.timestamp);
    }

    function getEpoch(uint time) public view returns (uint32) {
        require(time > startTime, 'Time must be larger than starttime');
        return uint32((time - startTime) / epochLength);
    }

    function getEpochTime(uint32 epoch) public view returns (uint128) {
        return uint32(startTime + epoch * epochLength);
    }
}
