const {
  time,
  loadFixture,
} = require("@nomicfoundation/hardhat-network-helpers");
const {
  days,
} = require("@nomicfoundation/hardhat-network-helpers/dist/src/helpers/time/duration");
const { expect } = require("chai");
const { ethers } = require("hardhat");
require("dotenv").config();

describe("ChromiaDelegation", function () {
  // We define a fixture to reuse the same setup in every test.
  // We use loadFixture to run this setup once, snapshot that state,
  // and reset Hardhat Network to that snapshot in every test.
  async function deployChromiaDelegation() {
    const [owner] = await ethers.getSigners();
    const randomAddresses = await ethers.getSigners();
    randomAddresses.shift();

    const ERC20Mock = await ethers.getContractFactory("ERC20Mock");
    const erc20Mock = await ERC20Mock.deploy(100000);
    await erc20Mock.deployed();

    const TwoWeeksNotice = await ethers.getContractFactory("contracts/TwoWeeksNotice.sol:TwoWeeksNotice");
    const twoWeeksNotice = await TwoWeeksNotice.deploy(erc20Mock.address);
    await twoWeeksNotice.deployed();

    const ChromiaDelegation = await ethers.getContractFactory("ChromiaDelegation");
    const chromiaDelegation = await ChromiaDelegation.deploy(erc20Mock.address, twoWeeksNotice.address, owner.address, 1);
    await chromiaDelegation.deployed();


    await erc20Mock.mint(randomAddresses[0].address, 10000000000);
    await erc20Mock.mint(chromiaDelegation.address, 10000000000);
    await erc20Mock.connect(randomAddresses[0]).increaseAllowance(twoWeeksNotice.address, 10000000000);
    await erc20Mock.increaseAllowance(chromiaDelegation.address, 10000000000);
    await twoWeeksNotice.connect(randomAddresses[0]).stake(10000000000, days(14));
    await chromiaDelegation.stake(1000, days(14));

    await time.increase(days(365));

    return {
      chromiaDelegation,
      twoWeeksNotice,
      erc20Mock,
      owner,
      randomAddresses
    };
  }

  it("Should let user delegate and record processed", async () => {
    const { chromiaDelegation, twoWeeksNotice, erc20Mock, owner, randomAddresses } =
      await loadFixture(deployChromiaDelegation);

    let prevAcc = await twoWeeksNotice.estimateAccumulated(randomAddresses[0].address);
    await chromiaDelegation.connect(randomAddresses[0]).delegate(owner.address);
    await time.increase(days(365));

    let delegation = await chromiaDelegation.delegations(randomAddresses[0].address);
    await expect(delegation[0]).to.be.closeTo(prevAcc[0], Math.round(prevAcc[0].toNumber() * 0.0000001));
  });

  it("Should not let claim uninitialized yield", async () => {
    const { chromiaDelegation, twoWeeksNotice, erc20Mock, owner, randomAddresses } =
      await loadFixture(deployChromiaDelegation);

    let prevAcc = await twoWeeksNotice.estimateAccumulated(randomAddresses[0].address);
    await expect(chromiaDelegation.claimYield(randomAddresses[0].address)).to.be.revertedWith("Address must make a first delegation.");
  });

  it("Should let claim yield", async () => {
    const { chromiaDelegation, twoWeeksNotice, erc20Mock, owner, randomAddresses } =
      await loadFixture(deployChromiaDelegation);

    await chromiaDelegation.connect(randomAddresses[0]).delegate(owner.address);
    await time.increase(days(365));

    let expectedYield = await chromiaDelegation.estimateYield(randomAddresses[0].address);
    let preBalance = await erc20Mock.balanceOf(randomAddresses[0].address);
    await expect(chromiaDelegation.connect(randomAddresses[0]).claimYield(randomAddresses[0].address)).to.not.be.reverted;
    let postBalance = await erc20Mock.balanceOf(randomAddresses[0].address);

    // Yield has been processed
    let prevAcc = await twoWeeksNotice.estimateAccumulated(randomAddresses[0].address);
    let delegation = await chromiaDelegation.delegations(randomAddresses[0].address);
    await expect(delegation[0]).to.be.closeTo(prevAcc[0], 10);

    // Yield has been received
    await expect(postBalance - preBalance).to.eq(expectedYield);

    let providerReward = await chromiaDelegation.getStakeState(owner.address);
    await expect(providerReward[1]).to.eq(expectedYield * 0.1);


  });
});