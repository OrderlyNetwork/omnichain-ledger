import { types } from "hardhat/config";
import { task } from "hardhat/config";
import { getLedgerContract, getLedgerTokenNum } from "../utils/ledger";
import { getContractAddress } from "../utils/common";
import { deployContract, verifyContractByHardhat } from "../utils/deploy";
import { defaultAbiCoder } from "@ethersproject/abi";
import { hexToBytes, } from "ethereum-cryptography/utils";
import { OmnichainLedgerTestV1, OmnichainLedgerV1 } from "../../types";

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
  token: LedgerToken;
  tokenAmount: bigint;
  sender: string;
  payloadType: number;
  payload: string;
}

// Function to convert uint8 to LedgerToken
const getTokenFromIndex = (index: number): LedgerToken => {
  if (index < 0 || index > 2) {
    return LedgerToken.PLACEHOLDER;
  }

  return index;
}

// Payload decoding functions
interface ClaimReward {
  distributionId: number;
  cumulativeAmount: string;
  merkleProof: string[];
}

const decodeClaimReward = (payload: string): ClaimReward => {
  const payloadBytes = hexToBytes(payload);
  const [[distributionId, cumulativeAmount, merkleProof]] = defaultAbiCoder.decode(
    ["tuple(uint32,uint256,bytes32[])"],
    payloadBytes
  ) as [[number, bigint, string[]]];

  return {
    distributionId,
    cumulativeAmount: cumulativeAmount.toString(),
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
    const dataWithoutPrefix = dataBytes.slice(76);
    // const dataWithoutPrefix = dataBytes;
    // console.log("Data without prefix: %s\n", bytesToHex(dataWithoutPrefix));
    // console.log("Data length: %s", dataWithoutPrefix.length);

    const [[chainedEventId, srcChainId, token, tokenAmount, sender, payloadType, payload]] = defaultAbiCoder.decode(
      ["tuple(uint256,uint256,uint8,uint256,bytes32,uint8,bytes)"],
      dataWithoutPrefix
    ) as [[
      bigint, // chainedEventId
      bigint, // srcChainId
      number, // token
      bigint, // tokenAmount
      string, // sender
      number, // payloadType
      string  // payload
    ]];

    const occVaultMessage: OCCVaultMessage = {
      chainedEventId,
      srcChainId,
      token: getTokenFromIndex(token),
      tokenAmount,
      sender,
      payloadType,
      payload,
    }

    // console.log("occVaultMessage: %s\n", occVaultMessage);

    console.log("Decoded OCCVaultMessage:");
    console.log("chainedEventId: %s", occVaultMessage.chainedEventId.toString());
    console.log("srcChainId: %s", occVaultMessage.srcChainId.toString());
    console.log("token: %s", LedgerToken[occVaultMessage.token]);
    console.log("tokenAmount: %s", occVaultMessage.tokenAmount.toString());
    console.log("sender: %s", occVaultMessage.sender);
    console.log("payloadType: %s", PayloadType[occVaultMessage.payloadType]);

    const decodedPayload = (() => {
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
        case PayloadType.STAKE:
          return "Stake payload (empty)";
        default:
          return "Unsupported payload type";
      }
    })();

    console.log("Payload:", decodedPayload);
  });

task("deploy-ol-impl", "Deploy and verify OmnichainLedgerV1 implementation")
  .setAction(async (taskArgs, hre) => {
    const { ethers, getNamedAccounts } = hre;

    if (hre.network.name !== "orderly" && hre.network.name !== "orderlySepolia" && hre.network.name !== "hardhat") {
      console.log("OmniChainLedgerV1 implementation deployment is only supported on orderly and orderlySepolia networks");
      return true;
    }

    const { deployer } = await getNamedAccounts();
    const owner = process.env.MULTISIG_OWNER || deployer;
    const occAdaptor = process.env.OCC_ADAPTOR_ADDRESS || ethers.ZeroAddress;
    const maximumValorEmission = process.env.MAXIMUM_VALOR_EMISSION ? BigInt(process.env.MAXIMUM_VALOR_EMISSION) :
      BigInt(1_000_000_000) * BigInt(10) ** BigInt(18);
    const ONE_DAY_IN_SECONDS = 86400;
    const valorEmissioDuration = process.env.VALOR_EMISSION_DURATION
      ? BigInt(process.env.VALOR_EMISSION_DURATION)
      : BigInt(200 * 14 * ONE_DAY_IN_SECONDS);
    const valorPerSecond = maximumValorEmission / valorEmissioDuration;
    console.log("owner:", owner);
    console.log("occAdaptor:", occAdaptor);
    console.log("maximumValorEmission:", maximumValorEmission.toString());
    console.log("valorEmissioDuration:", valorEmissioDuration.toString());
    console.log("valorPerSecond:", valorPerSecond.toString());

    console.log("Deploying OmnichainLedgerV1 impl to ", hre.network.name);

    const OmnichainLedgerV1 = await deployContract(hre, "OmnichainLedgerV1", []);
    const OmnichainLedgerV1Contract = await ethers.getContract<OmnichainLedgerV1>("OmnichainLedgerV1");
    try {
      await OmnichainLedgerV1Contract.initialize(owner, occAdaptor, valorPerSecond, maximumValorEmission);
    } catch (e) {
      console.log("OmnichainLedgerV1 already initialized, %s", e);
    }
    console.log("OmnichainLedgerV1:", OmnichainLedgerV1?.address);

  });

