import { BigNumber, BigNumberish, AddressLike } from "ethers";
import { DeployFunction, DeployResult } from "hardhat-deploy/types";
import { Artifact, HardhatRuntimeEnvironment } from "hardhat/types";
import { fullTokens, ONE_DAY_IN_SECONDS, ONE_HOUR_IN_SECONDS, ONE_YEAR_IN_SECONDS } from "../../test/utilities";
import { deployContract } from "../utils/deploy";
import { OmnichainLedgerV1 } from "../../types";
import { getChainConfig } from "orderly-network-config";

const func: DeployFunction = async function (hre: HardhatRuntimeEnvironment) {
  const { ethers, getNamedAccount } = hre;

  const { owner } = await getNamedAccounts();

  // Deploy OmnichainLedgerV1 to orderlySepolia (L`edger) network or hardhat (local) network for testing
  if (hre.network.name === "orderlySepolia" || hre.network.name === "hardhat") {
    const occAdaptor = process.env.OCC_ADAPTOR_ADDRESS || ethers.constants.AddressZero;
    const orderCollector = process.env.ORDER_COLLECTOR_ADDRESS || ethers.constants.AddressZero;
    const orderTokenOft = process.env.ORDER_TOKEN_OFT_ADDRESS || ethers.constants.AddressZero;

    const maximumValorEmission = process.env.MAXIMUM_VALOR_EMISSION || fullTokens(1_000_000_000);
    const valorEmissioDuration = process.env.VALOR_EMISSION_DURATION || 200 * 14 * ONE_DAY_IN_SECONDS;
    const valorPerSecond = maximumValorEmission.div(valorEmissioDuration);

    console.log("owner:", owner);
    console.log("occAdaptor:", occAdaptor);
    console.log("orderCollector:", orderCollector);
    console.log("orderTokenOft:", orderTokenOft);
    console.log("maximumValorEmission:", maximumValorEmission.toString());
    console.log("valorEmissioDuration:", valorEmissioDuration.toString());
    console.log("valorPerSecond:", valorPerSecond.toString());

    const OmnichainLedgerV1 = await deployContract(
      hre,
      "OmnichainLedgerV1",
      [
        owner as AddressLike,
        occAdaptor as AddressLike,
        orderCollector as AddressLike,
        orderTokenOft as AddressLike,
        valorPerSecond,
        maximumValorEmission
      ],
      "proxyInit"
    );

    console.log("OmnichainLedgerV1:", OmnichainLedgerV1.address);
  }

  console.log("Finished running 001-deploy-contracts");

  return true;
};
export default func;
func.id = "001-deploy-contracts"; // id required to prevent reexecution
func.tags = ["Lock"];
