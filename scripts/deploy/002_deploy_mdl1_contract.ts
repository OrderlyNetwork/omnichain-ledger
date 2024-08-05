import { BigNumber, BigNumberish, AddressLike } from "ethers";
import { DeployFunction, DeployResult } from "hardhat-deploy/types";
import { Artifact, HardhatRuntimeEnvironment } from "hardhat/types";
import { fullTokens, ONE_DAY_IN_SECONDS, ONE_HOUR_IN_SECONDS, ONE_YEAR_IN_SECONDS } from "../../test/utilities";
import { deployContract } from "../utils/deploy";
import { MerkleDistributorL1 } from "../../types";
import { getChainConfig } from "orderly-network-config";

const func: DeployFunction = async function (hre: HardhatRuntimeEnvironment) {
  const { ethers, getNamedAccounts } = hre;

  if (hre.network.name !== "ethereum" && hre.network.name !== "sepolia" && hre.network.name !== "hardhat") {
    console.log("Skipping 002-deploy-mdl1-contract");
    return true;
  }

  // Deploy MerkleDistributorL1 hardhat (localhost) network for testing
  const { owner } = await getNamedAccounts();

  let orderTokenAddress = process.env.MDL1_ORDER_TOKEN_ADDRESS;
  if (hre.network.name === "hardhat") {
    const orderTokenTotalSupply = fullTokens(1_000_000_000);
    const OrderToken = await deployContract(hre, "OrderToken", [orderTokenTotalSupply]);
    orderTokenAddress = OrderToken.address;
  }

  if (!orderTokenAddress) {
    orderTokenAddress = ethers.ZeroAddress;
  }

  const MerkleDistributorL1 = await deployContract(hre, "MerkleDistributorL1", [], "proxyNoInit");
  const MerkleDistributorL1Contract = await ethers.getContract<MerkleDistributorL1>("MerkleDistributorL1");
  try {
    await MerkleDistributorL1Contract.initialize(owner, orderTokenAddress);
  } catch (e) {
    console.log("MerkleDistributorL1 already initialized");
  }

  console.log("MerkleDistributorL1:", MerkleDistributorL1.address);

  console.log("Finished running 002-deploy-mdl1-contract");

  return true;
};
export default func;
func.id = "002-deploy-mdl1-contract"; // id required to prevent reexecution
func.tags = ["Lock"];
