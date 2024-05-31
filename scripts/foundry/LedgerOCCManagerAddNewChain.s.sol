// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import "forge-std/Script.sol";
import "./BaseScript.sol";
import "./ConfigScript.sol";

import "../../contracts/lib/LedgerOCCManager.sol";

import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

contract LedgerOCCManagerAddNewChain is BaseScript, ConfigScript {

    function run() external {

        string memory network = "orderlysepolia";
        string memory env = vm.envString("FS_LedgerOCCManagerAddNewChain_env");
        string memory newNetwork = vm.envString("FS_LedgerOCCManagerAddNewChain_newNetwork");

        DeployData memory ledgerOcc = readLedger(env, "ledger_occ_manager");
        DeployData memory ledgerProxy = readLedgerProxy(env, "ledger_proxy", newNetwork);

        console.log("[LedgerOCCManagerAddNewChain]env: ", env);
        console.log("[LedgerOCCManagerAddNewChain]network: ", network);
        console.log("[LedgerOCCManagerAddNewChain]ledgerOccAddress: ", ledgerOcc.proxy);
        console.log("[LedgerOCCManagerAddNewChain]ledgerAddress: ", ledgerProxy.proxy);

        LedgerOCCManager ledgerOCCManager = LedgerOCCManager(payable(ledgerOcc.proxy));

        vmSelectRpcAndBroadcast(network);

        ledgerOCCManager.setChainId2Eid(getChainId(newNetwork), getLzEid(newNetwork));
        ledgerOCCManager.setChainId2ProxyLedgerAddr(getChainId(newNetwork), ledgerProxy.proxy);

        vm.stopBroadcast();
    }
}
