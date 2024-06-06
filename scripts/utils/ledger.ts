import { HardhatRuntimeEnvironment } from "hardhat/types";
import { OmnichainLedgerTestV1, OmnichainLedgerV1 } from "../../types";

export enum LedgerRoles {
  DEFAULT_ADMIN_ROLE,
  TREASURE_UPDATER_ROLE,
  ROOT_UPDATER_ROLE
}

export enum LedgerToken {
  "ORDER",
  "esORDER"
}

export function getLedgerTokenNum(token: string) {
  if (token !== "ORDER" && token !== "esORDER") {
    throw new Error("Only $ORDER token and es$ORDER (record based) are supported.");
  }
  return token === "ORDER" ? LedgerToken.ORDER : LedgerToken.esORDER;
}

export async function getLedgerContract(hre: HardhatRuntimeEnvironment, contractAddress: string, signerAddress: string, test: boolean = false) {
  return test
    ? ((await hre.ethers.getContractAtWithSignerAddress("OmnichainLedgerTestV1", contractAddress, signerAddress)) as unknown as OmnichainLedgerTestV1)
    : ((await hre.ethers.getContractAtWithSignerAddress("OmnichainLedgerV1", contractAddress, signerAddress)) as unknown as OmnichainLedgerV1);
}

export function getLedgerContractName(test: boolean = false) {
  return test ? "OmnichainLedgerTestV1" : "OmnichainLedgerV1";
}

export async function getLedgerRoleHash(hre: HardhatRuntimeEnvironment, ledger: OmnichainLedgerV1 | OmnichainLedgerTestV1, role: LedgerRoles) {
  return role === LedgerRoles.DEFAULT_ADMIN_ROLE
    ? await ledger.DEFAULT_ADMIN_ROLE()
    : role === LedgerRoles.TREASURE_UPDATER_ROLE
      ? await ledger.TREASURE_UPDATER_ROLE()
      : await ledger.ROOT_UPDATER_ROLE();
}

export function getLedgerRoleName(role: LedgerRoles) {
  return role === LedgerRoles.DEFAULT_ADMIN_ROLE
    ? "DEFAULT_ADMIN_ROLE"
    : role === LedgerRoles.TREASURE_UPDATER_ROLE
      ? "TREASURE_UPDATER_ROLE"
      : "ROOT_UPDATER_ROLE";
}

export async function ledgerGrantRole(hre: HardhatRuntimeEnvironment, contractAddress: string, role: LedgerRoles, to: string, test: boolean = false) {
  const owner = await hre.ethers.getNamedSigner("owner");
  const ledger = await getLedgerContract(hre, contractAddress, owner.address, test);

  const roleHash = await getLedgerRoleHash(hre, ledger, role);

  console.log("Granting %s to address %s", getLedgerRoleName(role), to);
  const tx = await ledger.connect(owner).grantRole(roleHash, to);
  const granted = await ledger.hasRole(roleHash, to);
  console.log(`Role granted: ${granted}`);
}

export async function ledgerRevokeRole(
  hre: HardhatRuntimeEnvironment,
  contractAddress: string,
  role: LedgerRoles,
  from: string,
  test: boolean = false
) {
  const owner = await hre.ethers.getNamedSigner("owner");
  const ledger = await getLedgerContract(hre, contractAddress, owner.address, test);

  const roleHash = await getLedgerRoleHash(hre, ledger, role);

  console.log("Revoking %s from address %s", getLedgerRoleName(role), from);
  const tx = await ledger.connect(owner).revokeRole(roleHash, from);
  const revoked = await ledger.hasRole(roleHash, from);
  console.log(`Role revoked: ${!revoked}`);
}
