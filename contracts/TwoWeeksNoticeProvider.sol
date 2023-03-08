/**
 *Submitted for verification at BscScan.com on 2021-08-20
 */

// SPDX-License-Identifier: MIT

pragma solidity ^0.8.17;

import '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import 'hardhat/console.sol';

struct ProviderBalanceChange {
    uint128 balance;
    uint32 epoch;
}

struct TotalDelegationChanges {
    uint128 totalDelegations;
    uint128 delegationsIncrease;
    uint128 delegationsDecrease;
    uint32 epoch;
    bool totalDelegationsSet;
}

struct AdditionalReward {
    uint128 additionalReward;
    uint32 epoch;
}

contract TwoWeeksNoticeProvider {
    struct ProviderState {
        uint128 accumulated; // token-days staked
        uint128 accumulatedStrict; // token-days staked sans withdraw periods
        uint128 processed;
        uint64 unlockPeriod; // time it takes from requesting withdraw to being able to withdraw
        uint64 lockedUntil; // 0 if withdraw is not requested
        uint64 since;
        uint64 balance;
        uint32 claimedEpochReward;
        bool whitelisted;
        ProviderBalanceChange[] balanceTimeline;
        TotalDelegationChanges[] totalDelegationsTimeline;
        AdditionalReward[] additionalRewardTimeline;
    }

    event StakeUpdate(address indexed from, uint64 balance);
    event WithdrawRequest(address indexed from, uint64 until);

    mapping(address => ProviderState) internal providerStates;

    uint64 public rewardPerDayPerTokenProvider;
    uint64 public rewardPerDayPerTotalDelegation;
    address public owner;
    uint internal startTime = block.timestamp;
    uint public epochLength = 1 weeks;
    IERC20 internal token;

    constructor(IERC20 _token, address _owner, uint64 _rewardPerDayPerTokenProvider, uint64 _rewardPerDayPerTotalDelegation) {
        token = _token;
        owner = _owner;
        rewardPerDayPerTokenProvider = _rewardPerDayPerTokenProvider;
        rewardPerDayPerTotalDelegation = _rewardPerDayPerTotalDelegation;
    }

    function setProviderRewardRate(uint64 rewardRate) external {
        require(msg.sender == owner);
        rewardPerDayPerTokenProvider = rewardRate;
    }

    function getProviderStakeState(address account) external view returns (uint64, uint64, uint64, uint64, uint128) {
        ProviderState storage ss = providerStates[account];
        return (ss.balance, ss.unlockPeriod, ss.lockedUntil, ss.since, ss.processed);
    }

    function getAccumulated(address account) external view returns (uint128, uint128) {
        ProviderState storage ss = providerStates[account];
        return (ss.accumulated, ss.accumulatedStrict);
    }

    function estimateAccumulated(address account) public view returns (uint128, uint128) {
        ProviderState storage ss = providerStates[account];
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

    function updateAccumulated(ProviderState storage ss) private {
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

    function stakeProvider(uint64 amount, uint64 unlockPeriod) external {
        ProviderState storage providerState = providerStates[msg.sender];

        require(providerState.whitelisted, 'not whitelisted');
        require(amount > 0, 'amount must be positive');
        require(providerState.balance <= amount, 'cannot decrease balance');
        require(unlockPeriod <= 1000 days, 'unlockPeriod cannot be higher than 1000 days');
        require(providerState.unlockPeriod <= unlockPeriod, 'cannot decrease unlock period');
        require(unlockPeriod >= 2 weeks, "unlock period can't be less than 2 weeks");

        updateAccumulated(providerState);

        uint128 delta = amount - providerState.balance;
        if (delta > 0) {
            require(token.transferFrom(msg.sender, address(this), delta), 'transfer unsuccessful');
        }

        providerState.balance = amount;
        providerState.unlockPeriod = unlockPeriod;
        providerState.lockedUntil = 0;
        providerState.since = uint64(block.timestamp);

        providerState.balanceTimeline.push(ProviderStateChange(amount, getCurrentEpoch() + 1));
        emit StakeUpdate(msg.sender, amount);
    }

    function requestWithdrawProvider() external {
        ProviderState storage ss = providerStates[msg.sender];
        require(ss.balance > 0);
        updateAccumulated(ss);
        ss.since = uint64(block.timestamp);
        ss.lockedUntil = uint64(block.timestamp + ss.unlockPeriod);
    }

    function withdrawProvider(address to) external {
        ProviderState storage ss = providerStates[msg.sender];
        require(ss.balance > 0, 'must have tokens to withdraw');
        // require(ss.lockedUntil != 0, 'unlock not requested');
        // require(ss.lockedUntil < block.timestamp, 'still locked');
        updateAccumulated(ss);
        uint128 balance = ss.balance;
        ss.balance = 0;
        ss.unlockPeriod = 0;
        ss.lockedUntil = 0;
        ss.since = 0;

        providerState.balanceTimeline.push(ProviderStateChange(0, getCurrentEpoch() + 1));
        require(token.transfer(to, balance), 'transfer unsuccessful');
        emit StakeUpdate(msg.sender, 0);
    }

    function calculateTotalDelegation(uint32 epoch, address account) public view returns (uint128 latestTotalDelegations) {
        ProviderStateChange memory stakeChange;
        uint32 latestTotalDelegationsEpoch;
        for (uint32 i = epoch; i >= 0; i--) {
            stakeChange = providerStates[account].providerStateTimeline[i];
            if (stakeChange.totalDelegationsSet) {
                latestTotalDelegations = stakeChange.totalDelegations;
                latestTotalDelegationsEpoch = i;
                break;
            }
            if (i == 0) break;
        }
        for (uint32 i = latestTotalDelegationsEpoch + 1; i <= epoch; i++) {
            stakeChange = providerStates[account].providerStateTimeline[i];
            latestTotalDelegations = latestTotalDelegations + stakeChange.delegationsIncrease - stakeChange.delegationsDecrease;
        }
        return latestTotalDelegations;
    }

    function estimateProviderYield(address account) public view returns (uint128 reward) {
        uint128 prevPaid = providerStates[msg.sender].processed;
        (uint128 acc, ) = estimateAccumulated(account);
        if (acc > prevPaid) {
            uint128 delta = acc - prevPaid;
            reward = (rewardPerDayPerTokenProvider * delta) / 1000000;
        }
    }

    function claimProviderYield() public {
        uint128 reward = estimateProviderYield(msg.sender);
        require(reward > 0, 'reward is 0');
        (uint128 acc, ) = estimateAccumulated(msg.sender);
        providerStates[msg.sender].processed = acc;
        token.transfer(msg.sender, reward);
    }

    function estimateProviderDelegationReward() public returns (uint128 reward) {
        ProviderState storage providerState = providerStates[msg.sender];
        uint32 claimedEpochReward = providerState.claimedEpochReward;
        uint32 currentEpoch = getCurrentEpoch();

        uint128 totalDelegations;
        uint128 prevTotalDelegations;
        uint128 additionalRewards;
        if (currentEpoch - 1 > claimedEpochReward) {
            for (uint32 i = claimedEpochReward + 1; i < currentEpoch; i++) {
                ProviderStateChange storage psc = providerState.providerStateTimeline[i];

                // if provider is unstaked or removed from whitelist, they should get no reward for the week
                totalDelegations = (psc.balanceChanged && psc.balance == 0) ? 0 : calculateTotalDelegation(i, msg.sender);

                if (totalDelegations != prevTotalDelegations) {
                    psc.totalDelegations = totalDelegations;
                    psc.totalDelegationsSet = true;
                }
                reward += uint128(rewardPerDayPerTotalDelegation * totalDelegations * epochLength);
                additionalRewards += psc.additionalReward;
            }
            reward = reward / (1000000 * 86400) + additionalRewards;
        }
    }

    function claimProviderDelegationReward() public {
        uint128 reward = estimateProviderDelegationReward();
        require(reward > 0, 'reward is 0');
        providerStates[msg.sender].claimedEpochReward = getCurrentEpoch() - 1;
        token.transfer(msg.sender, reward);
    }

    function claimAllProviderRewards() public {
        uint128 reward = estimateProviderDelegationReward();
        reward += estimateProviderYield(msg.sender);
        require(reward > 0, 'reward is 0');
        (uint128 acc, ) = estimateAccumulated(msg.sender);
        providerStates[msg.sender].processed = acc;
        providerStates[msg.sender].claimedEpochReward = getCurrentEpoch() - 1;
        token.transfer(msg.sender, reward);
    }

    function grantAdditionalReward(address account, uint32 epoch, uint128 amount) public {
        require(msg.sender == owner);
        providerStates[account].additionalRewardTimeline.push(AdditionalReward(amount, epoch));
    }

    function addToWhitelist(address account) public {
        require(msg.sender == owner);
        providerStates[account].whitelisted = true;
    }

    function removeFromWhitelist(address account) public {
        require(msg.sender == owner);
        ProviderState storage providerState = providerStates[account];
        uint32 nextEpoch = getCurrentEpoch() + 1;

        // withdraw for provider
        if (providerState.balance > 0) {
            updateAccumulated(providerState); // TODO: Provider yield gets removed, find workaround?
            uint128 balance = providerState.balance;
            providerState.balance = 0;
            providerState.unlockPeriod = 0;
            providerState.lockedUntil = 0;
            providerState.since = 0;

            providerState.balanceTimeline.push(ProviderBalanceChange(0, nextEpoch));
            require(token.transfer(account, balance), 'transfer unsuccessful');
            emit StakeUpdate(msg.sender, 0);
        }

        providerState.totalDelegationsTimeline.push(TotalDelegationChanges(0, 0, 0, nextEpoch, true));

        // remove from whitelist
        providerState.whitelisted = false;
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
