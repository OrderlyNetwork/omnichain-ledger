import "@nomicfoundation/hardhat-toolbox";
import "@openzeppelin/hardhat-upgrades";
import "@typechain/hardhat";
import "dotenv/config";
import "hardhat-deploy";
import "hardhat-deploy-ethers";
import "hardhat-contract-sizer";
import type { HardhatUserConfig } from "hardhat/config";
import { task } from "hardhat/config";

import "./scripts/tasks/deploy_to";
import "./scripts/tasks/upgrade_ledger";
import "./scripts/tasks/verify_local";
import "./scripts/tasks/verify_etherscan";
import "./scripts/tasks/verify_hardhat";
import { getHardhatNetworkConfig, getHardhatApiKey, getHardhatEtherscanConfig } from "orderly-network-config";

task("accounts", "Prints the list of accounts", async (_args, hre) => {
  const accounts = await hre.ethers.getSigners();
  accounts.forEach(async account => console.info(account.address));
});

const accounts = {
  mnemonic: process.env.MNEMONIC || "test test test test test test test test test test test junk"
};

const config: HardhatUserConfig = {
  defaultNetwork: "hardhat",
  solidity: {
    version: "0.8.22",
    settings: {
      optimizer: {
        enabled: true,
        runs: 200
      }
    }
  },
  namedAccounts: {
    deployer: {
      default: 0
    },
    owner: {
      default: 0
    },
    user: {
      default: 1
    }
  },
  typechain: {
    outDir: "types",
    target: "ethers-v6"
  },
  paths: {
    artifacts: "artifacts",
    cache: "cache",
    deploy: "scripts/deploy",
    deployments: "deployments",
    imports: "imports",
    sources: "contracts",
    tests: "test"
  },
  networks: {
    localhost: {
      chainId: 31337,
      live: false,
      saveDeployments: true,
      tags: ["local"]
    },
    hardhat: {
      forking: {
        enabled: true,
        url: "https://api.avax.network/ext/bc/C/rpc",
        blockNumber: 6394745
      },
      allowUnlimitedContractSize: true,
      live: false,
      saveDeployments: true,
      tags: ["test", "local"]
    },
    arbitrumSepolia: {
      url: `https://sepolia-rollup.arbitrum.io/rpc`,
      accounts,
      chainId: 421614,
      live: true,
      saveDeployments: true,
      tags: ["staging"],
      gasPrice: 10000000000
    },
    orderlySepolia: getHardhatNetworkConfig("orderlySepolia"),
    optimismSepolia: getHardhatNetworkConfig("optimismSepolia"),
    polygonMumbai: getHardhatNetworkConfig("polygonMumbai"),
    polygon: getHardhatNetworkConfig("polygon")
  },
  etherscan: {
    apiKey: {
      arbitrumSepolia: getHardhatApiKey("arbitrumSepolia"),
      orderlySepolia: getHardhatApiKey("orderlySepolia") || "orderlySepolia",
      optimismSepolia: getHardhatApiKey("optimismSepolia"),
      polygonMumbai: getHardhatApiKey("polygonMumbai"),
      polygon: getHardhatApiKey("polygon")
    },
    customChains: [
      getHardhatEtherscanConfig("arbitrumSepolia"),
      getHardhatEtherscanConfig("orderlySepolia"),
      getHardhatEtherscanConfig("optimismSepolia"),
      getHardhatEtherscanConfig("polygonMumbai"),
      getHardhatEtherscanConfig("polygon")
    ]
  },
  external: {
    contracts: [
      {
        artifacts: "node_modules/@layerzerolabs/test-devtools-evm-hardhat/artifacts",
        deploy: "node_modules/@layerzerolabs/test-devtools-evm-hardhat/deploy"
      }
    ],
    deployments: {
      hardhat: ["external"]
    }
  }
};

export default config;
