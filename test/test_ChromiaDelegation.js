const {
  time,
  loadFixture,
} = require("@nomicfoundation/hardhat-network-helpers");
const {
  days, weeks,
} = require("@nomicfoundation/hardhat-network-helpers/dist/src/helpers/time/duration");
const { expect } = require("chai");
const { ethers } = require("hardhat");
require("dotenv").config();


function calcExpectedReward(stake, weeks, rewardsPerDayPerToken) {
  return ((stake * 7 * weeks) / 1000000) * rewardsPerDayPerToken;
}

describe("ChromiaDelegation", function () {
  // We define a fixture to reuse the same setup in every test.
  // We use loadFixture to run this setup once, snapshot that state,
  // and reset Hardhat Network to that snapshot in every test.
  async function deployChromiaDelegation() {
    const [owner] = await ethers.getSigners();
    const randomAddresses = await ethers.getSigners();
    randomAddresses.shift();

    const ERC20Mock = await ethers.getContractFactory("ERC20Mock");
    const erc20Mock = await ERC20Mock.deploy(10000000000);
    await erc20Mock.deployed();

    const TwoWeeksNotice = await ethers.getContractFactory("contracts/old/TwoWeeksNotice.sol:TwoWeeksNotice");
    const twoWeeksNotice = await TwoWeeksNotice.deploy(erc20Mock.address);
    await twoWeeksNotice.deployed();

    const ChromiaDelegation = await ethers.getContractFactory("ChromiaDelegation");
    const chromiaDelegation = await ChromiaDelegation.deploy(erc20Mock.address, twoWeeksNotice.address, owner.address, 548, 548, 1, randomAddresses[10].address);
    await chromiaDelegation.deployed();


    await erc20Mock.mint(randomAddresses[0].address, 20000000000);
    await erc20Mock.mint(chromiaDelegation.address, 10000000000);
    await erc20Mock.mint(randomAddresses[10].address, 10000000000000);
    await erc20Mock.connect(randomAddresses[10]).increaseAllowance(chromiaDelegation.address, 10000000000000);
    await erc20Mock.connect(randomAddresses[0]).increaseAllowance(twoWeeksNotice.address, 20000000000);
    await erc20Mock.increaseAllowance(chromiaDelegation.address, 20000000000);
    await twoWeeksNotice.connect(randomAddresses[0]).stake(10000000000, days(14));
    await chromiaDelegation.addToWhitelist(owner.address);
    await chromiaDelegation.stakeProvider(10000000000, days(14));

    await time.increase(weeks(52));

    return {
      chromiaDelegation,
      twoWeeksNotice,
      erc20Mock,
      owner,
      randomAddresses
    };
  }


  describe("Delegator", function () {
    // User simply claiming their yield
    it("Should let user delegate and record processed", async () => {
      const { chromiaDelegation, twoWeeksNotice, erc20Mock, owner, randomAddresses } =
        await loadFixture(deployChromiaDelegation);

      let prevAcc = await twoWeeksNotice.getAccumulated(randomAddresses[0].address);
      await chromiaDelegation.connect(randomAddresses[0]).delegate(owner.address);
      await time.increase(days(365));

      let delegation = await chromiaDelegation.delegatorStates(randomAddresses[0].address);
      console.log(delegation);
      console.log(prevAcc);
      await expect(delegation[0]).to.be.closeTo(prevAcc[1], Math.round(prevAcc[1].toNumber() * 0.0000001));
    });

    it("Should let user delegate and claim reward", async () => {
      const { chromiaDelegation, twoWeeksNotice, erc20Mock, owner, randomAddresses } =
        await loadFixture(deployChromiaDelegation);

      let expectedReward = calcExpectedReward(10000000000, 5, 548);

      await chromiaDelegation.connect(randomAddresses[0]).delegate(owner.address);
      await time.increase(weeks(6));
      // Epochs:      |Delegate|Reward|Reward|Reward|Reward|Reward|HERE|

      let preBalance = await erc20Mock.balanceOf(randomAddresses[0].address);
      // Claim yield
      await expect(chromiaDelegation.connect(randomAddresses[0]).claimYield(randomAddresses[0].address)).to.not.be.reverted;
      let postBalance = await erc20Mock.balanceOf(randomAddresses[0].address);

      await expect(postBalance - preBalance).to.eq(expectedReward);
    });

    it("Should let user reset account", async () => {
      const { chromiaDelegation, twoWeeksNotice, erc20Mock, owner, randomAddresses } =
        await loadFixture(deployChromiaDelegation);


      await chromiaDelegation.connect(randomAddresses[0]).delegate(owner.address);
      await time.increase(weeks(6));
      // Epochs:      |Delegate|Reward|Reward|Reward|Reward|Reward|HERE|

      var userAccount = await chromiaDelegation.delegatorStates(randomAddresses[0].address);

      await expect(Object.values(userAccount).every((v) => (v === false || v == 0))).to.be.false;

      await chromiaDelegation.connect(randomAddresses[0]).resetAccount();

      userAccount = await chromiaDelegation.delegatorStates(randomAddresses[0].address);

      await expect(Object.values(userAccount).every((v) => (v === false || v == 0))).to.be.true;

    });
    it("Should let user delegate and undelegate reward", async () => {
      const { chromiaDelegation, twoWeeksNotice, erc20Mock, owner, randomAddresses } =
        await loadFixture(deployChromiaDelegation);

      await chromiaDelegation.connect(randomAddresses[0]).delegate(owner.address);
      await chromiaDelegation.connect(randomAddresses[0]).undelegate();

      await time.increase(weeks(6));
      // Claim yield
      await chromiaDelegation.connect(randomAddresses[0]).claimYield(randomAddresses[0].address);
    });
    it("Should not give user delegation reward when withdraw their stake directly from TWN", async () => {
      const { chromiaDelegation, twoWeeksNotice, erc20Mock, owner, randomAddresses } =
        await loadFixture(deployChromiaDelegation);

      await chromiaDelegation.connect(randomAddresses[0]).delegate(owner.address);
      await time.increase(weeks(3));
      await twoWeeksNotice.connect(randomAddresses[0]).requestWithdraw();
      await time.increase(weeks(3));

      let preBalance = await erc20Mock.balanceOf(randomAddresses[0].address);
      // Claim yield
      await expect(chromiaDelegation.connect(randomAddresses[0]).claimYield(randomAddresses[0].address)).
        to.be.revertedWith("Accumulated doesnt match with TWN");
      let postBalance = await erc20Mock.balanceOf(randomAddresses[0].address);

      await expect(postBalance - preBalance).to.eq(0);
    });

    it("Should give user delegation reward when withdraw their stake and sync it", async () => {
      const { chromiaDelegation, twoWeeksNotice, erc20Mock, owner, randomAddresses } =
        await loadFixture(deployChromiaDelegation);

      var expectedReward = calcExpectedReward(10000000000, 2, 548);

      await chromiaDelegation.connect(randomAddresses[0]).delegate(owner.address);
      await time.increase(weeks(3));
      await twoWeeksNotice.connect(randomAddresses[0]).requestWithdraw();
      await chromiaDelegation.connect(randomAddresses[0]).syncWithdrawRequest();
      await time.increase(weeks(2));
      // Epochs:      |Delegate|Reward|Reward|Reward,SYNC|Reward|Withdraw,HERE|

      let preBalance = await erc20Mock.balanceOf(randomAddresses[0].address);
      // Claim yield
      await expect(chromiaDelegation.connect(randomAddresses[0]).claimYield(randomAddresses[0].address)).
        to.not.be.revertedWith("Accumulated doesnt match with TWN");
      let postBalance = await erc20Mock.balanceOf(randomAddresses[0].address);

      await expect(postBalance - preBalance).to.eq(expectedReward);
    });

    // If user hasnt used delegation before, shouldnt let them claim yield
    // since the "processed" variable hasnt been set yet and no delegation
    // has happened. User must first delegate to someone.
    it("Should not let claim uninitialized yield", async () => {
      const { chromiaDelegation, twoWeeksNotice, erc20Mock, owner, randomAddresses } =
        await loadFixture(deployChromiaDelegation);

      await expect(chromiaDelegation.claimYield(randomAddresses[0].address)).to.be.revertedWith("Address must make a first delegation.");
    });

    it("Should give correct delegator reward when provider unstakes", async () => {
      const { chromiaDelegation, twoWeeksNotice, erc20Mock, owner, randomAddresses } =
        await loadFixture(deployChromiaDelegation);

      await chromiaDelegation.connect(randomAddresses[0]).delegate(owner.address);
      await time.increase(weeks(5));

      await chromiaDelegation.withdrawProvider(owner.address);
      await time.increase(weeks(5));
      let preBalance = await erc20Mock.balanceOf(randomAddresses[0].address);
      // Claim yield
      await chromiaDelegation.connect(randomAddresses[0]).claimYield(randomAddresses[0].address);
      let postBalance = await erc20Mock.balanceOf(randomAddresses[0].address);
      var expectedReward = calcExpectedReward(10000000000, 5, 548);
      await expect(postBalance - preBalance).to.eq(expectedReward);
    });

    it("Should give correct delegator reward when provider unstakes twice", async () => {
      const { chromiaDelegation, twoWeeksNotice, erc20Mock, owner, randomAddresses } =
        await loadFixture(deployChromiaDelegation);

      await chromiaDelegation.connect(randomAddresses[0]).delegate(owner.address);
      await time.increase(weeks(5));

      await chromiaDelegation.withdrawProvider(owner.address);
      await erc20Mock.increaseAllowance(chromiaDelegation.address, 10000000000);
      let expectedYield = await chromiaDelegation.estimateYield(randomAddresses[0].address);
      await time.increase(weeks(5));

      await chromiaDelegation.stakeProvider(10000000000, days(14));
      await time.increase(weeks(5));
      await chromiaDelegation.withdrawProvider(owner.address);
      await time.increase(weeks(5));

      let preBalance = await erc20Mock.balanceOf(randomAddresses[0].address);
      // Claim yield
      await chromiaDelegation.connect(randomAddresses[0]).claimYield(randomAddresses[0].address);
      let postBalance = await erc20Mock.balanceOf(randomAddresses[0].address);
      var expectedReward = calcExpectedReward(10000000000, 5, 548);
      await expect(postBalance - preBalance).to.eq(expectedReward);
    });


    it("Should let delegator claim additional rewards", async () => {
      const { chromiaDelegation, twoWeeksNotice, erc20Mock, owner, randomAddresses } =
        await loadFixture(deployChromiaDelegation);

      let expectedReward = calcExpectedReward(10000000000, 5, 548);
      let additionalReward = calcExpectedReward(10000000000, 1, 1);

      await chromiaDelegation.connect(randomAddresses[0]).delegate(owner.address);

      let currentEpoch = await chromiaDelegation.getCurrentEpoch();
      await chromiaDelegation.grantAdditionalReward(owner.address, currentEpoch + 1, 1);
      await time.increase(weeks(6));
      // Epochs:      |Delegate|Reward|Reward|Reward|Reward|Reward|HERE|

      let preBalance = await erc20Mock.balanceOf(randomAddresses[0].address);
      // Claim yield
      await expect(chromiaDelegation.connect(randomAddresses[0]).claimYield(randomAddresses[0].address)).to.not.be.reverted;
      let postBalance = await erc20Mock.balanceOf(randomAddresses[0].address);

      await expect(postBalance - preBalance).to.eq(expectedReward + additionalReward);
    }).timeout(10000);

  });

  describe("Provider", function () {
    // Provider claiming their own yield (not delegation reward)
    it("Should let provider claim yield", async () => {
      const { chromiaDelegation, twoWeeksNotice, erc20Mock, owner, randomAddresses } =
        await loadFixture(deployChromiaDelegation);

      var expectedReward = await calcExpectedReward(10000000000, 51, 548);

      let preBalance = await erc20Mock.balanceOf(owner.address);
      // Claim provider yield
      await chromiaDelegation.claimProviderYield();
      let postBalance = await erc20Mock.balanceOf(owner.address);

      // Provider received yield
      await expect(postBalance - preBalance).to.eq(expectedReward);
    });

    it("Should let provider claim delegator rewards", async () => {
      const { chromiaDelegation, twoWeeksNotice, erc20Mock, owner, randomAddresses } =
        await loadFixture(deployChromiaDelegation);

      // User delegates stake
      await chromiaDelegation.connect(randomAddresses[0]).delegate(owner.address);
      await time.increase(weeks(5));

      let totalDelegation = await chromiaDelegation.calculateTotalDelegation(await chromiaDelegation.getCurrentEpoch(), owner.address);
      var expectedReward = await calcExpectedReward(totalDelegation, 4, 1);

      preBalance = await erc20Mock.balanceOf(owner.address);
      // Claim provider delegation reward
      await chromiaDelegation.claimProviderDelegationReward();
      postBalance = await erc20Mock.balanceOf(owner.address);

      // // Provider has received fee
      await expect(postBalance - preBalance).to.eq(expectedReward);
    }).timeout(10000);

    // Provider claiming delegation reward + their own yield
    it("Should let provider claim all rewards", async () => {
      const { chromiaDelegation, twoWeeksNotice, erc20Mock, owner, randomAddresses } =
        await loadFixture(deployChromiaDelegation);

      // User delegates stake
      await chromiaDelegation.connect(randomAddresses[0]).delegate(owner.address);
      await time.increase(weeks(5));

      let totalDelegation = await chromiaDelegation.calculateTotalDelegation(await chromiaDelegation.getCurrentEpoch(), owner.address);
      var expectedReward = await calcExpectedReward(totalDelegation, 4, 1);

      let estimatedYield = await chromiaDelegation.estimateProviderYield(owner.address);

      preBalance = await erc20Mock.balanceOf(owner.address);
      // Claim provider delegation reward
      await chromiaDelegation.claimAllProviderRewards();
      postBalance = await erc20Mock.balanceOf(owner.address);

      // // Provider has received fee
      await expect(postBalance - preBalance).to.closeTo(expectedReward + estimatedYield.toNumber(), Math.round((expectedReward + estimatedYield.toNumber()) * 0.0000001));
    }).timeout(10000);


    // Provider claiming delegation reward + their own yield
    it("Provider delegator reward should stop accumulating when removed from whitelist", async () => {
      const { chromiaDelegation, twoWeeksNotice, erc20Mock, owner, randomAddresses } =
        await loadFixture(deployChromiaDelegation);

      // User delegates stake
      await chromiaDelegation.connect(randomAddresses[0]).delegate(owner.address);
      await time.increase(weeks(5));

      let totalDelegation = await chromiaDelegation.calculateTotalDelegation(await chromiaDelegation.getCurrentEpoch(), owner.address);
      var expectedReward = await calcExpectedReward(totalDelegation, 5, 1);

      await chromiaDelegation.removeFromWhitelist(owner.address);
      await time.increase(weeks(8));

      preBalance = await erc20Mock.balanceOf(owner.address);
      // Claim provider delegation reward
      await chromiaDelegation.claimProviderDelegationReward();
      postBalance = await erc20Mock.balanceOf(owner.address);

      // // Provider has received fee
      await expect(postBalance - preBalance).to.eq(expectedReward);
    }).timeout(10000);

    it("All provider reward should stop accumulating when removed from whitelist", async () => {
      const { chromiaDelegation, twoWeeksNotice, erc20Mock, owner, randomAddresses } =
        await loadFixture(deployChromiaDelegation);

      // User delegates stake
      await chromiaDelegation.connect(randomAddresses[0]).delegate(owner.address);
      await time.increase(weeks(5));

      let totalDelegation = await chromiaDelegation.calculateTotalDelegation(await chromiaDelegation.getCurrentEpoch(), owner.address);
      var expectedReward = await calcExpectedReward(totalDelegation, 5, 1);
      let estimatedYield = await calcExpectedReward(10000000000, 57, 548); // 52 weeks from fixture plus 5 weeks now

      await chromiaDelegation.removeFromWhitelist(owner.address);
      await time.increase(weeks(10));

      preBalance = await erc20Mock.balanceOf(owner.address);
      // Claim provider delegation reward
      await chromiaDelegation.claimAllProviderRewards();
      postBalance = await erc20Mock.balanceOf(owner.address);

      // // Provider has received fee
      await expect(postBalance - preBalance).to.eq(expectedReward + estimatedYield);
    }).timeout(10000);
  });

  describe("Use flows", function () {
    // User and provider using the contract demonstrated (make sure to see)
    // the deployChromiaDelegation function as well for full use flow.
    it("Normal use flow", async () => {
      const { chromiaDelegation, twoWeeksNotice, erc20Mock, owner, randomAddresses } =
        await loadFixture(deployChromiaDelegation);

      // User delegates stake
      await chromiaDelegation.connect(randomAddresses[0]).delegate(owner.address);
      await time.increase(weeks(15));

      // User claims yield
      let expectedYield = calcExpectedReward(10000000000, 14, 548);
      let preBalance = await erc20Mock.balanceOf(randomAddresses[0].address);
      await expect(chromiaDelegation.connect(randomAddresses[0]).claimYield(randomAddresses[0].address)).to.not.be.reverted;
      let postBalance = await erc20Mock.balanceOf(randomAddresses[0].address);

      // Yield has been received
      await expect(postBalance - preBalance).to.eq(expectedYield);

      // Provider claims delegation rewards
      let expectedProviderReward = calcExpectedReward(10000000000, 14, 1);
      preBalance = await erc20Mock.balanceOf(owner.address);
      // Claim provider delegation reward
      await chromiaDelegation.claimProviderDelegationReward();
      postBalance = await erc20Mock.balanceOf(owner.address);

      // Provider has received fee
      await expect(postBalance - preBalance).to.eq(expectedProviderReward);
    }).timeout(10000);


    it("Normal use flow with increase stake and withdraw", async () => {
      const { chromiaDelegation, twoWeeksNotice, erc20Mock, owner, randomAddresses } =
        await loadFixture(deployChromiaDelegation);

      // User delegates stake
      await chromiaDelegation.connect(randomAddresses[0]).delegate(owner.address);
      await time.increase(weeks(52));

      let expectedYield = calcExpectedReward(10000000000, 51, 548);
      let preBalance = await erc20Mock.balanceOf(randomAddresses[0].address);
      // Claim yield
      await expect(chromiaDelegation.connect(randomAddresses[0]).claimYield(randomAddresses[0].address)).to.not.be.reverted;
      let postBalance = await erc20Mock.balanceOf(randomAddresses[0].address);

      // Yield has been received
      await expect(postBalance - preBalance).to.eq(expectedYield);

      /**
       * Increase stake
       */

      // User increases stake and delegates, total stake now 15000000000
      await twoWeeksNotice.connect(randomAddresses[0]).stake(15000000000, weeks(2));
      await chromiaDelegation.connect(randomAddresses[0]).delegate(owner.address);

      await time.increase(weeks(5));
      expectedYield = calcExpectedReward(15000000000, 4, 548) + calcExpectedReward(10000000000, 1, 548);

      preBalance = await erc20Mock.balanceOf(randomAddresses[0].address);
      // Claim yield
      await expect(chromiaDelegation.connect(randomAddresses[0]).claimYield(randomAddresses[0].address)).to.not.be.reverted;
      postBalance = await erc20Mock.balanceOf(randomAddresses[0].address);

      // Yield has been received
      await expect(postBalance - preBalance).to.eq(expectedYield);

      /**
       * Request withdraw
       */

      await twoWeeksNotice.connect(randomAddresses[0]).requestWithdraw();
      await time.increase(weeks(1));

      // If withdraw request is not synced, do not allow claimYield
      await expect(chromiaDelegation.connect(randomAddresses[0]).claimYield(randomAddresses[0].address)).to.be.revertedWith("Accumulated doesnt match with TWN");
      await chromiaDelegation.connect(randomAddresses[0]).syncWithdrawRequest();

      await time.increase(weeks(5));
      // No yield during withdraw
      expectedYield = calcExpectedReward(15000000000, 0, 548);

      preBalance = await erc20Mock.balanceOf(randomAddresses[0].address);
      // Claim yield
      await expect(chromiaDelegation.connect(randomAddresses[0]).claimYield(randomAddresses[0].address)).to.not.be.reverted;
      postBalance = await erc20Mock.balanceOf(randomAddresses[0].address);

      // Yield has been received
      await expect(postBalance - preBalance).to.eq(expectedYield);
    });
  });

  it("GAS TEST", async () => {
    const { chromiaDelegation, twoWeeksNotice, erc20Mock, owner, randomAddresses } =
      await loadFixture(deployChromiaDelegation);

    await chromiaDelegation.connect(randomAddresses[0]).delegate(owner.address);
    await time.increase(weeks(3));
    await expect(chromiaDelegation.connect(randomAddresses[0]).claimYield(randomAddresses[0].address)).to.not.be.reverted;
    await time.increase(weeks(3));
    await expect(chromiaDelegation.connect(randomAddresses[0]).claimYield(randomAddresses[0].address)).to.not.be.reverted;
    await time.increase(weeks(3));
    await expect(chromiaDelegation.connect(randomAddresses[0]).claimYield(randomAddresses[0].address)).to.not.be.reverted;
    await time.increase(weeks(3));
    await expect(chromiaDelegation.connect(randomAddresses[0]).claimYield(randomAddresses[0].address)).to.not.be.reverted;
    await time.increase(weeks(3));
    await expect(chromiaDelegation.connect(randomAddresses[0]).claimYield(randomAddresses[0].address)).to.not.be.reverted;
    await time.increase(weeks(3));
    await expect(chromiaDelegation.connect(randomAddresses[0]).claimYield(randomAddresses[0].address)).to.not.be.reverted;
    await time.increase(weeks(3));
    await expect(chromiaDelegation.connect(randomAddresses[0]).claimYield(randomAddresses[0].address)).to.not.be.reverted;
    await time.increase(weeks(3));
    await expect(chromiaDelegation.connect(randomAddresses[0]).claimYield(randomAddresses[0].address)).to.not.be.reverted;
    await time.increase(weeks(3));
    await expect(chromiaDelegation.connect(randomAddresses[0]).claimYield(randomAddresses[0].address)).to.not.be.reverted;
    await time.increase(weeks(3));
    await expect(chromiaDelegation.connect(randomAddresses[0]).claimYield(randomAddresses[0].address)).to.not.be.reverted;
    await time.increase(weeks(3));
    await expect(chromiaDelegation.connect(randomAddresses[0]).claimYield(randomAddresses[0].address)).to.not.be.reverted;
    await time.increase(weeks(3));
    await expect(chromiaDelegation.connect(randomAddresses[0]).claimYield(randomAddresses[0].address)).to.not.be.reverted;
  });
});