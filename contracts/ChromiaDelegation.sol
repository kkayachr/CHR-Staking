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
    struct RewardPerDayPerTokenChange {
        uint128 timePoint;
        uint128 rewardPerDayPerToken;
    }

    struct DelegationChange {
        uint128 timePoint;
        uint128 balance;
        address delegatedTo;
    }

    struct DelegationState {
        uint128 processed;
        uint128 processedDate;
        uint128 balanceAtProcessed;
        mapping(uint32 => DelegationChange) delegationTimeline; // each uint key is a week starting from "startTime"
    }

    mapping(address => DelegationState) public delegations;
    mapping(uint32 => RewardPerDayPerTokenChange) public rewardPerDayPerTokenTimeline;

    TwoWeeksNotice public twn;

    constructor(
        IERC20 _token,
        TwoWeeksNotice _twn,
        address _owner,
        uint64 inital_reward,
        uint64 inital_reward_provider
    ) TwoWeeksNoticeProvider(_token, _owner, inital_reward_provider) {
        rewardPerDayPerTokenTimeline[0] = RewardPerDayPerTokenChange(uint128(block.timestamp), inital_reward);
        twn = _twn;
    }

    function verifyStake(address account) internal view {
        (, uint128 remoteAccumulated) = twn.estimateAccumulated(account);

        uint128 deltaTime = uint128(block.timestamp) - delegations[account].processedDate;
        uint128 localAccumulated = (delegations[account].balanceAtProcessed * deltaTime) / 86400;

        require(remoteAccumulated >= (localAccumulated + delegations[account].processed), 'Accumulated doesnt match with TWN');
    }

    function setRewardRate(uint64 rewardRate) external {
        require(msg.sender == owner);
        uint32 currentEpoch = getCurrentEpoch();
        rewardPerDayPerTokenTimeline[currentEpoch + 1] = RewardPerDayPerTokenChange(getEpochTime(currentEpoch + 1), rewardRate);
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

    function estimateYield(address account) public view returns (uint128 reward, uint128 providerReward) {
        DelegationState storage userState = delegations[account];
        uint32 processedEpoch = getEpoch(userState.processedDate) - 1;
        uint32 currentEpoch = getCurrentEpoch();
        if (currentEpoch - 1 > processedEpoch) {
            verifyStake(account); // verify that TWN and ChromiaDelegation are synced

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
                } else if (activeDelegation.delegatedTo == address(0)) {
                    continue;
                } else {
                    if (providerState.stakeTimeline[i].timePoint == 0) {
                        providerState = _states[activeDelegation.delegatedTo];
                    }
                    totalReward += uint128(activeRate.rewardPerDayPerToken * activeDelegation.balance * epochLength);
                }
            }

            if (totalReward == 0) return (0, 0);
            totalReward /= 1000000 * 86400;
            providerReward = totalReward / providerState.rewardFraction;
            reward = totalReward - providerReward;
        }
    }

    function syncWithdrawRequest() external {
        (, , uint64 lockedUntil, ) = twn.getStakeState(msg.sender);
        require(lockedUntil > 0, 'Withdraw has not been requested');
        DelegationState storage userState = delegations[msg.sender];
        (, uint128 acc) = twn.estimateAccumulated(msg.sender);

        uint32 lockedUntilEpoch = getEpoch(lockedUntil);
        userState.balanceAtProcessed = 0;
        userState.processed = acc;
        userState.processedDate = uint128(block.timestamp);
        userState.delegationTimeline[lockedUntilEpoch] = DelegationChange(uint128(getEpochTime(lockedUntilEpoch)), 0, address(0));
    }

    function claimYield(address account) public {
        require(delegations[account].processedDate > 0, 'Address must make a first delegation.');
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
        DelegationState storage userState = delegations[msg.sender];
        (uint128 acc, ) = twn.estimateAccumulated(msg.sender);
        (uint64 delegateAmount, , uint64 lockedUntil, ) = twn.getStakeState(msg.sender);
        require(delegateAmount > 0, 'Must have a stake to delegate');
        require(lockedUntil == 0, 'Cannot change delegation while withdrawing');
        uint32 currentEpoch = getCurrentEpoch();

        userState.processed = acc;
        userState.processedDate = uint128(block.timestamp);
        userState.balanceAtProcessed = delegateAmount;
        userState.delegationTimeline[currentEpoch + 1] = DelegationChange(
            uint128(getEpochTime(currentEpoch + 1)),
            delegateAmount,
            to
        );
    }

    function undelegate() public {
        (, , uint64 lockedUntil, ) = twn.getStakeState(msg.sender);
        require(lockedUntil == 0, 'Cannot change delegation while withdrawing');
        uint32 currentEpoch = getCurrentEpoch();
        DelegationChange memory currentDelegation = getActiveDelegation(msg.sender, currentEpoch + 1);
        DelegationState storage userState = delegations[msg.sender];
        userState.delegationTimeline[currentEpoch + 1] = DelegationChange(
            uint128(getEpochTime(currentEpoch + 1)),
            currentDelegation.balance,
            address(0)
        );
    }

    function drain() external {
        require(msg.sender == owner);
        token.transfer(owner, token.balanceOf(address(this)));
    }
}
