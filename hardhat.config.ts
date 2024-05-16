import "@nomicfoundation/hardhat-toolbox";
import "@nomiclabs/hardhat-ethers";
import "@nomiclabs/hardhat-etherscan";
import "@openzeppelin/hardhat-upgrades";
import "@typechain/hardhat";
import "dotenv/config";
import "hardhat-deploy";
import "hardhat-deploy-ethers";
import "hardhat-contract-sizer";
import type { HardhatUserConfig } from "hardhat/config";
import { task } from "hardhat/config";

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
    dev: {
      default: 0
    },
    user: {
      default: 1
    }
  },
  typechain: {
    outDir: "types",
    target: "ethers-v5"
  },
  paths: {
    artifacts: "artifacts",
    cache: "cache",
    deploy: "deploy",
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
      live: false,
      saveDeployments: true,
      tags: ["test", "local"]
    },
    goerli: {
      url: `https://goerli.infura.io/v3/${process.env.INFURA_API_KEY}`,
      accounts,
      chainId: 5,
      live: true,
      saveDeployments: true,
      tags: ["staging"],
      gasPrice: 5000000000,
      gasMultiplier: 2
    },
    avalanche: {
      url: "https://api.avax.network/ext/bc/C/rpc",
      accounts,
      chainId: 43114,
      live: true,
      saveDeployments: true,
      gasPrice: 225000000000
    },
    fuji: {
      url: "https://api.avax-test.network/ext/bc/C/rpc",
      accounts,
      chainId: 43113,
      live: true,
      saveDeployments: true,
      tags: ["staging"],
      gas: 15e6,
      gasMultiplier: 2
    },
    orderly: {
      // url: "https://testnet-fuji-rpc-1.orderly.network/ext/bc/fVgSf4ruGhwvEMd8z6dRwsH6XgRaq31wxN4tRhZPN6rWYhjVt/rpc",
      url: "https://testnet-fuji-rpc-2.orderly.network/ext/bc/fVgSf4ruGhwvEMd8z6dRwsH6XgRaq31wxN4tRhZPN6rWYhjVt/rpc",
      accounts,
      chainId: 986532,
      live: true,
      saveDeployments: true,
      tags: ["staging"],
      gas: 8e6,
      gasMultiplier: 2
    },
    arbitrumGoerli: {
      // url: "https://arbitrum-goerli.infura.io/v3/27e4e66741de4789a7de52b16dc0d4a5",
      url: "https://arbitrum-goerli.publicnode.com",
      accounts,
      chainId: 421613,
      live: true,
      saveDeployments: true,
      tags: ["staging"],
      gasPrice: 200000000
    },
    orderlySepolia: {
      url: "https://l2-orderly-l2-4460-sepolia-8tc3sd7dvy.t.conduit.xyz",
      accounts,
      chainId: 4460,
      live: true,
      saveDeployments: true,
      tags: ["staging"],
      gasPrice: 200000000
    }
  },
  etherscan: {
    apiKey: {
      fuji: "avascan",
      orderly: "avascan",
      arbitrumGoerli: process.env.ARBISCAN_API_KEY || "",
      orderlySepolia: process.env.SEPOLIA_API_KEY || ""
    },
    customChains: [
      {
        network: "fuji",
        chainId: 43113,
        urls: {
          apiURL: "https://api.avascan.info/v2/network/testnet/evm/43113/etherscan",
          browserURL: "https://testnet.avascan.info/blockchain/c"
        }
      },
      {
        network: "orderly",
        chainId: 986532,
        urls: {
          apiURL: "https://api.avascan.info/v2/network/testnet/evm/986532/etherscan",
          browserURL: "https://testnet.avascan.info/blockchain/orderly"
        }
      },
      {
        network: "arbitrumGoerli",
        chainId: 421613,
        urls: {
          apiURL: "https://api-goerli.arbiscan.io/api",
          browserURL: "https://testnet.arbiscan.io"
        }
      },
      {
        network: "orderlySepolia",
        chainId: 4460,
        urls: {
          apiURL: "https://testnet-explorer.orderly.org/api",
          browserURL: "https://testnet-explorer.orderly.org/"
        }
      }
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
