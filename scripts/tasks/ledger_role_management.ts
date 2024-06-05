import { types } from "hardhat/config";
import { task } from "hardhat/config";
import { LedgerRoles, ledgerGrantRole, ledgerRevokeRole } from "../utils/ledger";
import { getContractAddress } from "../utils/common";

task("ledger-transfer-ownership", "Transfre ownership to provided address")
  .addParam("contractAddress", "Address of the contract", undefined, types.string, true)
  .addParam("to", "Address to grant ownership to", undefined, types.string)
  .addParam("test", "Use OmnichainLedgerTestV1 contract or OmnichainLedgerV1", true, types.boolean, true)
  .setAction(async (taskArgs, hre) => {
    console.log(`Running on ${hre.network.name}`);
    const contractAddress = getContractAddress(taskArgs.contractAddress);

    await ledgerGrantRole(hre, contractAddress, LedgerRoles.DEFAULT_ADMIN_ROLE, taskArgs.to, taskArgs.test);
    await ledgerRevokeRole(
      hre,
      contractAddress,
      LedgerRoles.DEFAULT_ADMIN_ROLE,
      await (await hre.ethers.getNamedSigner("owner")).getAddress(),
      taskArgs.test
    );
  });

task("ledger-grant-treasure-updater-role", "Grant TREASURE_UPDATER_ROLE to provided address")
  .addParam("contractAddress", "Address of the contract", undefined, types.string, true)
  .addParam("to", "Address to grant role to", undefined, types.string)
  .addParam("test", "Use OmnichainLedgerTestV1 contract or OmnichainLedgerV1", true, types.boolean, true)
  .setAction(async (taskArgs, hre) => {
    console.log(`Running on ${hre.network.name}`);
    await ledgerGrantRole(hre, getContractAddress(taskArgs.contractAddress), LedgerRoles.TREASURE_UPDATER_ROLE, taskArgs.to, taskArgs.test);
  });

task("ledger-revoke-treasure-updater-role", "Revoke TREASURE_UPDATER_ROLE from provided address")
  .addParam("contractAddress", "Address of the contract", undefined, types.string, true)
  .addParam("from", "Address to revoke role from", undefined, types.string)
  .addParam("test", "Use OmnichainLedgerTestV1 contract or OmnichainLedgerV1", true, types.boolean, true)
  .setAction(async (taskArgs, hre) => {
    console.log(`Running on ${hre.network.name}`);
    await ledgerRevokeRole(hre, getContractAddress(taskArgs.contractAddress), LedgerRoles.TREASURE_UPDATER_ROLE, taskArgs.from, taskArgs.test);
  });

task("ledger-grant-root-updater-role", "Grant ROOT_UPDATER_ROLE to provided address")
  .addParam("contractAddress", "Address of the contract", undefined, types.string, true)
  .addParam("to", "Address to grant role to", undefined, types.string)
  .addParam("test", "Use OmnichainLedgerTestV1 contract or OmnichainLedgerV1", true, types.boolean, true)
  .setAction(async (taskArgs, hre) => {
    console.log(`Running on ${hre.network.name}`);
    await ledgerGrantRole(hre, getContractAddress(taskArgs.contractAddress), LedgerRoles.ROOT_UPDATER_ROLE, taskArgs.to, taskArgs.test);
  });

task("ledger-revoke-root-updater-role", "Revoke ROOT_UPDATER_ROLE from provided address")
  .addParam("contractAddress", "Address of the contract", undefined, types.string, true)
  .addParam("from", "Address to revoke role from", undefined, types.string)
  .addParam("test", "Use OmnichainLedgerTestV1 contract or OmnichainLedgerV1", true, types.boolean, true)
  .setAction(async (taskArgs, hre) => {
    console.log(`Running on ${hre.network.name}`);
    await ledgerRevokeRole(hre, getContractAddress(taskArgs.contractAddress), LedgerRoles.ROOT_UPDATER_ROLE, taskArgs.from, taskArgs.test);
  });

export {};
