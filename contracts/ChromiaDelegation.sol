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
        uint128 rewardPerDayPerToken;
        bool changed;
    }

    struct DelegationChange {
        uint128 balance;
        address delegatedTo;
        bool changed;
    }

    struct DelegationState {
        uint128 processed;
        uint128 processedDate;
        uint128 balanceAtProcessed;
        uint32 claimedEpoch;
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
        rewardPerDayPerTokenTimeline[0] = RewardPerDayPerTokenChange(inital_reward, true);
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
        rewardPerDayPerTokenTimeline[getCurrentEpoch() + 1] = RewardPerDayPerTokenChange(rewardRate, true);
    }

    function getActiveDelegation(address account, uint32 epoch) public view returns (DelegationChange memory activeDelegation) {
        for (uint32 i = epoch; i >= 0; i--) {
            if (delegations[account].delegationTimeline[i].changed) return delegations[account].delegationTimeline[i];
            if (i == 0) break;
        }
    }

    function getActiveRate(uint32 epoch) public view returns (uint128 activeRate) {
        for (uint32 i = epoch; i >= 0; i--) {
            if (rewardPerDayPerTokenTimeline[i].changed) return rewardPerDayPerTokenTimeline[i].rewardPerDayPerToken;
            if (i == 0) break;
        }
    }

    function estimateYield(address account) public view returns (uint128 reward) {
        DelegationState storage userState = delegations[account];
        uint32 processedEpoch = userState.claimedEpoch;
        uint32 currentEpoch = getCurrentEpoch();

        if (currentEpoch - 1 > processedEpoch) {
            verifyStake(account); // verify that TWN > ChromiaDelegation

            uint128 activeRate = getActiveRate(processedEpoch + 1);
            DelegationChange memory activeDelegation = getActiveDelegation(account, processedEpoch + 1);
            ProviderState storage providerState = providerStates[activeDelegation.delegatedTo];
            // TODO: get active provider stake from its timeline - is provider even staked?

            for (uint32 i = processedEpoch + 1; i < currentEpoch; i++) {
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
                } else {
                    // TODO: Do we want time-based reward or epoch based reward?
                    reward += uint128(activeRate * activeDelegation.balance * epochLength);
                }
            }

            if (reward == 0) return 0;
            reward /= 1000000 * 86400;
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
        userState.delegationTimeline[lockedUntilEpoch] = DelegationChange(0, address(0), true);
    }

    function claimYield(address account) public {
        require(delegations[account].processedDate > 0, 'Address must make a first delegation.');
        uint128 reward = estimateYield(account);
        if (reward > 0) {
            delegations[account].claimedEpoch = getCurrentEpoch() - 1;
            token.transfer(account, reward);
        }
    }

    function delegate(address to) public {
        DelegationState storage userState = delegations[msg.sender];
        (, uint128 acc) = twn.estimateAccumulated(msg.sender);
        (uint64 delegateAmount, , uint64 lockedUntil, ) = twn.getStakeState(msg.sender);
        require(delegateAmount > 0, 'Must have a stake to delegate');
        require(lockedUntil == 0, 'Cannot change delegation while withdrawing');
        require(providerStates[to].whitelisted, 'Provider must be whitelisted');

        uint32 currentEpoch = getCurrentEpoch();

        // Remove previous delegation from providers pool
        DelegationChange memory currentDelegation = getActiveDelegation(msg.sender, currentEpoch + 1);
        ProviderState storage prevProviderState = providerStates[currentDelegation.delegatedTo];
        prevProviderState.providerStateTimeline[currentEpoch + 1].delegationsDecrease += currentDelegation.balance;

        if (userState.claimedEpoch == 0) userState.claimedEpoch = currentEpoch;
        // BUG HERE, if claimedEpoch stays the same and processed becomes acc, users can cheat and earn rewards without staking
        // in TWN.
        userState.processed = acc;
        userState.processedDate = uint128(block.timestamp);
        userState.balanceAtProcessed = delegateAmount;
        userState.delegationTimeline[currentEpoch + 1] = DelegationChange(delegateAmount, to, true);

        // Add delegation to new providers pool
        ProviderState storage providerState = providerStates[to];
        providerState.providerStateTimeline[currentEpoch + 1].delegationsIncrease += delegateAmount;
    }

    function undelegate() public {
        (, , uint64 lockedUntil, ) = twn.getStakeState(msg.sender);
        require(lockedUntil == 0, 'Cannot change delegation while withdrawing');
        uint32 currentEpoch = getCurrentEpoch();
        DelegationChange memory currentDelegation = getActiveDelegation(msg.sender, currentEpoch + 1);
        DelegationState storage userState = delegations[msg.sender];
        userState.delegationTimeline[currentEpoch + 1] = DelegationChange(currentDelegation.balance, address(0), true);
    }

    function drain() external {
        require(msg.sender == owner);
        token.transfer(owner, token.balanceOf(address(this)));
    }
}
