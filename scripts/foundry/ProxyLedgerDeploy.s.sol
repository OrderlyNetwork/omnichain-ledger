// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import "forge-std/Script.sol";
import "./BaseScript.sol";
import "./ConfigScript.sol";

import "../../contracts/ProxyLedger.sol";

import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

contract ProxyLedgerDeploy is BaseScript, ConfigScript {

    function run() external {
        string memory env = vm.envString("FS_ProxyLedgerDeploy_env");
        string memory network = vm.envString("FS_ProxyLedgerDeploy_network");
        string memory salt = vm.envString("FS_ProxyLedgerDeploy_salt");
        bool broadcast = vm.envBool("FS_ProxyLedgerDeploy_broadcast");

        console.log("[ProxyLedgerDeploy]env: ", env);
        console.log("[ProxyLedgerDeploy]network: ", network);

        address oftAddress = readOFT(env, network);
        address usdc = getUsdcAddress(network);

        vmSelectRpcAndBroadcast(network);

        ProxyLedger ledgerProxy = new ProxyLedger{salt: keccak256(bytes(salt))}();
        bytes memory data = abi.encodeWithSelector(ProxyLedger.initialize.selector, oftAddress, usdc, vm.addr(getPrivateKey(network)));
        address proxy = address(new ERC1967Proxy{salt: keccak256(bytes(salt))}(address(ledgerProxy), bytes("")));

        // run initialize
        ProxyLedger(payable(proxy)).initialize(oftAddress, usdc, vm.addr(getPrivateKey(network)));

        vm.stopBroadcast();

        if (broadcast) {
            DeployData memory deployData = DeployData({
                impl: address(ledgerProxy),
                proxy: proxy
            });

            writeLedgerProxy(env, "ledger_proxy", network, deployData);
        }

    }
}
