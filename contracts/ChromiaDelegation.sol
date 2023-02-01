// SPDX-License-Identifier: MIT

/*
    This contract has three parts: Delegation, Yield and TwoWeeksNoticeProvider.
*/

pragma solidity ^0.8.17;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "./TwoWeeksNoticeProvider.sol";

interface TwoWeeksNotice {
    function estimateAccumulated(
        address account
    ) external view returns (uint128, uint128);

    // function getStakeState(
    //     address account
    // ) external view returns (uint64, uint64, uint64, uint64);
}

contract ChromiaDelegation is TwoWeeksNoticeProvider {
    uint64 public rewardPerDayPerToken;
    TwoWeeksNotice public twn;
    address public owner;

    struct Delegation {
        uint128 processed;
        address delegatedTo;
    }

    mapping(address => Delegation) delegations;

    constructor(
        IERC20 _token,
        TwoWeeksNotice _twn,
        address _owner,
        uint64 inital_reward
    ) TwoWeeksNoticeProvider(_token) {
        twn = _twn;
        rewardPerDayPerToken = inital_reward;
        owner = _owner;
    }

    function setRewardRate(uint64 rewardRate) external {
        require(msg.sender == owner);
        rewardPerDayPerToken = rewardRate;
    }

    function estimateYield(
        address account
    ) public view returns (uint128 reward) {
        uint128 prevPaid = delegations[account].processed;
        (uint128 acc, ) = twn.estimateAccumulated(account);
        if (acc > prevPaid) {
            uint128 delta = acc - prevPaid;
            reward = (rewardPerDayPerToken * delta) / 1000000;
        }
    }

    function claimYield(address account) public {
        uint128 reward = estimateYield(account);
        if (reward > 0) {
            (uint128 acc, ) = twn.estimateAccumulated(account);
            delegations[account].processed = acc;
            token.transfer(account, reward);
            addDelegationReward(
                uint64(reward / 100), // TODO: Change to correct reward percentage for provider.
                delegations[account].delegatedTo
            ); 
        }
    }

    function delegate(address to) public {
        Delegation storage userDelegation = delegations[msg.sender];
        (uint128 acc, ) = twn.estimateAccumulated(msg.sender);
        // TODO: Are these needed?
        // (uint64 delegateAmount, , , ) = twn.getStakeState(msg.sender);
        // require(delegateAmount > 0, "Must have a stake to delegate");
        userDelegation.processed = acc;
        userDelegation.delegatedTo = to;
    }

    function undelegate() public {
        delegations[msg.sender].delegatedTo = address(0);
    }

    function drain() external {
        require(msg.sender == owner);
        token.transfer(owner, token.balanceOf(address(this)));
    }
}
