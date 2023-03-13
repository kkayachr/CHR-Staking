/**
 *Submitted for verification at BscScan.com on 2021-08-20
 */

// SPDX-License-Identifier: MIT

pragma solidity ^0.8.17;

import '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import 'hardhat/console.sol';

struct ProviderStateChange {
    uint128 balance;
    uint128 additionalRewardPerDayPerToken;
    uint128 totalDelegations;
    uint128 delegationsIncrease;
    uint128 delegationsDecrease;
    bool totalDelegationsSet;
    bool balanceChanged;
}

struct RateChange {
    uint16 rate;
    bool changed;
}

struct RateTimeline {
    mapping(uint16 => RateChange) timeline;
    uint16[] changes;
}

struct ProviderState {
    uint64 unlockPeriod; // time it takes from requesting withdraw to being able to withdraw
    uint64 lockedUntil; // 0 if withdraw is not requested
    uint64 balance;
    uint16 claimedEpochReward;
    uint16 claimedEpochYield;
    bool whitelisted;
    mapping(uint16 => ProviderStateChange) providerStateTimeline;
    uint16[] providerStateTimelineChanges;
}

/// @title Staking Contract for Chromia Providers
/// @author Koray Kaya based on the generic contract by Alex Mizrahi
/// @notice Locks CHR tokens for  period. Calculates token/days accumulated. Distribution of epoch-based rewards.
/// @dev Despite the name, the lock period is not fixed.
contract ProviderStaking {
    event StakeUpdate(address indexed from, uint64 balance);
    event WithdrawRequest(address indexed from, uint64 until);

    mapping(address => ProviderState) internal providerStates;

    RateTimeline providerYieldRateTimeline; // The regular yield a provider gets on their own stake
    RateTimeline providerRewardRateTimeline; // The reward the provider gets from the delegations that are delegated to them

    address public owner;
    uint internal startTime = block.timestamp;
    uint public epochLength = 1 weeks;
    IERC20 internal token;
    address public bank;

    constructor(
        IERC20 _token,
        address _owner,
        uint16 _rewardPerDayPerTokenProvider,
        uint16 _rewardPerDayPerTotalDelegation,
        address _bank
    ) {
        token = _token;
        owner = _owner;
        bank = _bank;
        providerYieldRateTimeline.timeline[0] = RateChange(_rewardPerDayPerTokenProvider, true);
        providerYieldRateTimeline.changes.push(0);
        providerRewardRateTimeline.timeline[0] = RateChange(_rewardPerDayPerTotalDelegation, true);
        providerRewardRateTimeline.changes.push(0);
    }

    /**
     *
     * SET AND GET RATES
     *
     */

    /// @notice Set the provider yield reward to `newRate` at the new epoch
    function setProviderYieldRate(uint16 newRate) external {
        setNewRate(newRate, providerYieldRateTimeline);
    }

    /// @notice Set the provider reward rate to `newRate` at the new epoch
    function setProviderRewardRate(uint16 newRate) external {
        setNewRate(newRate, providerRewardRateTimeline);
    }

    function setNewRate(uint16 newRate, RateTimeline storage rateTimeline) internal {
        require(msg.sender == owner);
        uint16 nextEpoch = getCurrentEpoch() + 1;
        rateTimeline.timeline[nextEpoch] = RateChange(newRate, true);
        rateTimeline.changes.push(nextEpoch);
    }

    /// @notice Gets the current active provider yield rate in the present epoch
    function getActiveProviderYieldRate(uint16 epoch) public view returns (uint128 activeRate) {
        return getActiveRate(epoch, providerYieldRateTimeline);
    }

    /// @notice Gets the current active reward rate in the present epoch
    function getActiveProviderRewardRate(uint16 epoch) public view returns (uint128 activeRate) {
        return getActiveRate(epoch, providerRewardRateTimeline);
    }

    // BUG: POTENTIAL PROBLEM: what if rateTimeline.changes is not in chronological order? Maybe need to loop through the whole array to make sure
    function getActiveRate(uint16 epoch, RateTimeline storage rateTimeline) internal view returns (uint128 activeRate) {
        for (uint i = rateTimeline.changes.length - 1; i >= 0; i--) {
            if (rateTimeline.changes[i] <= epoch) {
                return rateTimeline.timeline[rateTimeline.changes[i]].rate;
            }
            if (i == 0) break;
        }
    }

    /**
     *
     * PROVIDER STATE
     *
     */
    function getProviderStakeState(address account) external view returns (uint64, uint64, uint64) {
        ProviderState storage providerState = providerStates[account];
        return (providerState.balance, providerState.unlockPeriod, providerState.lockedUntil);
    }

    /// @notice Sets caller's stake to `amount`, locked for `unlockPeriod` seconds.
    /// @param amount Stake size in minor tokens. Must be higher than any existing stake.
    /// @param unlockPeriod Given in seconds. Must be greater than 2 weeks.
    /// @dev Will pull tokens and therefore requires approval.
    /// @dev Updates the accumulated tokens.
    function stakeProvider(uint64 amount, uint64 unlockPeriod) external {
        ProviderState storage providerState = providerStates[msg.sender];

        require(providerState.whitelisted, 'not whitelisted');
        require(amount > 0, 'amount must be positive');
        require(providerState.balance <= amount, 'cannot decrease balance');
        require(unlockPeriod <= 1000 days, 'unlockPeriod cannot be higher than 1000 days');
        require(providerState.unlockPeriod <= unlockPeriod, 'cannot decrease unlock period');
        require(unlockPeriod >= 2 weeks, "unlock period can't be less than 2 weeks");

        uint128 delta = amount - providerState.balance;
        if (delta > 0) {
            require(token.transferFrom(msg.sender, address(this), delta), 'transfer unsuccessful');
        }

        providerState.balance = amount;
        providerState.unlockPeriod = unlockPeriod;
        providerState.lockedUntil = 0;
        ProviderStateChange storage nextStakeChange = providerState.providerStateTimeline[getCurrentEpoch() + 1];
        nextStakeChange.balanceChanged = true;
        nextStakeChange.balance = amount;
        providerState.providerStateTimelineChanges.push(getCurrentEpoch() + 1);

        emit StakeUpdate(msg.sender, amount);
    }

    /// @notice Initiates a withdrawal of the calling provider's stake.
    /// @dev Updates the accumulated tokens.
    function requestWithdrawProvider() external {
        ProviderState storage providerState = providerStates[msg.sender];
        require(providerState.balance > 0);
        providerState.lockedUntil = uint64(block.timestamp + providerState.unlockPeriod);
    }

    /// @notice Withdraws the stake of the calling provider. Requires a previous call to `requestWithdrawProvider()`.
    function withdrawProvider(address to) external {
        ProviderState storage providerState = providerStates[msg.sender];
        require(providerState.balance > 0, 'must have tokens to withdraw');
        // require(providerState.lockedUntil != 0, 'unlock not requested');
        // require(providerState.lockedUntil < block.timestamp, 'still locked');
        uint128 balance = providerState.balance;
        providerState.balance = 0;
        providerState.unlockPeriod = 0;
        providerState.lockedUntil = 0;

        ProviderStateChange storage nextStakeChange = providerState.providerStateTimeline[getCurrentEpoch() + 1];
        nextStakeChange.balanceChanged = true;
        nextStakeChange.balance = 0;

        providerState.providerStateTimelineChanges.push(getCurrentEpoch() + 1);

        require(token.transferFrom(bank, to, balance), 'transfer unsuccessful');
        emit StakeUpdate(msg.sender, 0);
    }

    /// @notice Calculates the total stake for the provider `account` at epoch `epoch`
    /// @return latestTotalDelegations The stake active during that epoch
    function calculateTotalDelegation(uint16 epoch, address account) public view returns (uint128 latestTotalDelegations) {
        ProviderStateChange memory stakeChange;
        uint16 latestTotalDelegationsEpoch;
        for (uint16 i = epoch; i >= 0; i--) {
            stakeChange = providerStates[account].providerStateTimeline[i];
            if (stakeChange.balanceChanged && stakeChange.balance == 0) {
                latestTotalDelegations = 0;
                latestTotalDelegationsEpoch = i;
                break;
            }
            if (stakeChange.totalDelegationsSet) {
                latestTotalDelegations = stakeChange.totalDelegations;
                latestTotalDelegationsEpoch = i;
                break;
            }
            if (i == 0) break;
        }
        for (uint16 i = latestTotalDelegationsEpoch + 1; i <= epoch; i++) {
            stakeChange = providerStates[account].providerStateTimeline[i];
            latestTotalDelegations = latestTotalDelegations + stakeChange.delegationsIncrease - stakeChange.delegationsDecrease;
        }
        return latestTotalDelegations;
    }

    function getActiveProviderBalance(address account, uint16 epoch) public view returns (uint128 activeBalance) {
        ProviderState storage providerState = providerStates[account];
        if (providerState.providerStateTimelineChanges.length > 0) {
            for (uint i = providerState.providerStateTimelineChanges.length - 1; i >= 0; i--) {
                if (
                    providerState.providerStateTimelineChanges[i] <= epoch &&
                    providerState.providerStateTimeline[providerState.providerStateTimelineChanges[i]].balanceChanged
                ) {
                    return providerState.providerStateTimeline[providerState.providerStateTimelineChanges[i]].balance;
                }
                if (i == 0) break;
            }
        }
    }

    /**
     *
     * PROVIDER CLAIM FUNCTIONS
     *
     */

    /// @notice Token yield reward (minor units) claimable now by provider `account`
    function estimateProviderYield(address account) public view returns (uint128 reward) {
        ProviderState storage providerState = providerStates[account];
        uint16 claimedEpochReward = providerState.claimedEpochYield;
        uint16 currentEpoch = getCurrentEpoch();

        if (currentEpoch - 1 > claimedEpochReward) {
            uint128 activeRate = getActiveProviderYieldRate(claimedEpochReward + 1);
            uint128 activeBalance = getActiveProviderBalance(account, claimedEpochReward + 1);

            for (uint16 i = claimedEpochReward + 1; i < currentEpoch; i++) {
                // Check if rate changes this epoch
                activeRate = providerYieldRateTimeline.timeline[i].changed
                    ? providerYieldRateTimeline.timeline[i].rate
                    : activeRate;

                // Check if users delegation changes this epoch
                activeBalance = providerState.providerStateTimeline[i].balanceChanged
                    ? providerState.providerStateTimeline[i].balance
                    : activeBalance;

                reward += uint128(activeRate * activeBalance * epochLength);
            }

            if (reward == 0) return 0;
            reward /= 1000000 * 86400;
        }
    }

    /// @notice Claims token rewards from yield for provider `account`
    function claimProviderYield() public {
        uint128 reward = estimateProviderYield(msg.sender);
        require(reward > 0, 'reward is 0');
        providerStates[msg.sender].claimedEpochYield = getCurrentEpoch() - 1;
        token.transferFrom(bank, msg.sender, reward);
    }

    /// @notice Estimates the per epoch provider yield and additional rewards for `account`
    function estimateProviderDelegationReward() public returns (uint128 reward) {
        ProviderState storage providerState = providerStates[msg.sender];
        uint16 claimedEpochReward = providerState.claimedEpochReward;
        uint16 currentEpoch = getCurrentEpoch();

        if (currentEpoch - 1 > claimedEpochReward) {
            uint128 totalDelegations = calculateTotalDelegation(claimedEpochReward, msg.sender);
            uint128 prevTotalDelegations = totalDelegations;
            uint128 activeRate = getActiveProviderRewardRate(claimedEpochReward + 1);

            for (uint16 i = claimedEpochReward + 1; i < currentEpoch; i++) {
                ProviderStateChange storage psc = providerState.providerStateTimeline[i];
                totalDelegations += psc.delegationsIncrease - psc.delegationsDecrease;

                // Check if rate changes this epoch
                activeRate = providerRewardRateTimeline.timeline[i].changed
                    ? providerRewardRateTimeline.timeline[i].rate
                    : activeRate;

                if (psc.balanceChanged && psc.balance == 0) {
                    totalDelegations = 0;
                }

                reward += uint128(activeRate * totalDelegations * epochLength);
            }
            reward = reward / (1000000 * 86400);
            if (totalDelegations != prevTotalDelegations) {
                ProviderStateChange storage psc = providerState.providerStateTimeline[currentEpoch - 1];
                psc.totalDelegations = totalDelegations;
                psc.totalDelegationsSet = true;
            }
        }
    }

    /// @notice Claims additional token rewards for the calling provider
    function claimProviderDelegationReward() public {
        uint128 reward = estimateProviderDelegationReward();
        require(reward > 0, 'reward is 0');
        providerStates[msg.sender].claimedEpochReward = getCurrentEpoch() - 1;
        token.transferFrom(bank, msg.sender, reward);
    }

    /// @notice Claims both the provider yield and the additional token rewards for the calling provider
    function claimAllProviderRewards() public {
        uint128 reward = estimateProviderDelegationReward();
        reward += estimateProviderYield(msg.sender);
        require(reward > 0, 'reward is 0');
        providerStates[msg.sender].claimedEpochReward = getCurrentEpoch() - 1;
        providerStates[msg.sender].claimedEpochYield = getCurrentEpoch() - 1;
        token.transferFrom(bank, msg.sender, reward);
    }

    /**
     *
     * ADMIN FUNCTIONS
     *
     */

    /// @notice Grants a lump `amount` award to a provider `account` at epoch `epoch`
    function grantAdditionalReward(address account, uint16 epoch, uint128 amount) public {
        require(msg.sender == owner);
        providerStates[account].providerStateTimeline[epoch].additionalRewardPerDayPerToken = amount;
    }

    /// @notice Adds `account` as a valid provider on the whitelist
    function addToWhitelist(address account) public {
        require(msg.sender == owner);
        providerStates[account].whitelisted = true;
    }

    // TODO: Polish this function, make sure it works correctly
    /// @notice Removes `account` from the provider whitelist, and process an immediate withdrawal if successful
    function removeFromWhitelist(address account) public {
        require(msg.sender == owner);
        ProviderState storage providerState = providerStates[account];
        uint16 nextEpoch = getCurrentEpoch() + 1;

        // withdraw for provider
        if (providerState.balance > 0) {
            uint128 balance = providerState.balance;
            providerState.balance = 0;
            providerState.unlockPeriod = 0;
            providerState.lockedUntil = 0;

            ProviderStateChange storage nextStakeChange = providerState.providerStateTimeline[nextEpoch];
            nextStakeChange.balanceChanged = true;
            nextStakeChange.balance = 0;
            require(token.transferFrom(bank, account, balance), 'transfer unsuccessful');
            emit StakeUpdate(msg.sender, 0);
        }

        providerState.providerStateTimeline[nextEpoch].totalDelegations = 0;
        providerState.providerStateTimeline[nextEpoch].totalDelegationsSet = true;

        // remove from whitelist
        providerState.whitelisted = false;
    }

    /**
     *
     * EPOCH HELPERS
     *
     */

    function getCurrentEpoch() public view returns (uint16) {
        return getEpoch(block.timestamp);
    }

    function getEpoch(uint time) public view returns (uint16) {
        require(time > startTime, 'Time must be larger than starttime');
        return uint16((time - startTime) / epochLength);
    }
}
