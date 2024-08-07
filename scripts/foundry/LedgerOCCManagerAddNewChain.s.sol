// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import "forge-std/Script.sol";
import "./BaseScript.sol";
import "./ConfigScript.sol";
import "./Utils.sol";

import "../../contracts/lib/LedgerOCCManager.sol";

import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

contract LedgerOCCManagerAddNewChain is BaseScript, ConfigScript {
    using StringUtils for string;

    function run() external {

        string memory env = vm.envString("FS_LedgerOCCManagerAddNewChain_env");
        string memory newNetwork = vm.envString("FS_LedgerOCCManagerAddNewChain_newNetwork");
        string memory network;
        if (env.equal("production")) {
            network = "orderly";
        } else {
            network = "orderlysepolia";
        }

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
