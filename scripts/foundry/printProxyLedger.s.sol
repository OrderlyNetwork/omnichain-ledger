// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import "forge-std/Script.sol";
import "./BaseScript.sol";
import "./ConfigScript.sol";

import "../../contracts/ProxyLedger.sol";

import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

contract PrintProxyLedger is BaseScript, ConfigScript {

    function run() external {

        string memory network = vm.envString("FS_printProxyLedger_network");
        string memory env = vm.envString("FS_printProxyLedger_env");
        
        string memory ledgerNetwork = "orderlysepolia";

        DeployData memory ledgerOcc = readLedger(env, "ledger_occ_manager");
        DeployData memory ledgerProxy = readLedgerProxy(env, "ledger_proxy", network);

        address lzEndpoint = getLzV2Endpoint(network);

        console.log("[printProxyLedger]env: ", env);
        console.log("[printProxyLedger]network: ", network);
        console.log("[printProxyLedger]ledgerOccAddress: ", ledgerOcc.proxy);
        console.log("[printProxyLedger]ledgerProxyAddress: ", ledgerProxy.proxy);

        ProxyLedger proxyLedger =  ProxyLedger(payable(ledgerProxy.proxy));

        vmSelectRpcAndBroadcast(network);

        console.log("[printProxyLedger]usdc address: ", proxyLedger.usdcAddr());
        console.log("[printProxyLedger]order token address: ", proxyLedger.orderTokenOft());
        console.log("[printProxyLedger]lzEndpoint: ", proxyLedger.lzEndpoint());
        console.log("[printProxyLedger]myChainId: ", proxyLedger.myChainId());
        console.log("[printProxyLedger]ledgerChainId: ", proxyLedger.ledgerChainId());
        console.log("[printProxyLedger]ledgerAddr: ", proxyLedger.ledgerAddr());
        console.log("[printProxyLedger]chainId2Eid: ", proxyLedger.chainId2Eid(getChainId(ledgerNetwork)));

        vm.stopBroadcast();
    }
}
