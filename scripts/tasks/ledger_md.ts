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

enum PayloadType {
  CLAIM_REWARD = 0,
  STAKE = 1,
  CREATE_ORDER_UNSTAKE_REQUEST = 2,
  CANCEL_ORDER_UNSTAKE_REQUEST = 3,
  WITHDRAW_ORDER = 4,
  ES_ORDER_UNSTAKE_AND_VEST = 5,
  CANCEL_VESTING_REQUEST = 6,
  CANCEL_ALL_VESTING_REQUESTS = 7,
  CLAIM_VESTING_REQUEST = 8,
  REDEEM_VALOR = 9,
  CLAIM_USDC_REVENUE = 10,
  CLAIM_REWARD_BACKWARD = 11,
  WITHDRAW_ORDER_BACKWARD = 12,
  CLAIM_VESTING_REQUEST_BACKWARD = 13,
  CLAIM_USDC_REVENUE_BACKWARD = 14,
}

enum LedgerToken {
  ORDER,
  ESORDER,
  USDC,
  PLACEHOLDER
}

interface OCCVaultMessage {
  chainedEventId: bigint;
  srcChainId: bigint;
  token: number;
  tokenAmount: bigint;
  sender: string;
  payloadType: number;
  payload: string;
}

// Function to convert uint8 to LedgerToken
const getTokenFromIndex = (index: number): keyof typeof LedgerToken => {
  const tokens = Object.keys(LedgerToken);
  return tokens[index] as keyof typeof LedgerToken;
};

// Payload decoding functions
const decodeClaimReward = (payload: string) => {
  const [distributionId, cumulativeAmount, merkleProof] = defaultAbiCoder.decode(
    ["uint32", "uint256", "bytes32"],
    payload
  );
  return {
    distributionId,
    cumulativeAmount: BigInt(cumulativeAmount).toString(),
    merkleProof,
  };
};

const decodeCreateOrderUnstakeRequest = (payload: string) => {
  const [amount] = defaultAbiCoder.decode(["uint256"], payload);
  return { amount: BigInt(amount).toString() };
};

const decodeEsOrderUnstakeAndVest = (payload: string) => {
  const [amount] = defaultAbiCoder.decode(["uint256"], payload);
  return { amount: BigInt(amount).toString() };
};

const decodeCancelVestingRequest = (payload: string) => {
  const [requestId] = defaultAbiCoder.decode(["uint256"], payload);
  return { requestId: BigInt(requestId).toString() };
};

const decodeClaimVestingRequest = (payload: string) => {
  const [requestId] = defaultAbiCoder.decode(["uint256"], payload);
  return { requestId: BigInt(requestId).toString() };
};

const decodeRedeemValor = (payload: string) => {
  const [amount] = defaultAbiCoder.decode(["uint256"], payload);
  return { amount: BigInt(amount).toString() };
};

// Main task function
task("ledger-decode-occvaultmessage", "Decode provided data from message")
  .addParam("data", "Data to decode", undefined, types.string, true)
  .setAction(async (taskArgs, hre) => {
    const dataString = taskArgs.data;

    const dataBytes = hexToBytes(dataString);
    // console.log("Data: %s\n", bytesToHex(dataBytes));
    const dataWithoutPrefix = dataBytes.slice(76 + 32);
    // console.log("Data without prefix: %s\n", bytesToHex(dataWithoutPrefix));
    // console.log("Data length: %s", dataWithoutPrefix.length);

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

    const occVaultMessage: OCCVaultMessage = {
      chainedEventId: BigInt(decoded[0]),
      srcChainId: BigInt(decoded[1]),
      token: decoded[2],
      tokenAmount: BigInt(decoded[3]),
      sender: decoded[4],
      payloadType: decoded[5],
      payload: decoded[6],
    };

    // console.log("occVaultMessage: %s\n", occVaultMessage);

    const token = getTokenFromIndex(occVaultMessage.token);
    console.log("Decoded OCCVaultMessage:");
    console.log("chainedEventId: %s", occVaultMessage.chainedEventId.toString());
    console.log("srcChainId: %s", occVaultMessage.srcChainId.toString());
    console.log("token: %s", LedgerToken[token]);
    console.log("tokenAmount: %s", occVaultMessage.tokenAmount.toString());
    console.log("sender: %s", occVaultMessage.sender);
    console.log("payloadType: %s", PayloadType[occVaultMessage.payloadType]);

    const payload = (() => {
      switch (occVaultMessage.payloadType) {
        case PayloadType.CLAIM_REWARD:
          return decodeClaimReward(occVaultMessage.payload);
        case PayloadType.CREATE_ORDER_UNSTAKE_REQUEST:
          return decodeCreateOrderUnstakeRequest(occVaultMessage.payload);
        case PayloadType.ES_ORDER_UNSTAKE_AND_VEST:
          return decodeEsOrderUnstakeAndVest(occVaultMessage.payload);
        case PayloadType.CANCEL_VESTING_REQUEST:
          return decodeCancelVestingRequest(occVaultMessage.payload);
        case PayloadType.CLAIM_VESTING_REQUEST:
          return decodeClaimVestingRequest(occVaultMessage.payload);
        case PayloadType.REDEEM_VALOR:
          return decodeRedeemValor(occVaultMessage.payload);
        default:
          return "Unsupported payload type";
      }
    })();

    console.log("Payload:", payload);
  });

export { };
