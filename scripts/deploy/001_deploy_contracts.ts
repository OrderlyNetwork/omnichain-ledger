import { BigNumber, BigNumberish, AddressLike } from "ethers";
import { DeployFunction, DeployResult } from "hardhat-deploy/types";
import { Artifact, HardhatRuntimeEnvironment } from "hardhat/types";
import { fullTokens, ONE_DAY_IN_SECONDS, ONE_HOUR_IN_SECONDS, ONE_YEAR_IN_SECONDS } from "../../test/utilities";
import { deployContract } from "../utils/deploy";
import { OmnichainLedgerV1 } from "../../types";

const func: DeployFunction = async function (hre: HardhatRuntimeEnvironment) {
  const { ethers, getNamedAccount } = hre;

  const { owner, occAdaptor, orderCollector, orderTokenOft } = await getNamedAccounts();

  const maximumValorEmission = process.env.MAXIMUM_VALOR_EMISSION || fullTokens(1_000_000_000);
  const valorEmissioDuration = process.env.VALOR_EMISSION_DURATION || 200 * 14 * ONE_DAY_IN_SECONDS;
  const valorPerSecond = maximumValorEmission.div(valorEmissioDuration);

  const OmnichainLedgerV1 = await deployContract(hre, "OmnichainLedgerV1", [], "proxyNoInit");
  const OmnichainLedgerV1Contract = await ethers.getContract<OmnichainLedgerV1>("OmnichainLedgerV1");
  try {
    await OmnichainLedgerV1Contract.initialize(
      owner as AddressLike,
      occAdaptor as AddressLike,
      orderCollector as AddressLike,
      orderTokenOft as AddressLike,
      valorPerSecond,
      maximumValorEmission
    );
  } catch (e) {
    console.log("OmnichainLedgerV1 already initialized");
  }

  console.log("OmnichainLedgerV1:", OmnichainLedgerV1.address);

  console.log("Finished running 001-deploy-contracts");

  return true;
};
export default func;
func.id = "001-deploy-contracts"; // id required to prevent reexecution
func.tags = ["Lock"];
