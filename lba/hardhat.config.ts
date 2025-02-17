/**
 * @type import('hardhat/config').HardhatUserConfig
 */
import "@nomicfoundation/hardhat-chai-matchers";
import "@nomiclabs/hardhat-ethers";
import "@nomiclabs/hardhat-etherscan";
import "@nomiclabs/hardhat-solhint";
import "@openzeppelin/hardhat-upgrades";
import "@typechain/hardhat";
import "dotenv/config";
import "hardhat-deploy";
import "solidity-coverage";
import { HardhatUserConfig } from "hardhat/config";

// Custom tasks
import "./tasks";
import { env } from "./env";

const config: HardhatUserConfig = {
  solidity: {
    version: "0.8.13",
    settings: {
      optimizer: {
        enabled: true,
        runs: 1000,
      },
    },
  },
  defaultNetwork: env.defaultNetwork ?? "local",
  networks: {
    local: {
      chainId: 1337,
      // Automine for testing, periodic mini
      mining: {
        auto: !env.automineInterval,
        interval: env.automineInterval,
      },
      allowUnlimitedContractSize: true,
      url: "http://0.0.0.0:8545",
    },
    hardhat: {
      chainId: 1337,
    },
    "sepolia-test": {
      // [deployer, sequencer] (keys are fetched at runtime)
      accounts: [],
      url: "https://arbitrum-sepolia.infura.io/v3/6ec1f9738a3a46b7af2d85e8a07a96e8",
    },
    prod: {
      // [deployer, sequencer] (keys are fetched at runtime)
      accounts: [],
      url: "https://arb1.arbitrum.io/rpc",
    },
    "blast-test": {
      // [deployer, sequencer] (keys are fetched at runtime)
      accounts: [],
      url: "https://orbital-spring-bush.blast-sepolia.quiknode.pro/cce002b2627e40aefcc8b188206fec4572a1b225",
    },
    "blast-prod": {
      // [deployer, sequencer] (keys are fetched at runtime)
      accounts: [],
      url: "https://rpc.blast.io",
    },
    "mantle-test": {
      // [deployer, sequencer] (keys are fetched at runtime)
      accounts: [],
      url: "https://rpc.sepolia.mantle.xyz",
    },
    "mantle-prod": {
      // [deployer, sequencer] (keys are fetched at runtime)
      accounts: [],
      url: "https://thrilling-sleek-mansion.mantle-mainnet.quiknode.pro/0aca8f7bac033c42843e041b2ab43dfa36f4f59d",
    },
    "sei-test": {
      // [deployer, sequencer] (keys are fetched at runtime)
      accounts: [],
      url: "https://lively-small-wave.sei-atlantic.quiknode.pro/fda3c38ead9aa11afb2b4aeb16916f11c4f381a1",
    },
    "sei-prod": {
      // [deployer, sequencer] (keys are fetched at runtime)
      accounts: [],
      url: "https://tiniest-solemn-wish.sei-pacific.quiknode.pro/dff8d3abf2754d0c8aa58cd2360a3638e68f02ff",
    },
    "base-test": {
      // [deployer, sequencer] (keys are fetched at runtime)
      accounts: [],
      url: "https://fittest-cold-county.base-sepolia.quiknode.pro/3d08b02db8b5327853fcc7b233e1db60940c7056",
    },
    "base-prod": {
      // [deployer, sequencer] (keys are fetched at runtime)
      accounts: [],
      url: "https://side-dark-borough.base-mainnet.quiknode.pro/54a4ef64b532c1f9139e5b7e007b23a3ec307098/",
    },
  },
  paths: {
    tests: "./tests",
  },
  etherscan: {
    apiKey: {
      prod: "B8N4V8ZXEXT2HTWEA5JN68NJ2GD4BRQXAZ",
      "sepolia-test": "B8N4V8ZXEXT2HTWEA5JN68NJ2GD4BRQXAZ",
      "mantle-test": "B8N4V8ZXEXT2HTWEA5JN68NJ2GD4BRQXAZ",
      "mantle-prod": "B8N4V8ZXEXT2HTWEA5JN68NJ2GD4BRQXAZ",
      "blast-test": "B8N4V8ZXEXT2HTWEA5JN68NJ2GD4BRQXAZ",
      "blast-prod": "MUFXMVYWU9VKIP5QZMNNZN4GA5SVAERDUW",
      "sei-test": "B8N4V8ZXEXT2HTWEA5JN68NJ2GD4BRQXAZ",
      "sei-prod": "B8N4V8ZXEXT2HTWEA5JN68NJ2GD4BRQXAZ",
      "base-test": "QP14D6T7U98VDES41IE8J2WX6QC4DPQ41N",
      "base-prod": "QP14D6T7U98VDES41IE8J2WX6QC4DPQ41N",
    },
    customChains: [
      {
        network: "prod",
        chainId: 42161,
        urls: {
          apiURL: "https://api.arbiscan.io/api",
          browserURL: "https://arbiscan.io/",
        },
      },
      {
        network: "sepolia-test",
        chainId: 421614,
        urls: {
          apiURL: "https://api-sepolia.arbiscan.io/api",
          browserURL: "https://sepolia.arbiscan.io/",
        },
      },
      {
        network: "mantle-test",
        chainId: 5003,
        urls: {
          apiURL: "https://explorer.sepolia.mantle.xyz/api",
          browserURL: "https://explorer.sepolia.mantle.xyz",
        },
      },
      {
        network: "mantle-prod",
        chainId: 5000,
        urls: {
          apiURL: "https://explorer.mantle.xyz/api",
          browserURL: "https://explorer.mantle.xyz",
        },
      },
      {
        network: "blast-test",
        chainId: 168587773,
        urls: {
          apiURL:
            "https://api.routescan.io/v2/network/testnet/evm/168587773/etherscan",
          browserURL: "https://testnet.blastscan.io",
        },
      },
      {
        network: "blast-prod",
        chainId: 81457,
        urls: {
          apiURL: "https://api.blastscan.io/api",
          browserURL: "https://blastscan.io",
        },
      },
      {
        network: "sei-test",
        chainId: 1328,
        urls: {
          apiURL: "https://seitrace.com/atlantic-2/api",
          browserURL: "https://seitrace.com/?chain=atlantic-2",
        },
      },
      {
        network: "sei-prod",
        chainId: 1329,
        urls: {
          apiURL: "https://seitrace.com/pacific-1/api",
          browserURL: "https://seitrace.com/?chain=pacific-1",
        },
      },
      {
        network: "base-test",
        chainId: 84532,
        urls: {
          apiURL: "https://api-sepolia.basescan.org/api",
          browserURL: "https://sepolia-explorer.base.org",
        },
      },
      {
        network: "base-prod",
        chainId: 8453,
        urls: {
          apiURL: "https://api.basescan.org/api",
          browserURL: "https://basescan.org",
        },
      },
    ],
  },
};

export default config;
