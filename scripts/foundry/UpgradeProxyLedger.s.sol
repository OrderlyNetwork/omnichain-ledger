// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import "forge-std/Script.sol";
import "./BaseScript.sol";
import "./ConfigScript.sol";

import "../../contracts/ProxyLedger.sol";

import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

contract UpgradeProxyLedger is BaseScript, ConfigScript {

    function run() external {

        string memory network = vm.envString("FS_UpgradeProxyLedger_network");
        string memory env = vm.envString("FS_UpgradeProxyLedger_env");
        bool broadcast = vm.envBool("FS_UpgradeProxyLedger_broadcast");
        
        DeployData memory ledgerProxy = readLedgerProxy(env, "ledger_proxy", network);

        console.log("[UpgradeProxyLedger]env: ", env);
        console.log("[UpgradeProxyLedger]network: ", network);
        console.log("[UpgradeProxyLedger]ledgerProxyAddress: ", ledgerProxy.proxy);

        vmSelectRpcAndBroadcast(network);

        ProxyLedger proxyLedger = new ProxyLedger();
        ProxyLedger(payable(address(ledgerProxy.proxy))).upgradeToAndCall(address(proxyLedger), bytes(""));

        vm.stopBroadcast();

        if (broadcast) {
            DeployData memory deployData = DeployData({
                impl: address(proxyLedger),
                proxy: ledgerProxy.proxy
            });

            writeLedgerProxy(env, "ledger_proxy", network, deployData);
        }
    }
}
