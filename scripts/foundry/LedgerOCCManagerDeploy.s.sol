// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import "forge-std/Script.sol";
import "./BaseScript.sol";
import "./ConfigScript.sol";

import "../../contracts/lib/LedgerOCCManager.sol";

import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

contract LedgerOCCManagerDeploy is BaseScript, ConfigScript {

    function run() external {
        string memory env = vm.envString("FS_LedgerOCCManagerDeploy_env");
        string memory network = vm.envString("FS_LedgerOCCManagerDeploy_network");
        bool broadcast = vm.envBool("FS_LedgerOCCManagerDeploy_broadcast");

        console.log("[LedgerOCCManagerDeploy]env: ", env);
        console.log("[LedgerOCCManagerDeploy]network: ", network);

        address oftAddress = readOFT(env, network);

        vmSelectRpcAndBroadcast(network);

        LedgerOCCManager ledgerOCCManager = new LedgerOCCManager();
        bytes memory data = abi.encodeWithSelector(LedgerOCCManager.initialize.selector, oftAddress, vm.addr(getPrivateKey(network)));
        address proxy = address(new ERC1967Proxy(address(ledgerOCCManager), data));

        vm.stopBroadcast();

        if(broadcast) {
            DeployData memory deployData = DeployData({
                impl: address(ledgerOCCManager),
                proxy: proxy
            });

            writeLedger(env, "ledger_occ_manager", deployData);
        }
    }
}
