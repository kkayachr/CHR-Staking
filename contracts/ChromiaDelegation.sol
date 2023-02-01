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

    function getStakeState(
        address account
    ) external view returns (uint64, uint64, uint64, uint64);
    
    function withdraw(address to) external;
}

contract ChromiaDelegation is TwoWeeksNoticeProvider {
    uint64 public rewardPerDayPerToken;
    TwoWeeksNotice public twn;
    address public owner;

    struct Delegation {
        uint64 delegatedAmount;
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

    function estimateReward(
        address account
    ) external view returns (uint256 reward) {
        uint128 prevPaid = delegations[account].processed;
        (uint128 acc, ) = twn.estimateAccumulated(account);
        uint128 delta = acc - prevPaid;
        reward = (rewardPerDayPerToken * delta) / 1000000;
    }

    function setRewardRate(uint64 rewardRate) external {
        require(msg.sender == owner);

        rewardPerDayPerToken = rewardRate;
    }

    function payReward(address to) public {
        uint128 prevPaid = delegations[to].processed;
        (uint128 acc, ) = twn.estimateAccumulated(to);
        if (acc > prevPaid) {
            uint128 delta = acc - prevPaid;
            uint128 reward = (rewardPerDayPerToken * delta) / 1000000;
            if (reward > 0) {
                delegations[to].processed = acc;
                token.transfer(to, reward);
            }
        }
    }

    function delegate(address to) public {
        Delegation storage userDelegation = delegations[msg.sender];
        (uint128 acc, ) = twn.estimateAccumulated(msg.sender);
        (uint64 delegateAmount, , , ) = twn.getStakeState(msg.sender);
        require(delegateAmount > 0, "Must have a stake to delegate");
        userDelegation.processed = acc;
        userDelegation.delegatedTo = to;
        userDelegation.delegatedAmount = delegateAmount;
        addDelegateAmount(delegateAmount, to);
    }

    function undelegate() public {
        Delegation storage userDelegation = delegations[msg.sender];
        removeDelegateAmount(
            userDelegation.delegatedAmount,
            userDelegation.delegatedTo
        );
        userDelegation.delegatedAmount = 0;
        userDelegation.delegatedTo = address(0);
    }

    function userWithdraw(address to) public {
        undelegate();
        twn.withdraw(to);
    }

    function distribute() external {
        payReward(msg.sender);
    }

    function drain() external {
        require(msg.sender == owner);
        token.transfer(owner, token.balanceOf(address(this)));
    }
}
