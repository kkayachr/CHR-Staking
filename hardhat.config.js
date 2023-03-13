/** @type import('hardhat/config').HardhatUserConfig */
require("dotenv").config();
require("@nomiclabs/hardhat-waffle");
require("@nomiclabs/hardhat-etherscan");
require("hardhat-gas-reporter");
require("solidity-coverage");
require('@primitivefi/hardhat-dodoc');

const NULL_PRIVATE_KEY = '0000000000000000000000000000000000000000000000000000000000000000';
const BSCTESTNET_PRIVATE_KEY = process.env.BSCTESTNET_PRIVATE_KEY || NULL_PRIVATE_KEY;
const BSCMAINNET_PRIVATE_KEY = process.env.BSCMAINNET_PRIVATE_KEY || NULL_PRIVATE_KEY;
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
  gasReporter: {
    currency: "USD",
    token: "ETH",
    gasPriceApi: "https://api.etherscan.io/api?module=proxy&action=eth_gasPrice",
    coinmarketcap: "0431b70e-ffff-4061-81b0-fa361384d36c",
    enabled: (process.env.REPORT_GAS) ? true : false
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
      accounts: [`0x${BSCMAINNET_PRIVATE_KEY}`],
      allowUnlimitedContractSize: true,
    },
  },
  etherscan: {
    apiKey: BSCSCAN_API_KEY,
  },
  dodoc: {
    include: ['ChromiaDelegation.sol', 'old/TwoWeeksNotice.sol'],
    outputDir: 'artifacts/docs',
    freshOutput: true,
  },
};

if (process.env.XUNIT) {
    module.exports.mocha = {
      reporter: 'xunit',
      reporterOption: {
      output: 'artefacts/test-results/mocha/xunit.xml',
    }
  }
}