task("verify-ol-impl", "Verify OmnichainLedgerV1 implementation")
  .addParam("contractAddress", "Address of the contract", undefined, types.string, true)
  .setAction(async (taskArgs, hre) => {
    const { ethers, getNamedAccounts } = hre;

    if (hre.network.name !== "orderly" && hre.network.name !== "orderlySepolia" && hre.network.name !== "hardhat") {
      console.log("OmniChainLedgerV1 implementation verification is only supported on orderly and orderlySepolia networks");
      return true;
    }

    const contractAddress = getContractAddress(taskArgs.contractAddress);

    const { deployer } = await getNamedAccounts();
    const owner = process.env.MULTISIG_OWNER || deployer;
    const occAdaptor = process.env.OCC_ADAPTOR_ADDRESS || ethers.ZeroAddress;
    const maximumValorEmission = process.env.MAXIMUM_VALOR_EMISSION ? BigInt(process.env.MAXIMUM_VALOR_EMISSION) :
      BigInt(1_000_000_000) * BigInt(10) ** BigInt(18);
    const ONE_DAY_IN_SECONDS = 86400;
    const valorEmissioDuration = process.env.VALOR_EMISSION_DURATION
      ? BigInt(process.env.VALOR_EMISSION_DURATION)
      : BigInt(200 * 14 * ONE_DAY_IN_SECONDS);
    const valorPerSecond = maximumValorEmission / valorEmissioDuration;
    console.log("owner:", owner);
    console.log("occAdaptor:", occAdaptor);
    console.log("maximumValorEmission:", maximumValorEmission.toString());
    console.log("valorEmissioDuration:", valorEmissioDuration.toString());
    console.log("valorPerSecond:", valorPerSecond.toString());

    console.log("Verifying OmnichainLedgerV1 impl on ", hre.network.name);

    const OmnichainLedgerV1Contracts = await hre.deployments.getDeploymentsFromAddress(contractAddress);
    console.log("OmnichainLedgerV1Contracts:", OmnichainLedgerV1Contracts);
    console.log("Verifying OmnichainLedgerV1 impl at ", OmnichainLedgerV1Contracts[0].address);
    // await verifyContractByHardhat(hre, "OmnichainLedgerV1", OmnichainLedgerV1Contracts[0]);

  });

task("deploy-ol-test-impl", "Deploy and verify OmnichainLedgerTestV1 implementation")
  .setAction(async (taskArgs, hre) => {
    const { ethers, getNamedAccounts } = hre;

    if (hre.network.name !== "orderly" && hre.network.name !== "orderlySepolia" && hre.network.name !== "hardhat") {
      console.log("OmniChainLedgerTestV1 implementation deployment is only supported on orderly and orderlySepolia networks");
      return true;
    }

    const { deployer } = await getNamedAccounts();
    const owner = process.env.MULTISIG_OWNER || deployer;
    const occAdaptor = process.env.OCC_ADAPTOR_ADDRESS || ethers.ZeroAddress;
    const maximumValorEmission = process.env.MAXIMUM_VALOR_EMISSION ? BigInt(process.env.MAXIMUM_VALOR_EMISSION) :
      BigInt(1_000_000_000) * BigInt(10) ** BigInt(18);
    const ONE_DAY_IN_SECONDS = 86400;
    const valorEmissioDuration = process.env.VALOR_EMISSION_DURATION
      ? BigInt(process.env.VALOR_EMISSION_DURATION)
      : BigInt(200 * 14 * ONE_DAY_IN_SECONDS);
    const valorPerSecond = maximumValorEmission / valorEmissioDuration;
    console.log("owner:", owner);
    console.log("occAdaptor:", occAdaptor);
    console.log("maximumValorEmission:", maximumValorEmission.toString());
    console.log("valorEmissioDuration:", valorEmissioDuration.toString());
    console.log("valorPerSecond:", valorPerSecond.toString());

    console.log("Deploying OmnichainLedgerTestV1 impl to ", hre.network.name);

    const OmnichainLedgerTestV1 = await deployContract(hre, "OmnichainLedgerTestV1", []);
    const OmnichainLedgerTestV1Contract = await ethers.getContract<OmnichainLedgerTestV1>("OmnichainLedgerTestV1");
    try {
      await OmnichainLedgerTestV1Contract.initialize(owner, occAdaptor, valorPerSecond, maximumValorEmission);
    } catch (e) {
      console.log("OmnichainLedgerTestV1 already initialized, %s", e);
    }
    console.log("OmnichainLedgerTestV1:", OmnichainLedgerTestV1?.address);

  });

export { };
