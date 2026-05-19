require("@nomicfoundation/hardhat-toolbox");
require("dotenv").config();

module.exports = {
  solidity: {
    compilers: [
      { version: "0.8.20" },
      { version: "0.8.19" }
    ],
    settings: { optimizer: { enabled: true, runs: 200 } }
  },
  networks: {
    hardhat: {
      throwOnTransactionFailures: true,
      throwOnCallFailures: true,
    },
    sepolia: {
      url: process.env.SEPOLIA_URL ?? "https://eth-sepolia.public.blastapi.io",
      accounts: process.env.PRIVATE_KEY ? [process.env.PRIVATE_KEY] : [],
    },
    base: {
      url: process.env.BASE_URL ?? "https://mainnet.base.org",
      accounts: process.env.PRIVATE_KEY ? [process.env.PRIVATE_KEY] : [],
    },
    arbitrum: {
      url: process.env.ARBITRUM_URL ?? "https://arb1.arbitrum.io/rpc",
      accounts: process.env.PRIVATE_KEY ? [process.env.PRIVATE_KEY] : [],
    },
  },
  etherscan: {
    apiKey: {
      sepolia:  process.env.ETHERSCAN_API_KEY,
      base:     process.env.BASESCAN_API_KEY,
      arbitrumOne: process.env.ARBISCAN_API_KEY,
    }
  }
};
