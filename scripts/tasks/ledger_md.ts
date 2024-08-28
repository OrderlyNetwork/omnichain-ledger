import { types } from "hardhat/config";
import { task } from "hardhat/config";
import { LedgerRoles, getLedgerContract, getLedgerTokenNum, ledgerGrantRole, ledgerRevokeRole } from "../utils/ledger";
import { getContractAddress } from "../utils/common";
import { check } from "prettier";
import { defaultAbiCoder } from "@ethersproject/abi";
import { hexToBytes, bytesToHex } from "ethereum-cryptography/utils";

task("ledger-create-distribution", "Create a new distribution with the given token and propose Merkle root for it")
  .addParam("contractAddress", "Address of the contract", undefined, types.string, true)
  .addParam("distributionId", "The distribution id", undefined, types.int)
  .addParam("token", "The type of the token. Currently only $ORDER token and es$ORDER (record based) are supported.", undefined, types.string)
  .addParam("root", "Proposed Merkle Root", undefined, types.string)
  .addParam("startTimestamp", "Timestamp when new root become active", undefined, types.bigint)
  .addParam("ipfsId", "IPFS ID for uploaded Merkle Tree (optional)", "0x00", types.string, true)
  .addParam("test", "Use OmnichainLedgerTestV1 contract or OmnichainLedgerV1", true, types.boolean, true)
  .setAction(async (taskArgs, hre) => {
    console.log(`Running on ${hre.network.name}`);
    const contractAddress = getContractAddress(taskArgs.contractAddress);
    const tokenNum = getLedgerTokenNum(taskArgs.token);

    console.log("Distribution ID: %s", taskArgs.distributionId);
    console.log("Token: %s", taskArgs.token);
    console.log("Proposing new root %s", taskArgs.root);
    console.log("startTimestamp: %s", taskArgs.startTimestamp);
    console.log("ipfsId: %s", taskArgs.ipfsId);

    const owner = await hre.ethers.getNamedSigner("owner");
    const ledger = await getLedgerContract(hre, contractAddress, owner.address, taskArgs.test);

    await ledger.connect(owner).createDistribution(taskArgs.distributionId, tokenNum, taskArgs.root, taskArgs.startTimestamp, taskArgs.ipfsId);

    const distribution = await ledger.getDistribution(taskArgs.distributionId);
    console.log("Distribution created: %s", distribution);

    const proposedRoot = await ledger.getProposedRoot(taskArgs.distributionId);
    console.log("Proposed root: %s", proposedRoot);
  });

task("ledger-decode-occvaultmessage", "Decode provided data from message")
  .addParam("data", "Data to decode", undefined, types.string, true)
  .setAction(async (taskArgs, hre) => {
    const dataString = taskArgs.data;


    //   struct OCCVaultMessage {
    //     /// @dev the event id for the message, different id for different chains
    //     uint256 chainedEventId;
    //     /// @dev the source chain id, the sender can omit this field
    //     uint256 srcChainId;
    //     /// @dev the symbol of the token
    //     LedgerToken token;
    //     /// @dev the amount of token
    //     uint256 tokenAmount;
    //     /// @dev the address of the sender
    //     address sender;
    //     /// @dev payloadType is the type of the payload
    //     uint8 payloadType;
    //     /// @dev payload is the data to be sent
    //     bytes payload;
    // }

    const dataBytes = hexToBytes(dataString);
    const dataWithoutPrefix = dataBytes.slice(76);
    // const dataWithoutPrefix = data;
    const decoded = defaultAbiCoder.decode(
      [
        "uint256",
        "uint256",
        "uint8",
        "uint256",
        "address",
        "uint8",
        "bytes",
      ],
      dataWithoutPrefix
    );
    console.log(decoded);
  });

export { };
