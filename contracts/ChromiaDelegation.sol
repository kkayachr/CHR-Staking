// SPDX-License-Identifier: MIT

/*
    This contract has three parts: Delegation, Yield and TwoWeeksNoticeProvider.
*/

pragma solidity ^0.8.17;

import '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import './TwoWeeksNoticeProvider.sol';
import 'hardhat/console.sol';

interface TwoWeeksNotice {
    function estimateAccumulated(address account) external view returns (uint128, uint128);

    function getStakeState(address account) external view returns (uint64, uint64, uint64, uint64);
}

contract ChromiaDelegation is TwoWeeksNoticeProvider {
    TwoWeeksNotice public twn;

    struct DelegationChange {
        uint128 timePoint;
        uint128 balance;
        address delegatedTo;
    }

    struct RewardPerDayPerTokenChange {
        uint128 timePoint;
        uint128 rewardPerDayPerToken;
    }

    struct DelegationState {
        uint128 processed;
        uint128 processedDate;
        DelegationChange[] delegationChanges;
        mapping(uint32 => DelegationChange) delegationTimeline; // each uint key is a week starting from "startTime"
    }

    mapping(address => DelegationState) public delegations;
    mapping(uint32 => RewardPerDayPerTokenChange) public rewardPerDayPerTokenTimeline;

    constructor(
        IERC20 _token,
        TwoWeeksNotice _twn,
        address _owner,
        uint64 inital_reward,
        uint64 inital_reward_provider
    ) TwoWeeksNoticeProvider(_token, _owner, inital_reward_provider) {
        twn = _twn;
        rewardPerDayPerTokenTimeline[0] = RewardPerDayPerTokenChange(uint128(block.timestamp), inital_reward);
    }

    function setRewardRate(uint64 rewardRate) external {
        require(msg.sender == owner);
        uint32 currentEpoch = getCurrentEpoch();
        rewardPerDayPerTokenTimeline[currentEpoch + 1] = RewardPerDayPerTokenChange(getEpochTime(currentEpoch + 1), rewardRate);
    }

    function verifyRemoteAccumulated(address account) public view {
        (uint128 remoteAccumulated, ) = twn.estimateAccumulated(account);
        uint128 localAccumulated = estimateAccumulatedFromTo(
            account,
            delegations[account].processedDate,
            uint128(block.timestamp)
        );

        require(
            localAccumulated > (remoteAccumulated - delegations[account].processed) - 10,
            'Accumulated doesnt match with TWN'
        );
        require(
            localAccumulated < (remoteAccumulated - delegations[account].processed) + 10,
            'Accumulated doesnt match with TWN'
        );
    }

    function getActiveDelegation(address account, uint32 epoch) public view returns (DelegationChange memory activeDelegation) {
        for (uint32 i = epoch; i >= 0; i--) {
            if (delegations[account].delegationTimeline[i].timePoint > 0) return delegations[account].delegationTimeline[i];
            if (i == 0) break;
        }
    }

    function getActiveRate(uint32 epoch) public view returns (RewardPerDayPerTokenChange memory activeRate) {
        for (uint32 i = epoch; i >= 0; i--) {
            if (rewardPerDayPerTokenTimeline[i].timePoint > 0) return rewardPerDayPerTokenTimeline[i];
            if (i == 0) break;
        }
    }

    function changeDelegation(uint128 balance, address delegatedTo) private {
        uint32 currentEpoch = getCurrentEpoch();
        DelegationState storage userState = delegations[msg.sender];
        userState.delegationTimeline[currentEpoch + 1] = DelegationChange(
            uint128(getEpochTime(currentEpoch + 1)),
            balance,
            delegatedTo
        );
        userState.delegationChanges.push(DelegationChange(uint128(block.timestamp), balance, delegatedTo));
    }

    function estimateYield(address account) public view returns (uint128 reward, uint128 providerReward) {
        DelegationState storage userState = delegations[account];
        uint32 processedEpoch = getEpoch(userState.processedDate) - 1;
        uint32 currentEpoch = getCurrentEpoch();
        if (currentEpoch - 1 > processedEpoch) {
            verifyRemoteAccumulated(account); // verify that TWN and ChromiaDelegation are synced

            uint128 totalReward;
            RewardPerDayPerTokenChange memory activeRate = getActiveRate(processedEpoch + 1);
            DelegationChange memory activeDelegation = getActiveDelegation(account, processedEpoch + 1);
            StakeState storage providerState = _states[activeDelegation.delegatedTo];
            for (uint32 i = uint32(processedEpoch) + 1; i < currentEpoch - 1; i++) {
                activeRate = rewardPerDayPerTokenTimeline[i].timePoint > 0 ? rewardPerDayPerTokenTimeline[i] : activeRate;
                activeDelegation = userState.delegationTimeline[i].timePoint > 0
                    ? userState.delegationTimeline[i]
                    : activeDelegation;
                if (providerState.stakeTimeline[i].timePoint > 0 && providerState.stakeTimeline[i].balance == 0) {
                    break;
                } else {
                    if (providerState.stakeTimeline[i].timePoint == 0) {
                        providerState = _states[activeDelegation.delegatedTo];
                    }
                    totalReward += uint128(activeRate.rewardPerDayPerToken * activeDelegation.balance * epochLength);
                }
            }
            totalReward /= 1000000 * 86400;
            providerReward = totalReward / providerState.rewardFraction;
            reward = totalReward - providerReward;
        }
    }

    // If provider has stopped providing, we want to subtract "accumulated token days" from that point.
    function estimateAccumulatedFromTo(address account, uint128 from, uint128 to) private view returns (uint128 accumulated) {
        uint128 prevTimepoint;
        uint128 deltaTime;
        DelegationState storage userDelegation = delegations[account];
        if (userDelegation.delegationChanges.length > 1) {
            for (uint256 i = 1; i < delegations[account].delegationChanges.length; i++) {
                if (userDelegation.delegationChanges[i].timePoint > to) break;
                if (userDelegation.delegationChanges[i].timePoint > from) {
                    prevTimepoint = (from > userDelegation.delegationChanges[i - 1].timePoint)
                        ? from
                        : userDelegation.delegationChanges[i - 1].timePoint;

                    deltaTime = userDelegation.delegationChanges[i].timePoint - prevTimepoint;
                    accumulated += deltaTime * userDelegation.delegationChanges[i - 1].balance;
                }
            }
        }
        prevTimepoint = (from > userDelegation.delegationChanges[userDelegation.delegationChanges.length - 1].timePoint)
            ? from
            : userDelegation.delegationChanges[userDelegation.delegationChanges.length - 1].timePoint;

        deltaTime = to - prevTimepoint;
        accumulated += deltaTime * userDelegation.delegationChanges[userDelegation.delegationChanges.length - 1].balance;
        accumulated = accumulated / 86400;
    }

    function claimYield(address account) public {
        require(delegations[account].delegationChanges.length > 0, 'Address must make a first delegation.');
        require(delegations[account].processedDate > 0, 'Address must be processed.');
        (uint128 reward, uint128 providerReward) = estimateYield(account);
        if (reward > 0) {
            (uint128 acc, ) = twn.estimateAccumulated(account);
            delegations[account].processedDate = uint128(block.timestamp);
            delegations[account].processed = acc;
            token.transfer(account, reward);

            addDelegationReward(uint64(providerReward), getActiveDelegation(account, getCurrentEpoch()).delegatedTo);
        }
    }

    function delegate(address to) public {
        DelegationState storage userDelegation = delegations[msg.sender];
        (uint128 acc, ) = twn.estimateAccumulated(msg.sender);
        (uint64 delegateAmount, , , ) = twn.getStakeState(msg.sender);
        require(delegateAmount > 0, 'Must have a stake to delegate');
        userDelegation.processed = acc;
        userDelegation.processedDate = uint128(block.timestamp);
        changeDelegation(delegateAmount, to);
    }

    function undelegate() public {
        uint32 currentEpoch = getCurrentEpoch();
        DelegationChange memory currentDelegation = getActiveDelegation(msg.sender, currentEpoch);
        changeDelegation(currentDelegation.balance, address(0));
    }

    function drain() external {
        require(msg.sender == owner);
        token.transfer(owner, token.balanceOf(address(this)));
    }
}
