// SPDX-License-Identifier: MIT

/*
    This contract has three parts: Delegation, Yield and TwoWeeksNoticeProvider.
*/

pragma solidity ^0.8.17;

import '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import './TwoWeeksNoticeProvider.sol';

interface TwoWeeksNotice {
    function estimateAccumulated(address account) external view returns (uint128, uint128);

    function getStakeState(address account) external view returns (uint64, uint64, uint64, uint64);
}

contract ChromiaDelegation is TwoWeeksNoticeProvider {
    uint64 public rewardPerDayPerToken;
    TwoWeeksNotice public twn;

    struct DelegationChange {
        uint128 timePoint;
        uint128 balance;
        address delegatedTo;
    }

    struct Delegation {
        uint128 processed;
        uint128 processedDate;
        uint128 currentDelegationStartDate;
        DelegationChange[] delegationTimeline;
    }

    mapping(address => Delegation) public delegations;

    constructor(
        IERC20 _token,
        TwoWeeksNotice _twn,
        address _owner,
        uint64 inital_reward,
        uint64 inital_reward_provider
    ) TwoWeeksNoticeProvider(_token, _owner, inital_reward_provider) {
        twn = _twn;
        rewardPerDayPerToken = inital_reward;
    }

    function setRewardRate(uint64 rewardRate) external {
        require(msg.sender == owner);
        rewardPerDayPerToken = rewardRate;
    }

    function verifyRemoteAccumulated(uint128 remoteAccumulated, address account) public view {
        uint128 localAccumulated;
        for (uint256 i = 0; i < delegations[account].delegationTimeline.length; i++) {
            if (delegations[account].delegationTimeline[i].timePoint > delegations[account].processedDate) {
                uint128 prevTimepoint = (delegations[account].processedDate >
                    delegations[account].delegationTimeline[i - 1].timePoint)
                    ? delegations[account].processedDate
                    : delegations[account].delegationTimeline[i - 1].timePoint;
                uint128 currentTimepoint = delegations[account].delegationTimeline[i].timePoint;
                uint128 prevBalance = delegations[account].delegationTimeline[i - 1].balance;
                localAccumulated += (currentTimepoint - prevTimepoint) * prevBalance;
            }
        }
        localAccumulated +=
            (delegations[account].delegationTimeline[delegations[account].delegationTimeline.length - 1].timePoint -
                uint128(block.timestamp)) *
            delegations[account].delegationTimeline[delegations[account].delegationTimeline.length - 1].balance;
        require(localAccumulated == remoteAccumulated, 'Accumulated doesnt match with TWN');
    }

    function estimateYield(address account) public view returns (uint128 reward) {
        uint128 prevPaid = delegations[account].processed;
        (uint128 acc, ) = twn.estimateAccumulated(account);
        verifyRemoteAccumulated(acc, account);
        if (acc > prevPaid) {
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
            uint128 subtractedYield;
            if (providerStakeEnd > 0) {
                subtractedYield = calculateYieldOverflow(account, providerStakeEnd); // If provider has ended stake, subtract from that point
            }
            uint128 delta = acc - prevPaid - subtractedYield;
            reward = (rewardPerDayPerToken * delta) / 1000000;
        }
    }

    // If provider has stopped providing, we want to subtract "accumulated token days" from that point.
    function calculateYieldOverflow(address account, uint128 providerStakeEnd) private view returns (uint128 subtractedYield) {
        uint128 prevTimepoint;
        uint128 deltaTime;
        if (delegations[account].delegationTimeline.length > 1) {
            for (uint256 i = 0; i < delegations[account].delegationTimeline.length; i++) {
                if (delegations[account].delegationTimeline[i].timePoint > providerStakeEnd) {
                    prevTimepoint = (providerStakeEnd > delegations[account].delegationTimeline[i - 1].timePoint)
                        ? providerStakeEnd
                        : delegations[account].delegationTimeline[i - 1].timePoint;

                    deltaTime = delegations[account].delegationTimeline[i].timePoint - prevTimepoint;
                    subtractedYield += deltaTime * delegations[account].delegationTimeline[i - 1].balance;
                }
            }
        }
        prevTimepoint = (providerStakeEnd >
            delegations[account].delegationTimeline[delegations[account].delegationTimeline.length - 1].timePoint)
            ? providerStakeEnd
            : delegations[account].delegationTimeline[delegations[account].delegationTimeline.length - 1].timePoint;

        deltaTime = uint128(block.timestamp) - prevTimepoint;
        subtractedYield +=
            deltaTime *
            delegations[account].delegationTimeline[delegations[account].delegationTimeline.length - 1].balance;
    }

    function claimYield(address account) public {
        require(delegations[account].delegationTimeline.length > 0, 'Address must make a first delegation.');
        uint128 reward = estimateYield(account);
        if (reward > 0) {
            (uint128 acc, ) = twn.estimateAccumulated(account);
            delegations[account].processed = acc;
            delegations[account].processedDate = uint128(block.timestamp);
            token.transfer(account, reward);
            addDelegationReward(
                uint64(reward / 10), // TODO: Change to correct reward percentage for provider.
                getCurrentDelegation(account).delegatedTo
            );
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
        delegations[msg.sender].delegationTimeline[delegations[msg.sender].delegationTimeline.length - 1].delegatedTo = to;
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
