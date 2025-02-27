import { types } from "hardhat/config";
import { task } from "hardhat/config";
import { UUPSUpgradeable } from "../../types";
import { deployContract } from "../utils/deploy";

task("occ-manager-deploy-impl", "Deploy OCCManager implementation")
  .setAction(async (taskArgs, hre) => {
    if (hre.network.name !== "orderly" && hre.network.name !== "orderlySepolia" && hre.network.name !== "hardhat") {
      console.log("OCCManager deployment is only supported on orderly and orderlySepolia networks");
      return true;
    }

    const occManagerImpl = await deployContract(hre, "LedgerOCCManager", []);

    console.log("LedgerOCCManager implementation deployed to:", occManagerImpl?.address);
  });

task("occ-manager-verify-impl", "Verify OCCManager implementation")
  .addParam("occManagerImplAddress", "Address of the OCCManager implementation", undefined, types.string, false)
  .setAction(async (taskArgs, hre) => {
    try {
      const networkName = hre.network.name;
      const customChain = hre.config.etherscan.customChains.find(chain => chain.network === networkName);
      if (!customChain) {
        console.log(`No custom chain found for ${networkName}`);
        return;
      }

      const apiUrl = customChain.urls.apiURL;
      const apiKeys = hre.config.etherscan.apiKey;
      const apiKey = apiKeys[networkName as keyof typeof apiKeys];

      console.log("Verifying contract on explorer. apiUrl:", apiUrl);

      await hre.run("etherscan-verify", {
        forceLicense: true,
        license: "LGPL-3.0",
        solcInput: true,
        apiUrl: apiUrl,
        apiKey: apiKey,
        contract: "contracts/lib/LedgerOCCManager.sol:LedgerOCCManager",
        address: taskArgs.occManagerImplAddress
      });

      console.log("Verification successful");
    } catch (error) {
      console.error("Verification failed:", error);
    }
  });


task("occ-manager-upgrade-to", "Upgrade OCCManager to already deployed implementation")
  .addParam("occManagerProxyAddress", "Address of the OCCManager proxy", undefined, types.string, false)
  .addParam("occManagerImplAddress", "Address of the OCCManager implementation", undefined, types.string, false)
  .setAction(async (taskArgs, hre) => {
    const { ethers } = hre;

    if (hre.network.name !== "orderly" && hre.network.name !== "orderlySepolia" && hre.network.name !== "hardhat") {
      console.log("OCCManager deployment is only supported on orderly and orderlySepolia networks");
      return true;
    }

    console.log("occManagerProxyAddress:", taskArgs.occManagerProxyAddress);
    console.log("occManagerImplAddress:", taskArgs.occManagerImplAddress);

    const occManagerProxyContract = await ethers.getContractAt("UUPSUpgradeable", taskArgs.occManagerProxyAddress) as unknown as UUPSUpgradeable;

    await occManagerProxyContract.upgradeToAndCall(taskArgs.occManagerImplAddress, "0x", { gasLimit: 1_000_000 });

    console.log("OCCManager upgraded to:", taskArgs.occManagerImplAddress);
  });

export { };
