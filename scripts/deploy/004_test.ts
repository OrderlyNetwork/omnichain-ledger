import * as helpers from "@nomicfoundation/hardhat-network-helpers";
import { expect } from "chai";
import { DeployFunction } from "hardhat-deploy/types";
import { HardhatRuntimeEnvironment } from "hardhat/types";
import { ONE_DAY_IN_SECONDS, ONE_HOUR_IN_SECONDS, ONE_WEEK_IN_SECONDS } from "../../test/utilities";
import { OmnichainLedgerV1 } from "../../types";

const func: DeployFunction = async function (hre: HardhatRuntimeEnvironment) {
  const runTest = process.env.RUN_TEST || false;

  if (!runTest) {
    console.log("Skip running 004-test");
    return true;
  }

  console.log("######### Running 004-test #########");

  const { ethers } = hre;
  const deployer = await ethers.getNamedSigner("deployer");
  const user = await ethers.getNamedSigner("user");

  const OmnichainLedgerV1 = await ethers.getContract<OmnichainLedgerV1>("OmnichainLedgerV1");

  const occAdaptor = await OmnichainLedgerV1.occAdaptor();
  console.log("occAdaptor:", occAdaptor);

  const orderTokenOft = await OmnichainLedgerV1.orderTokenOft();
  console.log("orderTokenOft:", orderTokenOft);

  const orderCollector = await OmnichainLedgerV1.orderCollector();
  console.log("orderCollector:", orderCollector);

  const valorPerSecond = await OmnichainLedgerV1.valorPerSecond();
  console.log("valorPerSecond:", valorPerSecond.toString());

  const maximumValorEmission = await OmnichainLedgerV1.maximumValorEmission();
  console.log("maximumValorEmission:", maximumValorEmission.toString());

  console.log("Finished running 004-test");

  return true;
};
func.id = "004-test";
export default func;
