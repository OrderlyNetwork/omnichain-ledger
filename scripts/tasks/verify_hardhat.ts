import { task } from "hardhat/config";
import {verifyContractByHardhat} from "../utils/deploy";

task("verify-hardhat", "Verifies deployed contracts usingg hardhat verify").setAction(async (_, hre) => {
    const deployedContracts = await hre.deployments.all();
    for (const contract of Object.keys(deployedContracts)) {
        const deployment = await hre.deployments.get(contract);
        await verifyContractByHardhat(hre, contract, deployment);
    }
});

export {};
