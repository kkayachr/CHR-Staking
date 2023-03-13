<!-- <p align="center">
  <a href="" rel="noopener">
 <img width=200px height=200px src="./logo.png" alt="Project logo"></a>
</p> -->

<h3 align="center">Chromia delegated staking</h3>

<div align="center">

[![Status](https://img.shields.io/badge/status-active-success.svg)]()
[![License](https://img.shields.io/badge/license-MIT-blue.svg)](/LICENSE)

</div>

---

<p align="center"> Enables delegating what users already have staked in TwoWeeksNotice. Providers can also now start providing/staking.
    <br> 
</p>

## 📝 Table of Contents

- [📝 Table of Contents](#-table-of-contents)
- [🏁 About ](#-about-)
- [🤔 Concepts](#-concepts)
  - [Epochs](#epochs)
  - [Sync-ing](#sync-ing)
- [🏁 Getting Started ](#-getting-started-)
  - [Prerequisites](#prerequisites)
- [🔧 Running the tests ](#-running-the-tests-)
- [🎈 Usage ](#-usage-)
- [🚀 Deployment ](#-deployment-)
- [⛏️ Built Using ](#️-built-using-)
- [✍️ Authors ](#️-authors-)

## 🏁 About <a name = "about"></a>

Is designed to sit alongside an already deployed TWN contract.

Allows for four district types of yield to be claimed.

Name  | Paid To | Depends On | Function Call
------------- | ------------- | ------------- | -------------
Delegator Yield | Delegator | Proportionate to staked days. Conditional on delegating to a provider. | `claimYield(account)`
Provider Yield | Provider | Proportionate to the provider's staked days | `claimProviderYield()` `claimAllProviderRewards()`
Provider Delegated Stake Yield | Provider  | Proportionate to the staked days delegated to the provider | `claimProviderDelegationReward()` `claimAllProviderRewards()`
Additional Provider Reward | Provider | Lump amount paid to a provider for a particular epoch. | `claimProviderDelegationReward()` `claimAllProviderRewards()`

## 🤔 Concepts

### Epochs

The staking system manages time in epochs. Reward related changes applied in your present epoch will not take
effect until the next.

The contract starts at epoch zero, and ticks over to the next epoch at > `7 * 24 * 60 * 60 seconds`. So a change applied
20 seconds after the contract is deployed will not be active until `604801 seconds`. A change applied at `604801 seconds`,
will not be active until `1209601 seconds`.

### Sync-ing

The contract replicates state from its companion TwoWeeksNotice contract.

Users **MUST** call `syncWithdrawRequest()` after requesting a withdrawal on the existing TWN contract. Users ***SHOULD*** redelegate their stake if they change the size of their stake locked at the companion TWN.


## 🏁 Getting Started <a name = "getting_started"></a>

These instructions will get you a copy of the project up and running on your local machine for development and testing purposes. See [deployment](#deployment) for notes on how to deploy the project on a live system.

### Prerequisites

Simply do an npm install in the root folder for the prerequisites

```
npm install
```

## 🔧 Running the tests <a name = "tests"></a>

Tests can simply be run by the following console command in the root folder:

```
npx hardhat test
```

## 🎈 Usage <a name="usage"></a>

The smart contract is not yet available on a blockchain network.

## 🚀 Deployment <a name = "deployment"></a>

To be written...

## ⛏️ Built Using <a name = "built_using"></a>

-   [Hardhat](https://hardhat.org/) - Blockchain Tooling

## ✍️ Authors <a name = "authors"></a>

-   [@kkayam](https://github.com/kkayam)
