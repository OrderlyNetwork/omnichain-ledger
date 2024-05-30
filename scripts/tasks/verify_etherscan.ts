import { task } from "hardhat/config";

task("verify-etherscan", "Verifies deployed contracts using etherscan-verify").setAction(async (_, hre) => {
  const networkName = hre.network.name;
  const customChain = hre.config.etherscan.customChains.find(chain => chain.network === networkName);
  if (!customChain) {
    console.log(`No custom chain found for ${networkName}`);
    return;
  }
  const apiUrl = customChain.urls.apiURL;
  const apiKeys = hre.config.etherscan.apiKey;
  const apiKey = apiKeys.hasOwnProperty(networkName) ? apiKeys[networkName as keyof typeof apiKeys] : undefined;
  if (!apiKey) {
    console.warn(`No api key found for ${networkName}`);
    // return;
  }

  console.log("Verifying deployment on etherscan. apiUrl: ", apiUrl);

  await hre.run("etherscan-verify", {
    forceLicense: true,
    license: "LGPL-3.0",
    solcInput: true,
    apiUrl: apiUrl,
    apiKey: apiKey
  });
});

export {};
