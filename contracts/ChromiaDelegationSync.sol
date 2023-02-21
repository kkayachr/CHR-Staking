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

    function requestWithdraw() external;

    function withdraw(address to) external;
}

struct StakeChange {
    uint128 timePoint;
    uint128 balance;
}

contract ChromiaDelegationSync {
    TwoWeeksNotice public twn;

    struct DelegationChange {
        uint128 timePoint;
        uint128 balance;
        address delegatedTo;
    }

    struct DelegationState {
        uint128 processed;
        uint128 processedDate;
        StakeChange[] stakeTimeline;
        mapping(uint32 => DelegationChange) delegationTimeline; // each uint key is a week starting from "startTime"
    }

    mapping(address => DelegationState) public delegations;

    constructor(TwoWeeksNotice _twn) {
        twn = _twn;
    }

    function verifyRemoteAccumulated(address account) internal view {
        (, uint128 remoteAccumulated) = twn.estimateAccumulated(account);
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

    // If provider has stopped providing, we want to subtract "accumulated token days" from that point.
    function estimateAccumulatedFromTo(address account, uint128 from, uint128 to) private view returns (uint128 accumulated) {
        uint128 prevTimepoint;
        uint128 deltaTime;
        DelegationState storage userDelegation = delegations[account];
        uint lastIndex;
        if (userDelegation.stakeTimeline.length > 1) {
            for (uint256 i = 1; i < delegations[account].stakeTimeline.length; i++) {
                lastIndex = i;
                if (userDelegation.stakeTimeline[i].timePoint > to) {
                    break;
                }
                if (userDelegation.stakeTimeline[i].timePoint > from) {
                    prevTimepoint = (from > userDelegation.stakeTimeline[i - 1].timePoint)
                        ? from
                        : userDelegation.stakeTimeline[i - 1].timePoint;

                    deltaTime = userDelegation.stakeTimeline[i].timePoint - prevTimepoint;
                    accumulated += deltaTime * userDelegation.stakeTimeline[i - 1].balance;
                }
            }
        }
        prevTimepoint = (from > userDelegation.stakeTimeline[lastIndex].timePoint)
            ? from
            : userDelegation.stakeTimeline[lastIndex].timePoint;

        deltaTime = to - prevTimepoint;
        accumulated += deltaTime * userDelegation.stakeTimeline[lastIndex].balance;
        accumulated = accumulated / 86400;
    }
}
