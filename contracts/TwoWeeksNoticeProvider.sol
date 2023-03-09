/**
 *Submitted for verification at BscScan.com on 2021-08-20
 */

// SPDX-License-Identifier: MIT

pragma solidity ^0.8.17;

import '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import 'hardhat/console.sol';

struct ProviderStateChange {
    uint128 balance;
    uint128 additionalRewardPerDayPerToken;
    uint128 totalDelegations;
    uint128 delegationsIncrease;
    uint128 delegationsDecrease;
    bool totalDelegationsSet;
    bool balanceChanged;
}

struct RateChange {
    uint16 rate;
    bool changed;
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
        uint16 claimedEpochReward;
        bool whitelisted;
        mapping(uint16 => ProviderStateChange) providerStateTimeline;
    }

    event StakeUpdate(address indexed from, uint64 balance);
    event WithdrawRequest(address indexed from, uint64 until);

    mapping(address => ProviderState) internal providerStates;

    mapping(uint16 => RateChange) public rewardPerDayPerTokenProviderTimeline;
    uint16[] public rewardPerDayPerTokenProviderChanges;
    mapping(uint16 => RateChange) public rewardPerDayPerTotalDelegationTimeline;
    uint16[] public rewardPerDayPerTotalDelegationChanges;

    address public owner;
    uint internal startTime = block.timestamp;
    uint public epochLength = 1 weeks;
    IERC20 internal token;
    address public bank;

    constructor(
        IERC20 _token,
        address _owner,
        uint64 _rewardPerDayPerTokenProvider,
        uint64 _rewardPerDayPerTotalDelegation,
        address _bank
    ) {
        token = _token;
        owner = _owner;
        bank = _bank;
        rewardPerDayPerTokenProviderTimeline[0] = _rewardPerDayPerTokenProvider;
        rewardPerDayPerTokenProviderChanges.push(0);
        rewardPerDayPerTotalDelegationTimeline[0] = _rewardPerDayPerTotalDelegation;
        rewardPerDayPerTotalDelegationChanges.push(0);
    }

    function setProviderRewardRate(uint64 rewardRate) external {
        require(msg.sender == owner);
        uint16 nextEpoch = getCurrentEpoch() + 1;
        rewardPerDayPerTokenProviderTimeline[nextEpoch] = rewardRate;
        rewardPerDayPerTokenProviderChanges.push(nextEpoch);
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
        ProviderStateChange memory nextStakeChange = providerState.providerStateTimeline[getCurrentEpoch() + 1];
        nextStakeChange.balanceChanged = true;
        nextStakeChange.balance = amount;
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

        ProviderStateChange storage nextStakeChange = ss.providerStateTimeline[getCurrentEpoch() + 1];
        nextStakeChange.balanceChanged = true;
        nextStakeChange.balance = 0;
        require(token.transferFrom(bank, to, balance), 'transfer unsuccessful');
        emit StakeUpdate(msg.sender, 0);
    }

    function calculateTotalDelegation(uint16 epoch, address account) public view returns (uint128 latestTotalDelegations) {
        ProviderStateChange memory stakeChange;
        uint16 latestTotalDelegationsEpoch;
        for (uint16 i = epoch; i >= 0; i--) {
            stakeChange = providerStates[account].providerStateTimeline[i];
            if (stakeChange.balanceChanged && stakeChange.balance == 0) {
                latestTotalDelegations = 0;
                latestTotalDelegationsEpoch = i;
                break;
            }
            if (stakeChange.totalDelegationsSet) {
                latestTotalDelegations = stakeChange.totalDelegations;
                latestTotalDelegationsEpoch = i;
                break;
            }
            if (i == 0) break;
        }
        for (uint16 i = latestTotalDelegationsEpoch + 1; i <= epoch; i++) {
            stakeChange = providerStates[account].providerStateTimeline[i];
            latestTotalDelegations = latestTotalDelegations + stakeChange.delegationsIncrease - stakeChange.delegationsDecrease;
        }
        return latestTotalDelegations;
    }

    // function estimateProviderYield(address account) public view returns (uint128 reward) {
    //     uint128 prevPaid = providerStates[msg.sender].processed;
    //     (uint128 acc, ) = estimateAccumulated(account);
    //     if (acc > prevPaid) {
    //         uint128 delta = acc - prevPaid;
    //         reward = (rewardPerDayPerTokenProvider * delta) / 1000000;
    //     }
    // }

    function estimateProviderYield(address account) public view returns (uint128 reward) {
        DelegationState storage userState = delegations[account];
        uint16 processedEpoch = userState.claimedEpoch;
        uint16 currentEpoch = getCurrentEpoch();

        if (currentEpoch - 1 > processedEpoch) {
            verifyStake(account); // verify that TWN > ChromiaDelegation

            uint128 activeRate = getActiveRate(processedEpoch + 1);
            DelegationChange memory activeDelegation = getActiveDelegation(account, processedEpoch + 1);
            ProviderState storage providerState = providerStates[activeDelegation.delegatedTo];
            // TODO: get active provider stake from its timeline - is provider even staked?

            for (uint16 i = processedEpoch + 1; i < currentEpoch; i++) {
                // Check if rate changes this epoch
                activeRate = rewardPerDayPerTokenTimeline[i].changed
                    ? rewardPerDayPerTokenTimeline[i].rewardPerDayPerToken
                    : activeRate;

                // Check if users delegation changes this epoch
                activeDelegation = userState.delegationTimeline[i].changed ? userState.delegationTimeline[i] : activeDelegation;

                if (
                    providerState.providerStateTimeline[i].balanceChanged && providerState.providerStateTimeline[i].balance == 0
                ) {
                    // if provider withdrew, stop counting reward
                    break;
                } else if (activeDelegation.delegatedTo == address(0)) {
                    // If user is undelegated this epoch, skip it
                    continue;
                }
                // TODO: Do we want time-based reward or epoch based reward?
                reward += uint128(
                    (activeRate + providerState.providerStateTimeline[i].additionalRewardPerDayPerToken) *
                        activeDelegation.balance *
                        epochLength
                );
            }

            if (reward == 0) return 0;
            reward /= 1000000 * 86400;
        }
    }

    function claimProviderYield() public {
        uint128 reward = estimateProviderYield(msg.sender);
        require(reward > 0, 'reward is 0');
        (uint128 acc, ) = estimateAccumulated(msg.sender);
        providerStates[msg.sender].processed = acc;
        token.transferFrom(bank, msg.sender, reward);
    }

    function estimateProviderDelegationReward() public returns (uint128 reward) {
        ProviderState storage providerState = providerStates[msg.sender];
        uint16 claimedEpochReward = providerState.claimedEpochReward;
        uint16 currentEpoch = getCurrentEpoch();

        if (currentEpoch - 1 > claimedEpochReward) {
            uint128 totalDelegations = calculateTotalDelegation(claimedEpochReward, msg.sender);
            uint128 prevTotalDelegations = totalDelegations;
            for (uint16 i = claimedEpochReward + 1; i < currentEpoch; i++) {
                ProviderStateChange storage psc = providerState.providerStateTimeline[i];
                totalDelegations += psc.delegationsIncrease - psc.delegationsDecrease;

                if (psc.balanceChanged && psc.balance == 0) {
                    totalDelegations = 0;
                }

                reward += uint128(rewardPerDayPerTotalDelegation * totalDelegations * epochLength);
            }
            reward = reward / (1000000 * 86400);
            if (totalDelegations != prevTotalDelegations) {
                ProviderStateChange storage psc = providerState.providerStateTimeline[currentEpoch - 1];
                psc.totalDelegations = totalDelegations;
                psc.totalDelegationsSet = true;
            }
        }
    }

    function claimProviderDelegationReward() public {
        uint128 reward = estimateProviderDelegationReward();
        require(reward > 0, 'reward is 0');
        providerStates[msg.sender].claimedEpochReward = getCurrentEpoch() - 1;
        token.transferFrom(bank, msg.sender, reward);
    }

    function claimAllProviderRewards() public {
        uint128 reward = estimateProviderDelegationReward();
        reward += estimateProviderYield(msg.sender);
        require(reward > 0, 'reward is 0');
        (uint128 acc, ) = estimateAccumulated(msg.sender);
        providerStates[msg.sender].processed = acc;
        providerStates[msg.sender].claimedEpochReward = getCurrentEpoch() - 1;
        token.transferFrom(bank, msg.sender, reward);
    }

    function grantAdditionalReward(address account, uint16 epoch, uint128 amount) public {
        require(msg.sender == owner);
        providerStates[account].providerStateTimeline[epoch].additionalRewardPerDayPerToken = amount;
    }

    function addToWhitelist(address account) public {
        require(msg.sender == owner);
        providerStates[account].whitelisted = true;
    }

    function removeFromWhitelist(address account) public {
        require(msg.sender == owner);
        ProviderState storage providerState = providerStates[account];
        uint16 nextEpoch = getCurrentEpoch() + 1;

        // withdraw for provider
        if (providerState.balance > 0) {
            updateAccumulated(providerState); // TODO: Provider yield gets removed, find workaround?
            uint128 balance = providerState.balance;
            providerState.balance = 0;
            providerState.unlockPeriod = 0;
            providerState.lockedUntil = 0;
            providerState.since = 0;

            ProviderStateChange storage nextStakeChange = providerState.providerStateTimeline[nextEpoch];
            nextStakeChange.balanceChanged = true;
            nextStakeChange.balance = 0;
            require(token.transferFrom(bank, account, balance), 'transfer unsuccessful');
            emit StakeUpdate(msg.sender, 0);
        }

        providerState.providerStateTimeline[nextEpoch].totalDelegations = 0;
        providerState.providerStateTimeline[nextEpoch].totalDelegationsSet = true;

        // remove from whitelist
        providerState.whitelisted = false;
    }

    function getCurrentEpoch() public view returns (uint16) {
        return getEpoch(block.timestamp);
    }

    function getEpoch(uint time) public view returns (uint16) {
        require(time > startTime, 'Time must be larger than starttime');
        return uint16((time - startTime) / epochLength);
    }

    function getEpochTime(uint16 epoch) public view returns (uint128) {
        return uint16(startTime + epoch * epochLength);
    }
}
