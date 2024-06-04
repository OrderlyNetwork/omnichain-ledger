import { types } from "hardhat/config";
import { task } from "hardhat/config";
import { LedgerRoles, ledgerGrantRole, ledgerRevokeRole } from "../utils/ledger";

task("mdl1-propose-root", "Propose new root to the Merkle Distributor L1 contract")
  .addPositionalParam("address", "Address of Merkle Distributor L1", undefined, types.string)
  .addParam("root", "Proposed Merkle Root", undefined, types.string)
  .addParam("startTimestamp", "Timestamp when new root become active", undefined, types.bigint)
  .addParam("endTimestamp", "Timestamp when distribution ends", 0n, types.bigint, true)
  .addParam("ipfsId", "IPFS ID for uploaded Merkle Tree (optional)", "0x00", types.string, true)
  .setAction(async (taskArgs, hre) => {
    console.log(`Running on ${hre.network.name}`);
    console.log(`address: ${taskArgs.address}`);

    const owner = await hre.ethers.getNamedSigner("owner");

    const MerkleDistributorL1 = await hre.ethers.getContractAtWithSignerAddress("MerkleDistributorL1", taskArgs.address, owner.address);
    const MerkleDistributorL1Address = await MerkleDistributorL1.getAddress();
    console.log(`MerkleDistributorL1 address: ${MerkleDistributorL1Address}`);

    console.log("Proposing new root %s", taskArgs.root);
    console.log("startTimestamp: %s", taskArgs.startTimestamp);
    console.log("endTimestamp: %s", taskArgs.endTimestamp);
    console.log("ipfsId: %s", taskArgs.ipfsId);

    console.log("Proposing new root %s", taskArgs.root);
    const tx = await MerkleDistributorL1.connect(owner).proposeRoot(taskArgs.root, taskArgs.startTimestamp, taskArgs.endTimestamp, taskArgs.ipfsId);

    const proposedRoot = await MerkleDistributorL1.getProposedRoot();
    console.log(`Proposed root: ${proposedRoot}`);
  });

export {};
