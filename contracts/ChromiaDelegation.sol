// SPDX-License-Identifier: MIT

/*
    This contract has three parts: Delegation, Yield and TwoWeeksNoticeProvider.
*/

pragma solidity ^0.8.17;

import '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import './TwoWeeksNoticeProvider.sol';
import './ChromiaDelegationSync.sol';
import 'hardhat/console.sol';

contract ChromiaDelegation is ChromiaDelegationSync, TwoWeeksNoticeProvider {
    struct RewardPerDayPerTokenChange {
        uint128 timePoint;
        uint128 rewardPerDayPerToken;
    }

    mapping(uint32 => RewardPerDayPerTokenChange) public rewardPerDayPerTokenTimeline;

    constructor(
        IERC20 _token,
        TwoWeeksNotice _twn,
        address _owner,
        uint64 inital_reward,
        uint64 inital_reward_provider
    ) ChromiaDelegationSync(_twn) TwoWeeksNoticeProvider(_token, _owner, inital_reward_provider) {
        rewardPerDayPerTokenTimeline[0] = RewardPerDayPerTokenChange(uint128(block.timestamp), inital_reward);
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

    function changeDelegation(uint128 balance, address delegatedTo) private {
        uint32 currentEpoch = getCurrentEpoch();
        DelegationState storage userState = delegations[msg.sender];
        userState.delegationTimeline[currentEpoch + 1] = DelegationChange(
            uint128(getEpochTime(currentEpoch + 1)),
            balance,
            delegatedTo
        );
        userState.stakeTimeline.push(StakeChange(uint128(block.timestamp), balance));
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

        uint64 requestTime = lockedUntil - 2 weeks;
        userState.stakeTimeline.push(StakeChange(uint128(requestTime), 0));
        uint32 requestEpoch = getEpoch(requestTime);
        userState.delegationTimeline[requestEpoch + 2] = DelegationChange(uint128(getEpochTime(requestEpoch + 2)), 0, address(0));
    }

    function claimYield(address account) public {
        require(delegations[account].stakeTimeline.length > 0, 'Address must make a first delegation.');
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
        (uint64 delegateAmount, , uint64 lockedUntil, ) = twn.getStakeState(msg.sender);
        require(delegateAmount > 0, 'Must have a stake to delegate');
        require(lockedUntil == 0, 'Cannot change delegation while withdrawing');
        userDelegation.processed = acc;
        userDelegation.processedDate = uint128(block.timestamp);
        changeDelegation(delegateAmount, to);
    }

    function undelegate() public {
        (, , uint64 lockedUntil, ) = twn.getStakeState(msg.sender);
        require(lockedUntil == 0, 'Cannot change delegation while withdrawing');
        uint32 currentEpoch = getCurrentEpoch();
        DelegationChange memory currentDelegation = getActiveDelegation(msg.sender, currentEpoch + 1);
        changeDelegation(currentDelegation.balance, address(0));
    }

    function drain() external {
        require(msg.sender == owner);
        token.transfer(owner, token.balanceOf(address(this)));
    }
}
