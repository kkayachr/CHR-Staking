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

    struct Delegation {
        uint128 processed;
        uint128 processedDate;
        uint128 currentDelegationStartDate;
        DelegationChange[] delegationTimeline;
    }

    mapping(address => Delegation) public delegations;
    RewardPerDayPerTokenChange[] public rewardPerDayPerTokenTimeline;

    constructor(
        IERC20 _token,
        TwoWeeksNotice _twn,
        address _owner,
        uint64 inital_reward,
        uint64 inital_reward_provider
    ) TwoWeeksNoticeProvider(_token, _owner, inital_reward_provider) {
        twn = _twn;
        rewardPerDayPerTokenTimeline.push(RewardPerDayPerTokenChange(uint128(block.timestamp), inital_reward));
    }

    function setRewardRate(uint64 rewardRate) external {
        require(msg.sender == owner);
        rewardPerDayPerTokenTimeline.push(RewardPerDayPerTokenChange(uint128(block.timestamp), rewardRate));
    }

    function verifyRemoteAccumulated(uint128 remoteAccumulated, address account) public view {
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

    function estimateYield(address account) public view returns (uint128 reward, uint128 providerReward) {
        uint128 prevPaid = delegations[account].processed;
        (uint128 acc, ) = twn.estimateAccumulated(account);
        if (acc > prevPaid) {
            verifyRemoteAccumulated(acc, account);

            // See if provider has ever withdrawn during the delegation
            StakeState memory providerState = _states[getCurrentDelegation(account).delegatedTo];
            uint128 providerStakeEnd;
            for (uint256 i = 0; i < providerState.stakeTimeline.length; i++) {
                if (
                    providerState.stakeTimeline[i].timePoint > delegations[account].currentDelegationStartDate &&
                    providerState.stakeTimeline[i].balance == 0
                ) {
                    providerStakeEnd = providerState.stakeTimeline[i].timePoint;
                    break;
                }
            }

            uint128 totalReward;
            bool limitedByProviderStakeEnd;
            for (uint i = 0; i < rewardPerDayPerTokenTimeline.length; i++) {
                if (i > 0) {
                    uint128 rewardUntil = (providerStakeEnd < rewardPerDayPerTokenTimeline[i].timePoint && providerStakeEnd != 0)
                        ? providerStakeEnd
                        : rewardPerDayPerTokenTimeline[i].timePoint;
                    totalReward +=
                        estimateAccumulatedFromTo(account, rewardPerDayPerTokenTimeline[i - 1].timePoint, rewardUntil) *
                        rewardPerDayPerTokenTimeline[i].rewardPerDayPerToken;
                    if (rewardUntil == providerStakeEnd) {
                        limitedByProviderStakeEnd = true;
                        break;
                    }
                }
            }

            if (!limitedByProviderStakeEnd) {
                uint128 rewardUntil = (providerStakeEnd < uint128(block.timestamp) && providerStakeEnd != 0)
                    ? providerStakeEnd
                    : uint128(block.timestamp);
                totalReward +=
                    estimateAccumulatedFromTo(
                        account,
                        rewardPerDayPerTokenTimeline[rewardPerDayPerTokenTimeline.length - 1].timePoint,
                        rewardUntil
                    ) *
                    rewardPerDayPerTokenTimeline[rewardPerDayPerTokenTimeline.length - 1].rewardPerDayPerToken;
            }
            totalReward /= 1000000;
            providerReward = (totalReward / providerState.rewardFraction);
            reward = totalReward - providerReward;
        }
    }

    // If provider has stopped providing, we want to subtract "accumulated token days" from that point.
    function estimateAccumulatedFromTo(address account, uint128 from, uint128 to) private view returns (uint128 accumulated) {
        uint128 prevTimepoint;
        uint128 deltaTime;
        if (delegations[account].delegationTimeline.length > 1) {
            for (uint256 i = 1; i < delegations[account].delegationTimeline.length; i++) {
                // TODO: "i" should be 1?
                if (delegations[account].delegationTimeline[i].timePoint > to) break;
                if (delegations[account].delegationTimeline[i].timePoint > from) {
                    prevTimepoint = (from > delegations[account].delegationTimeline[i - 1].timePoint)
                        ? from
                        : delegations[account].delegationTimeline[i - 1].timePoint;

                    deltaTime = delegations[account].delegationTimeline[i].timePoint - prevTimepoint;
                    accumulated += deltaTime * delegations[account].delegationTimeline[i - 1].balance;
                }
            }
        }
        prevTimepoint = (from >
            delegations[account].delegationTimeline[delegations[account].delegationTimeline.length - 1].timePoint)
            ? from
            : delegations[account].delegationTimeline[delegations[account].delegationTimeline.length - 1].timePoint;

        deltaTime = to - prevTimepoint;
        accumulated +=
            deltaTime *
            delegations[account].delegationTimeline[delegations[account].delegationTimeline.length - 1].balance;
        accumulated = accumulated / 86400;
    }

    function claimYield(address account) public {
        require(delegations[account].delegationTimeline.length > 0, 'Address must make a first delegation.');
        (uint128 reward, uint128 providerReward) = estimateYield(account);
        if (reward > 0) {
            (uint128 acc, ) = twn.estimateAccumulated(account);
            delegations[account].processed = acc;
            delegations[account].processedDate = uint128(block.timestamp);
            token.transfer(account, reward);
            addDelegationReward(uint64(providerReward), getCurrentDelegation(account).delegatedTo);
        }
    }

    function getCurrentDelegation(address account) public view returns (DelegationChange memory) {
        return delegations[account].delegationTimeline[delegations[account].delegationTimeline.length - 1];
    }

    function delegate(address to) public {
        Delegation storage userDelegation = delegations[msg.sender];
        (uint128 acc, ) = twn.estimateAccumulated(msg.sender);
        (uint64 delegateAmount, , , ) = twn.getStakeState(msg.sender);
        require(delegateAmount > 0, 'Must have a stake to delegate');
        userDelegation.processed = acc;
        userDelegation.delegationTimeline.push(DelegationChange(uint128(block.timestamp), delegateAmount, to));
    }

    function undelegate() public {
        DelegationChange memory currentDelegation = getCurrentDelegation(msg.sender);
        delegations[msg.sender].delegationTimeline.push(
            DelegationChange(uint128(block.timestamp), currentDelegation.balance, address(0))
        );
    }

    function drain() external {
        require(msg.sender == owner);
        token.transfer(owner, token.balanceOf(address(this)));
    }
}
