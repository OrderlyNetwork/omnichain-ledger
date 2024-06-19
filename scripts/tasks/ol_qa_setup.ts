import { task } from "hardhat/config";
import { OmnichainLedgerV1, OmnichainLedgerTestV1 } from "../../types";

enum LedgerTokens {
  ORDER,
  esORDER
}

type Distribution = {
  id: number;
  token: LedgerTokens;
  root: string;
};

const addressForAdminRole = [
  "0x6CBe925762348413fc2cfDD7bC9A8D04CB8E249e",
  "0xf7430d52cd39424536d26e74150d9e0274e0cad6",
  "0x4A5c7C5633bAF55dDD46B6B9cAF084E839BDa895",
  "0x2FA47E9a2a9d1b0A13BF84Ff38F7B54617C9614f"
];

const addressForUsdcUpdaterRole = ["0x314d042d164bbef71924f19a3913f65c0acfb94e", "0x4a5c7c5633baf55ddd46b6b9caf084e839bda895"];

async function grantRoleForAddressList(OmnichainLedgerTestV1: OmnichainLedgerTestV1, roleHash: string, addressForRole: string[]) {
  for (const address of addressForRole) {
    const hasRole = await OmnichainLedgerTestV1.hasRole(roleHash, address);
    if (hasRole) {
      console.log(`Address ${address} already has ${roleHash} role`);
      continue;
    } else {
      //   await OmnichainLedgerTestV1.grantRole(defaultAdminRole, address);
      console.log(`Granted ${roleHash} role to ${address}`);
    }
  }
}

task("ol-qa-setup", "Initial contract setup for QA environment").setAction(async (_, hre) => {
  console.log("######### Initial OmnichainLedgerTestV1 contract setup for QA environment #########");

  const { ethers } = hre;
  const deployer = await ethers.getNamedSigner("deployer");

  const OmnichainLedgerTestV1 = await ethers.getContract<OmnichainLedgerTestV1>("OmnichainLedgerTestV1");
  console.log("OmnichainLedgerTestV1:", await OmnichainLedgerTestV1.getAddress());

  const defaultAdminRole = await OmnichainLedgerTestV1.DEFAULT_ADMIN_ROLE();
  await grantRoleForAddressList(OmnichainLedgerTestV1, defaultAdminRole, addressForAdminRole);

  const usdcUpdaterRole = await OmnichainLedgerTestV1.TREASURE_UPDATER_ROLE();
  await grantRoleForAddressList(OmnichainLedgerTestV1, usdcUpdaterRole, addressForUsdcUpdaterRole);

  const distributions: Distribution[] = [
    {
      id: 0,
      token: LedgerTokens.ORDER,
      root: "0x57be9e714ef8c5d0b8fb9bc2a4c5fd3c5c360ba1349b6faf6a085669ed8bc194"
    },
    {
      id: 2,
      token: LedgerTokens.ORDER,
      root: "0xe4381082d20128e9a5aba5110f642554bb955277c31567041be8bfdc0881ca7b"
    },
    {
      id: 3,
      token: LedgerTokens.esORDER,
      root: "0x3c9d7d97b058147c55e6a577a67ac7135afd7dff2c6577521bbbab01dc420239"
    }
  ];

  const fiveMinutes = 60 * 5;
  const distributionStartTimestamp = new Date().getTime() / 1000 + fiveMinutes;

  for (const distribution of distributions) {
    const activeDistribution = await OmnichainLedgerTestV1.getDistribution(distribution.id);
    const activeDistributionTimestamp = activeDistribution[2];
    if (activeDistributionTimestamp > 0) {
      const activeDistributionRoot = activeDistribution[1];
      const proposedRoot = (await OmnichainLedgerTestV1.getProposedRoot(distribution.id))[0];
      if (activeDistributionRoot === distribution.root || proposedRoot === distribution.root) {
        console.log(`Distribution ${distribution.id} root ${distribution.root} is already active`);
        continue;
      } else {
        await OmnichainLedgerTestV1.proposeRoot(distribution.id, distribution.root, distributionStartTimestamp, "0x");
        console.log(`Proposed root ${distribution.root} for distribution ${distribution.id} with start timestamp ${distributionStartTimestamp}`);
      }
    } else {
      await OmnichainLedgerTestV1.createDistribution(distribution.id, distribution.token, distribution.root, distributionStartTimestamp, "0x");
      console.log(
        `Added distribution ${distribution.id} for token ${distribution.token} with root ${distribution.root} and start timestamp ${distributionStartTimestamp}`
      );
    }
  }
});

export {};
