/**
 *Submitted for verification at BscScan.com on 2021-08-11
*/

// SPDX-License-Identifier: MIT

pragma solidity 0.8.17;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

interface TwoWeeksNotice {
    
    function estimateAccumulated(address account) external view returns (uint128, uint128);
    
}

contract Rewards {
    
    mapping (address => uint128) public processed;
    uint64 public rewardPerDayPerToken;
    TwoWeeksNotice public twn;
    IERC20 public token;
    address public owner;
    
    constructor (IERC20 _token, TwoWeeksNotice _twn, address _owner, uint64 inital_reward) {
        token = _token;
        twn = _twn;
        rewardPerDayPerToken = inital_reward;
        owner = _owner;
    }
    
    function estimateReward(address account) external view returns (uint256 reward) {
        uint128 prevPaid = processed[account];
        (uint128 acc,) = twn.estimateAccumulated(account);
        uint128 delta = acc - prevPaid;
        reward = (rewardPerDayPerToken * delta) / 1000000;
    }
    
    function setRewardRate(uint64 rewardRate) external {
        require(msg.sender == owner);
        
        rewardPerDayPerToken = rewardRate;
    }
    
    function payReward(address to) public {
        uint128 prevPaid = processed[to];
        (uint128 acc,) = twn.estimateAccumulated(to);
        if (acc > prevPaid) {
            uint128 delta = acc - prevPaid;
            uint128 reward = (rewardPerDayPerToken * delta) / 1000000;
            if (reward > 0) {
                processed[to] = acc;
                token.transfer(to, reward);
            }
        }
    }
    
    function distribute() external {
        payReward(msg.sender);
    }
    
    function returnToTresury () external {
        require(msg.sender == owner);
        token.transfer(owner, token.balanceOf(address(this)));
    }
    

}