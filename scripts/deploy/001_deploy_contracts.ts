import { BigNumber, BigNumberish, AddressLike } from "ethers";
import { DeployFunction, DeployResult } from "hardhat-deploy/types";
import { Artifact, HardhatRuntimeEnvironment } from "hardhat/types";
import { fullTokens, ONE_DAY_IN_SECONDS, ONE_HOUR_IN_SECONDS, ONE_YEAR_IN_SECONDS } from "../../test/utilities";
import { deployContract } from "../utils/deploy";
import { OmnichainLedgerV1, OmnichainLedgerTestV1 } from "../../types";
import { getChainConfig } from "orderly-network-config";

const func: DeployFunction = async function (hre: HardhatRuntimeEnvironment) {
  const { ethers, getNamedAccounts } = hre;

  const { owner } = await getNamedAccounts();

  // Deploy OmnichainLedgerV1 to orderlySepolia (L`edger) network or hardhat (local) network for testing
  if (hre.network.name === "orderlySepolia" || hre.network.name === "hardhat") {
    const occAdaptor = process.env.OCC_ADAPTOR_ADDRESS || ethers.ZeroAddress;
    const orderCollector = process.env.ORDER_COLLECTOR_ADDRESS || ethers.ZeroAddress;
    const orderTokenOft = process.env.ORDER_TOKEN_OFT_ADDRESS || ethers.ZeroAddress;
    const maximumValorEmission = process.env.MAXIMUM_VALOR_EMISSION ? BigInt(process.env.MAXIMUM_VALOR_EMISSION) : fullTokens(1_000_000_000);
    const valorEmissioDuration = process.env.VALOR_EMISSION_DURATION
      ? BigInt(process.env.VALOR_EMISSION_DURATION)
      : BigInt(200 * 14 * ONE_DAY_IN_SECONDS);
    const valorPerSecond = maximumValorEmission / valorEmissioDuration;
    console.log("owner:", owner);
    console.log("occAdaptor:", occAdaptor);
    console.log("orderCollector:", orderCollector);
    console.log("orderTokenOft:", orderTokenOft);
    console.log("maximumValorEmission:", maximumValorEmission.toString());
    console.log("valorEmissioDuration:", valorEmissioDuration.toString());
    console.log("valorPerSecond:", valorPerSecond.toString());
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

    // Deploy OmnichainLedgerTestV1 with adjustable batchDuration, unstakeLockPeriod, vestingLockPeriod, vestingLinearPeriod for testing purposes
    const OmnichainLedgerTestV1 = await deployContract(hre, "OmnichainLedgerTestV1", [], "proxyNoInit");
    const OmnichainLedgerTestV1Contract = await ethers.getContract<OmnichainLedgerTestV1>("OmnichainLedgerTestV1");
    try {
      await OmnichainLedgerTestV1Contract.initialize(
        owner as AddressLike,
        occAdaptor as AddressLike,
        orderCollector as AddressLike,
        orderTokenOft as AddressLike,
        valorPerSecond,
        maximumValorEmission
      );

      const batchDuration = await OmnichainLedgerTestV1Contract.batchDuration();
      console.log("batchDuration:", batchDuration.toString());

      const ONE_MINUTE_IN_SECONDS = 60;
      await OmnichainLedgerTestV1Contract.setBatchDuration(14 * ONE_MINUTE_IN_SECONDS);
      await OmnichainLedgerTestV1Contract.setUnstakeLockPeriod(7 * ONE_MINUTE_IN_SECONDS);
      await OmnichainLedgerTestV1Contract.setVestingLockPeriod(15 * ONE_MINUTE_IN_SECONDS);
      await OmnichainLedgerTestV1Contract.setVestingLinearPeriod(75 * ONE_MINUTE_IN_SECONDS);
    } catch (e) {
      console.log("OmnichainLedgerTestV1 already initialized");
    }
  }

  console.log("Finished running 001-deploy-contracts");

  return true;
};
export default func;
func.id = "001-deploy-contracts"; // id required to prevent reexecution
func.tags = ["Lock"];
