import { HardhatRuntimeEnvironment } from "hardhat/types";
import { OmnichainLedgerTestV1, OmnichainLedgerV1 } from "../../types";

export function getContractAddress(argAddress: string | undefined) {
  // Return argAddress or process.env.CONTRACT_ADDRESS rise error if both are undefined
  const contractAddress = argAddress || process.env.CONTRACT_ADDRESS;
  if (!contractAddress) {
    throw new Error("Contract address is not provided. Provide it as --contract-address or CONTRACT_ADDRESS env variable");
  }
  console.log(`Contract address: ${contractAddress}`);
  return contractAddress;
}
