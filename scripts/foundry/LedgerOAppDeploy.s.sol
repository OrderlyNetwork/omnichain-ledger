// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import "forge-std/Script.sol";
import "./BaseScript.sol";
import "./ConfigScript.sol";

import "../../contracts/LedgerOApp.sol";

import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

contract LedgerOAppDeploy is BaseScript, ConfigScript {
    function run() external {
        string memory env = vm.envString("FS_LedgerOAppDeploy_env");
        string memory network = vm.envString("FS_LedgerOAppDeploy_network");
        string memory salt = vm.envString("FS_LedgerOAppDeploy_salt");
        string memory lzEndpoint = vm.envString("ORDERLYSEPOLIA_V2_ENDPOINT");
        bool broadcast = vm.envBool("FS_LedgerOAppDeploy_broadcast");

        console.log("[LedgerOAppDeploy]env: ", env);
        console.log("[LedgerOAppDeploy]network: ", network);
        console.log("[LedgerOAppDeploy]lzEndpoint: ", lzEndpoint);

        address lzEndpointAddress = vm.parseAddress(lzEndpoint);

        vmSelectRpcAndBroadcast(network);

        LedgerOApp ledgerOApp = new LedgerOApp();
        bytes memory data = abi.encodeWithSelector(LedgerOApp.initialize.selector, lzEndpointAddress, vm.addr(getPrivateKey(network)));
        address proxy = address(new ERC1967Proxy{salt: keccak256(bytes(salt))}(address(ledgerOApp), data));

        vm.stopBroadcast();

        if (broadcast) {
            DeployData memory deployData = DeployData({impl: address(ledgerOApp), proxy: proxy});

            writeLedger(env, "ledger_oapp", deployData);
        }
    }
}
