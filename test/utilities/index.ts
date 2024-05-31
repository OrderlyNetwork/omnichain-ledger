import fs from "fs";
import path from "path";
import { deployments, ethers, upgrades } from "hardhat";
import { BigNumberish, ContractFactory } from "ethers";

export const BASE_TEN = 10;
export const INITIAL_SUPPLY = fullTokens(1_000_000);
export const INITIAL_SUPPLY_STR = INITIAL_SUPPLY.toString();
export const TOTAL_SUPPLY = BigInt(2) * INITIAL_SUPPLY;
export const TOTAL_SUPPLY_STR = TOTAL_SUPPLY.toString();
export const ONE_HOUR_IN_SECONDS = 60 * 60;
export const ONE_DAY_IN_SECONDS = ONE_HOUR_IN_SECONDS * 24;
export const ONE_WEEK_IN_SECONDS = ONE_DAY_IN_SECONDS * 7;
export const ONE_YEAR_IN_SECONDS = ONE_DAY_IN_SECONDS * 365;
export const HALF_YEAR_IN_SECONDS = ONE_YEAR_IN_SECONDS / 2;
export const VALOR_MAXIMUM_EMISSION = fullTokens(1_000_000_000);
export const VALOR_EMISSION_DURATION = 200 * 14 * ONE_DAY_IN_SECONDS;
export const VALOR_PER_SECOND = VALOR_MAXIMUM_EMISSION / BigInt(VALOR_EMISSION_DURATION);
export const VALOR_PER_DAY = VALOR_PER_SECOND * BigInt(ONE_DAY_IN_SECONDS);

// Defaults to e18 using amount * 10^18
export function fullTokens(amount: BigNumberish, decimals = 18): bigint {
  return BigInt(amount) * BigInt(BASE_TEN) ** BigInt(decimals);
}

export function abs(value: BigNumberish): bigint {
  return BigInt(value) >= 0 ? BigInt(value) : -BigInt(value);
}

export function closeTo(value: BigNumberish, target: BigNumberish, precision: BigNumberish): boolean {
  return abs(BigInt(value) - BigInt(target)) <= BigInt(precision);
}

export enum LedgerToken {
  ORDER,
  ESORDER
}

export async function ledgerFixture() {
  const ledgerCF = await ethers.getContractFactory("LedgerTest");
  const orderTokenOftCF = await ethers.getContractFactory("OrderTokenOFT");

  const [owner, user, updater, operator, orderCollector] = await ethers.getSigners();

  // The EndpointV2Mock contract comes from @layerzerolabs/test-devtools-evm-hardhat package
  // and its artifacts are connected as external artifacts to this project
  //
  // Unfortunately, hardhat itself does not yet provide a way of connecting external artifacts
  // so we rely on hardhat-deploy to create a ContractFactory for EndpointV2Mock
  //
  // See https://github.com/NomicFoundation/hardhat/issues/1040
  const eidA = 1;
  const EndpointV2MockArtifact = await deployments.getArtifact("EndpointV2Mock");
  const EndpointV2Mock = new ContractFactory(EndpointV2MockArtifact.abi, EndpointV2MockArtifact.bytecode, owner);
  const mockEndpointA = await EndpointV2Mock.deploy(eidA);
  const mockEndpointAAddress = await mockEndpointA.getAddress();

  const orderTokenOft = await orderTokenOftCF.deploy(owner.address, TOTAL_SUPPLY, mockEndpointAAddress);
  const orderTokenOftAddress = await orderTokenOft.getAddress();

  const ledger = await upgrades.deployProxy(
    ledgerCF,
    [owner.address, mockEndpointAAddress, orderCollector.address, orderTokenOftAddress, VALOR_PER_SECOND, VALOR_MAXIMUM_EMISSION],
    { kind: "uups" }
  );
  await ledger.connect(owner).grantRole(ledger.ROOT_UPDATER_ROLE(), updater.address);

  // console.log("owner: ", owner.address);
  // console.log("updater: ", updater.address);
  // console.log("ledger: ", ledger.address);

  return { ledger, orderTokenOft, owner, user, updater, operator };
}

type Proof = {
  leafSelfHash: string;
  neighbourHashHierarchy: string[];
  leafValue: {
    address: string;
    amount: string;
    token: string;
    extraInfo: string;
  };
};

function parseToJSON(data: string): { proofs: Proof[]; root: string } {
  const proofPattern = /proof\d+==========MerkleProofBO\((.*?)\)/g;
  const rootPattern = /root==========(\w+)/;
  const proofsData = [...data.matchAll(proofPattern)].map(match => match[1]);
  const root = rootPattern.exec(data)![1];
  const proofs: Proof[] = proofsData.map(proofData => {
    const [leafSelfHash, neighbourHashHierarchy, leafValue] = proofData.split(", ");
    const [address, amount, token, extraInfo] = leafValue.replace("MerkleLeafValueBO(", "").replace(")", "").split(", ");
    console.log("address: %s, amount: %s, token: %s, extraInfo: %s", address, amount, token, extraInfo);
    return {
      leafSelfHash: leafSelfHash.split("=")[1],
      neighbourHashHierarchy: neighbourHashHierarchy.split("=")[1].replace("[", "").replace("]", "").split(", "),
      leafValue: {
        address: address.split("=")[1],
        amount: amount.split("=")[1],
        token: token.split("=")[1],
        extraInfo: extraInfo.split("=")[1]
      }
    };
  });
  return { proofs, root };
}

export async function readFileContentAsJson(filePath: fs.PathOrFileDescriptor): Promise<any> {
  // Define the path to the file
  //   const filePath = path.join(__dirname, fileName);

  console.log("filePath: ", filePath);
  // Read the file content
  const fileContent = fs.readFileSync(filePath, "utf-8");

  // Convert the file content to JSON
  const jsonData = parseToJSON(fileContent);

  console.log(JSON.stringify(jsonData, null, 2));

  //   return jsonData;
  return jsonData;
}
