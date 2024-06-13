import { project_deploy_json } from "../const"

export const CONTRACT_META: {[key: string]: {path: string, name: string}} = {
    "ledger": {
        "path": "contracts/OmnichainLedgerV1.sol",
        "name": "OmnichainLedgerV1",
    },
    "ledger_occ_manager": {
        "path": "contracts/lib/LedgerOCCManager.sol",
        "name": "LedgerOCCManager",
    },
    "ledger_proxy": {
        "path": "contracts/ProxyLedger.sol",
        "name": "ProxyLedger"
    }
}

interface ContractInfo {
    path: string;
    name: string;
    address: string;
}

export function getContract(contractName: string, network: string, env: string, proxy: boolean) : ContractInfo {
    const config_json_file = project_deploy_json;

    // load json file
    const fs = require('fs');
    const json = JSON.parse(fs.readFileSync(config_json_file, 'utf8'));

    let address;

    if (contractName === "ledger_proxy") {
        address = proxy? json[env]["ledger_proxy"][network].proxy : json[env]["ledger_proxy"][network].impl;
    } else {
        address = proxy? json[env][contractName].proxy : json[env][contractName].impl;
    }

    return {
        path: CONTRACT_META[contractName].path,
        name: CONTRACT_META[contractName].name,
        address: address
    }
}