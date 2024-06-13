// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import "forge-std/Script.sol";
import "./BaseScript.sol";
import "./ConfigScript.sol";
import "./Utils.sol";

import "../../contracts/ProxyLedger.sol";

import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

contract UpdateOFTAddress is BaseScript, ConfigScript {

    function run() external {

        string memory network = vm.envString("FS_UpdateOFTAddress_network");
        string memory env = vm.envString("FS_UpdateOFTAddress_env");
        
        bool isProxyLedger = false;
        if (StringUtils.equal(network, "orderlysepolia")) {
            isProxyLedger = true;
        }

        address theContract = address(0);
        if (isProxyLedger) {
            theContract = readLedgerProxy(env, "ledger_proxy", network).proxy;
        } else {
            theContract = readLedger(env, "ledger_occ_manager").proxy;
        }

        address oft = readOFT(env, network);

        console.log("[UpdateOFTAddress]env: ", env);
        console.log("[UpdateOFTAddress]network: ", network);
        console.log("[UpdateOFTAddress]theContract: ", theContract);

        vmSelectRpcAndBroadcast(network);
        

        vm.stopBroadcast();
    }
}
