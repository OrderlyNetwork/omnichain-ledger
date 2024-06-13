import { set_env_var, foundry_wrapper } from "../foundry";
import * as ethers from "ethers";
import { checkArgs } from "../utils/helper";
import { addOperation, addArgvType } from "../utils/config";
import { getExplorerApiUrl, getChainId, getEtherscanApiKey, getExplorerType } from "../utils/envUtils";
import { getContract } from "../utils/getContract";
import { exec } from "shelljs";
import { compilerVersionMap } from "../const";

// current file name
const method_name = "verifyContract";

addArgvType("string", "constructorArgs")

export function verifyContractWithArgv(argv: any) {
    const required_flags = ["env", "network", "contract"];
    checkArgs(method_name, argv, required_flags);
    verifyContract(argv.env, argv.network, argv.contract, argv.proxy as boolean, argv.constructorArgs, argv.compilerVersion, argv.simulate);
}

export function verifyContract(env: string, network: string, contract: string, proxy: boolean, constructorArgs: string | undefined, compilerVeresion: string, simulate: boolean) {
    let blockscout = false;

    const explorerType = getExplorerType(network);
    const explorerApiUrl = getExplorerApiUrl(network);
    const chainId = getChainId(network);

    const contractInfo = getContract(contract, network, env, proxy);

    let cmd = "";
    const contractPath = `${contractInfo.path}:${contractInfo.name}`

    // run command
    if (explorerType === "blockscout") {
        // forge verify-contract 0xd1c426290eaf9C16dC55e9bd10b624abb827DEef contracts/LedgerCrossChainManagerUpgradeable.sol:LedgerCrossChainManagerUpgradeable --chain-id 291 --verifier-url https://explorer.orderly.networ/api\? --verifier blockscout 
        cmd = (`forge verify-contract ${contractInfo.address} ${contractPath} --chain-id ${chainId} --verifier-url ${explorerApiUrl} --verifier blockscout`);


    } else {
        const etherscanApiKey = getEtherscanApiKey(network);
        // forge verify-contract <contract-address> contracts/CrossChainRelayUpgradeable.sol:CrossChainRelayUpgradeable --chain-id 421613 --verifier-url https://api-goerli.arbiscan.io/api -e <etherscan-api-key>
        const constructorArgsFlag = constructorArgs ? `--constructor-args ${constructorArgs}` : "--constructor-args 0x";
        const compilerVersionFlag = compilerVeresion ? `--compiler-version ${compilerVersionMap[compilerVeresion as keyof typeof compilerVersionMap]}` : "";
        const defaultOptimizationFlag = "--num-of-optimizations 200";
        cmd = (`forge verify-contract ${contractInfo.address} ${contractPath} --chain-id ${chainId} --verifier-url ${explorerApiUrl} --etherscan-api-key ${etherscanApiKey}`)
    }
    console.log(cmd);
    if (!simulate) {
        exec(cmd);
    }

}

addOperation(method_name, verifyContractWithArgv);

