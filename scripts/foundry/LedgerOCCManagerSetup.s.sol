// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import "forge-std/Script.sol";
import "./BaseScript.sol";
import "./ConfigScript.sol";
import "./Utils.sol";

import "../../contracts/lib/LedgerOCCManager.sol";

import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

contract LedgerOCCManagerSetup is BaseScript, ConfigScript {
    using StringUtils for string;

    function run() external {

        string memory env = vm.envString("FS_LedgerOCCManagerSetup_env");
        string memory network;
        if (env.equal("production")) {
            network = "orderly";
        } else {
            network = "orderlysepolia";
        }

        DeployData memory ledgerOcc = readLedger(env, "ledger_occ_manager");
        DeployData memory ledger = readLedger(env, "ledger");

        address lzEndpoint = getLzV2Endpoint(network);

        console.log("[LedgerOCCManagerSetup]env: ", env);
        console.log("[LedgerOCCManagerSetup]network: ", network);
        console.log("[LedgerOCCManagerSetup]ledgerOccAddress: ", ledgerOcc.proxy);
        console.log("[LedgerOCCManagerSetup]ledgerAddress: ", ledger.proxy);

        LedgerOCCManager ledgerOCCManager = LedgerOCCManager(payable(ledgerOcc.proxy));

        vmSelectRpcAndBroadcast(network);

        ledgerOCCManager.setLzEndpoint(lzEndpoint);
        ledgerOCCManager.setLedgerAddr(ledger.proxy);
        ledgerOCCManager.setMyChainId(getChainId(network));

        vm.stopBroadcast();
    }
}
