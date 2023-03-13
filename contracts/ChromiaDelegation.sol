// SPDX-License-Identifier: MIT

/*
    This contract has three parts: Delegation, Yield and ProviderStaking.
*/

pragma solidity ^0.8.17;

import '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import './ProviderStaking.sol';
import 'hardhat/console.sol';

interface TwoWeeksNotice {
    function estimateAccumulated(address account) external view returns (uint128, uint128);

    function getStakeState(address account) external view returns (uint64, uint64, uint64, uint64);
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
    uint16 claimedEpoch;
    bool addedToArray;
    mapping(uint16 => DelegationChange) delegationTimeline; // each uint key is a week starting from "startTime"
    uint16[] delegationTimelineChanges;
}

/// @title ChromiaProvider Delegation
/// @author Koray Kaya
/// @notice TwoWeekNoticeProvider extension that allows delegation rewards for an existing TwoWeekNotice contract.
/// @dev Syncronizes state with the TWN contract when delegation is altered.
/// @dev Syncronization must also be performed after a TWN withdrawal
contract ChromiaDelegation is ProviderStaking {
    mapping(address => DelegationState) public delegatorStates;
    RateTimeline delegatorYieldTimeline;

    address[] public allDelegatorAddresses;

    TwoWeeksNotice public twn;

    constructor(
        IERC20 _token,
        TwoWeeksNotice _twn,
        address _owner,
        uint16 initial_reward,
        uint16 initial_reward_provider,
        uint16 initial_del_reward_provider,
        address _bank
    ) ProviderStaking(_token, _owner, initial_reward_provider, initial_del_reward_provider, _bank) {
        delegatorYieldTimeline.timeline[0] = RateChange(initial_reward, true);
        delegatorYieldTimeline.changes.push(0);
        twn = _twn;
    }

    /// @dev Ensure the delegator's stake on the TWN contract has not been released.
    function verifyStake(address account) internal view {
        (, uint128 remoteAccumulated) = twn.estimateAccumulated(account);

        uint128 deltaTime = uint128(block.timestamp) - delegatorStates[account].processedDate;
        uint128 localAccumulated = (delegatorStates[account].balanceAtProcessed * deltaTime) / 86400;

        require(
            remoteAccumulated >= (localAccumulated + delegatorStates[account].processed),
            'Accumulated doesnt match with TWN'
        );
    }

    /// @notice Set the reward rate to `rewardRate` for the *next* epoch
    function setRewardRate(uint16 newRate) external {
        setNewRate(newRate, delegatorYieldTimeline);
    }

    /// @notice Get the active delegates state for `account` at epoch `epoch`
    function getActiveDelegation(address account, uint16 epoch) public view returns (DelegationChange memory activeDelegation) {
        DelegationState storage userState = delegatorStates[account];
        if (userState.delegationTimelineChanges.length > 0) {
            for (uint i = userState.delegationTimelineChanges.length - 1; i >= 0; i--) {
                if (userState.delegationTimelineChanges[i] <= epoch) {
                    return userState.delegationTimeline[userState.delegationTimelineChanges[i]];
                }
                if (i == 0) break;
            }
        }
    }

    // TODO: add reset function that completely resets all rewards and everything in case user messes up the sync
    /// @notice Get the reward rate active at epoch `epoch`
    function getActiveRate(uint16 epoch) public view returns (uint128 activeRate) {
        return getActiveRate(epoch, delegatorYieldTimeline);
    }

    /// @notice Calculate the total accumulated reward available to `account`
    function estimateYield(address account) public view returns (uint128 reward) {
        DelegationState storage userState = delegatorStates[account];
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
                activeRate = delegatorYieldTimeline.timeline[i].changed ? delegatorYieldTimeline.timeline[i].rate : activeRate;

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

    /// @notice Informs the reward contract of a withdrawal on TWN. Failure to do so may result in lost.
    function syncWithdrawRequest() external {
        (, , uint64 lockedUntil, ) = twn.getStakeState(msg.sender);
        require(lockedUntil > 0, 'Withdraw has not been requested');
        DelegationState storage userState = delegatorStates[msg.sender];
        (, uint128 acc) = twn.estimateAccumulated(msg.sender);

        uint16 lockedUntilEpoch = getEpoch(lockedUntil);
        userState.balanceAtProcessed = 0;
        userState.processed = acc;
        userState.processedDate = uint128(block.timestamp);
        userState.delegationTimeline[lockedUntilEpoch - 2] = DelegationChange(0, address(0), true);
        userState.delegationTimelineChanges.push(lockedUntilEpoch - 2);
    }

    /// @notice Claims the rewards (which should be per `estimateYield(account)`) for `account`
    function claimYield(address account) public {
        require(delegatorStates[account].processedDate > 0, 'Address must make a first delegation.');
        uint128 reward = estimateYield(account);
        if (reward > 0) {
            delegatorStates[account].claimedEpoch = getCurrentEpoch() - 1;
            token.transferFrom(bank, account, reward);
        }
    }

    /// @notice Set the delegation of the caller for the *next* epoch
    function delegate(address to) public {
        DelegationState storage userState = delegatorStates[msg.sender];
        (, uint128 acc) = twn.estimateAccumulated(msg.sender);
        (uint64 delegateAmount, , uint64 lockedUntil, ) = twn.getStakeState(msg.sender);
        require(delegateAmount > 0, 'Must have a stake to delegate');
        require(lockedUntil == 0, 'Cannot change delegation while withdrawing');
        require(providerStates[to].whitelisted, 'Provider must be whitelisted');

        uint16 currentEpoch = getCurrentEpoch();

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
        userState.delegationTimelineChanges.push(currentEpoch + 1);

        // Add delegation to new providers pool
        ProviderState storage providerState = providerStates[to];
        providerState.providerStateTimeline[currentEpoch + 1].delegationsIncrease += delegateAmount;

        if (!userState.addedToArray) {
            allDelegatorAddresses.push(msg.sender);
            userState.addedToArray = true;
        }
    }

    function getNumberOfDelegators() external view returns (uint count) {
        for (uint i = 0; i < allDelegatorAddresses.length; i++) {
            DelegationChange memory activeDelegation = getActiveDelegation(allDelegatorAddresses[i], getCurrentEpoch());
            if (activeDelegation.balance > 0 && activeDelegation.delegatedTo != address(0)) {
                count++;
            }
        }
    }

    /// @notice Removes the delegation of the caller for the *next* epoch *if* they are not withdrawing
    function undelegate() public {
        (, , uint64 lockedUntil, ) = twn.getStakeState(msg.sender);
        require(lockedUntil == 0, 'Cannot change delegation while withdrawing');
        uint16 currentEpoch = getCurrentEpoch();
        DelegationChange memory currentDelegation = getActiveDelegation(msg.sender, currentEpoch + 1);
        DelegationState storage userState = delegatorStates[msg.sender];
        userState.delegationTimeline[currentEpoch + 1] = DelegationChange(currentDelegation.balance, address(0), true);
        userState.delegationTimelineChanges.push(currentEpoch + 1);
    }

    function getAllDelegatorAddresses(uint from, uint to) external view returns (address[] memory result) {
        to = (allDelegatorAddresses.length > to) ? to : allDelegatorAddresses.length;
        result = new address[](to - from);
        for (uint i = 0; i < result.length; i++) {
            DelegationChange memory activeDelegation = getActiveDelegation(allDelegatorAddresses[from + i], getCurrentEpoch());
            if (
                allDelegatorAddresses[from + i] != address(0) &&
                activeDelegation.balance > 0 &&
                activeDelegation.delegatedTo != address(0)
            ) {
                result[i] = allDelegatorAddresses[from + i];
            }
        }
    }

    /// @notice Sends all CHR tokens to the contract owner. Only the owner can call.
    function drain() external {
        require(msg.sender == owner);
        token.transfer(owner, token.balanceOf(address(this)));
    }
}
