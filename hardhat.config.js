/** @type import('hardhat/config').HardhatUserConfig */
require("dotenv").config();
require("@nomiclabs/hardhat-waffle");
require("@nomiclabs/hardhat-etherscan");

const BSCTESTNET_PRIVATE_KEY = process.env.BSCTESTNET_PRIVATE_KEY;
const RPC_NODE = process.env.RPC_NODE;
const BSCSCAN_API_KEY = process.env.BSCSCAN_API_KEY;

module.exports = {
  solidity: {
    version: "0.8.17",
    settings: {
      optimizer: {
        enabled: true,
        runs: 200,
      },
    },
  },
  networks: {
    hardhat: {
      allowUnlimitedContractSize: true,
      accounts: {
        count: 50
      }
    },
    BSCTestnet: {
      url: `${RPC_NODE}`,
      accounts: [`0x${BSCTESTNET_PRIVATE_KEY}`],
      allowUnlimitedContractSize: true,
    },
    BSCMainnet: {
      url: `${process.env.RPC_NODE_MAINNET}`,
      accounts: [`0x${process.env.BSCMAINNET_PRIVATE_KEY}`],
      allowUnlimitedContractSize: true,
    },
  },
  etherscan: {
    apiKey: BSCSCAN_API_KEY,
  },
};
