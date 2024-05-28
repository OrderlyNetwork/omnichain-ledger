import { task } from "hardhat/config";

task("deploy-to", "Deploys and verifies contracts").setAction(async (_, hre) => {
  await hre.run("deploy");
  // await hre.run("local-verify");
  // console.log("Verifying deployment on sourcify");
  // await hre.run("sourcify");
  // await hre.run("verify-hardhat");
  // await hre.run("verify-etherscan");
});

export {};
