// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import "forge-std/Script.sol";
import "./BaseScript.sol";
import "./ConfigScript.sol";

import "../../contracts/lib/LedgerOCCManager.sol";

import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

contract UpgradeLedgerOCCManager is BaseScript, ConfigScript {

    function run() external {

        string memory network = "orderlysepolia";
        string memory env = vm.envString("FS_UpgradeLedgerOCCManager_env");
        bool broadcast = vm.envBool("FS_UpgradeLedgerOCCManager_broadcast");

        DeployData memory ledgerOcc = readLedger(env, "ledger_occ_manager");

        console.log("[UpgradeLedgerOCCManager]env: ", env);
        console.log("[UpgradeLedgerOCCManager]network: ", network);
        console.log("[UpgradeLedgerOCCManager]ledgerOccAddress: ", ledgerOcc.proxy);


        vmSelectRpcAndBroadcast(network);

        LedgerOCCManager ledgerOCCManager = new LedgerOCCManager();
        LedgerOCCManager(payable(ledgerOcc.proxy)).upgradeToAndCall(address(ledgerOCCManager), bytes(""));

        vm.stopBroadcast();

        if (broadcast) {
            DeployData memory deployData = DeployData({
                impl: address(ledgerOCCManager),
                proxy: ledgerOcc.proxy
            });

            writeLedger(env, "ledger_occ_manager", deployData);
        }
    }
}
