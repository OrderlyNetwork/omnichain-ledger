// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import "forge-std/Script.sol";
import "./BaseScript.sol";
import "./ConfigScript.sol";

import "../../contracts/lib/LedgerOCCManager.sol";

import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

contract LedgerOCCManagerSetup is BaseScript, ConfigScript {

    function run() external {

        string memory network = "orderlysepolia";
        string memory env = vm.envString("FS_LedgerOCCManagerSetup_env");

        DeployData memory ledgerOcc = readLedger(env, "ledger_occ_manager");
        DeployData memory ledger = readLedger(env, "ledger");

        console.log("[LedgerOCCManagerSetup]env: ", env);
        console.log("[LedgerOCCManagerSetup]network: ", network);
        console.log("[LedgerOCCManagerSetup]ledgerOccAddress: ", ledgerOcc.proxy);
        console.log("[LedgerOCCManagerSetup]ledgerAddress: ", ledger.proxy);

        LedgerOCCManager ledgerOCCManager = LedgerOCCManager(payable(ledgerOcc.proxy));

        vmSelectRpcAndBroadcast(network);

        ledgerOCCManager.setLedgerAddr(ledger.proxy);
        ledgerOCCManager.setMyChainId(getChainId(network));

        vm.stopBroadcast();
    }
}
