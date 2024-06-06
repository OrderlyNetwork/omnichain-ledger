// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import "forge-std/Script.sol";
import "./BaseScript.sol";
import "./ConfigScript.sol";

import "../../contracts/ProxyLedger.sol";

import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

contract ProxyLedgerSetup is BaseScript, ConfigScript {

    function run() external {

        string memory network = vm.envString("FS_ProxyLedgerSetup_network");
        string memory env = vm.envString("FS_ProxyLedgerSetup_env");
        
        string memory ledgerNetwork = "orderlysepolia";

        DeployData memory ledgerOcc = readLedger(env, "ledger_occ_manager");
        DeployData memory ledgerProxy = readLedgerProxy(env, "ledger_proxy", network);

        address lzEndpoint = getLzV2Endpoint(network);

        console.log("[ProxyLedgerSetup]env: ", env);
        console.log("[ProxyLedgerSetup]network: ", network);
        console.log("[ProxyLedgerSetup]ledgerOccAddress: ", ledgerOcc.proxy);
        console.log("[ProxyLedgerSetup]ledgerProxyAddress: ", ledgerProxy.proxy);

        ProxyLedger proxyLedger =  ProxyLedger(payable(ledgerProxy.proxy));

        vmSelectRpcAndBroadcast(network);

        proxyLedger.setLzEndpoint(lzEndpoint);
        proxyLedger.setMyChainId(getChainId(network));
        proxyLedger.setLedgerInfo(getChainId(ledgerNetwork), ledgerOcc.proxy);
        proxyLedger.setChainId2Eid(getChainId(ledgerNetwork), getLzEid(ledgerNetwork));

        vm.stopBroadcast();
    }
}
