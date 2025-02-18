// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import "forge-std/Script.sol";
import "./BaseScript.sol";
import "./ConfigScript.sol";

import "../../contracts/LedgerOapp.sol";

import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

contract UpgradeLedgerOApp is BaseScript, ConfigScript {

    function run() external {

        string memory network = "orderlysepolia";
        string memory env = vm.envString("FS_UpgradeLedgerOApp_env");
        bool broadcast = vm.envBool("FS_UpgradeLedgerOApp_broadcast");

        DeployData memory ledgerOapp = readLedger(env, "ledger_oapp");

        console.log("[UpgradeLedgerOApp]env: ", env);
        console.log("[UpgradeLedgerOApp]network: ", network);
        console.log("[UpgradeLedgerOApp]ledgerOappAddress: ", ledgerOapp.proxy);


        vmSelectRpcAndBroadcast(network);

        LedgerOApp ledgerOApp = new LedgerOApp();
        LedgerOApp(payable(ledgerOapp.proxy)).upgradeToAndCall(address(ledgerOApp), bytes(""));

        vm.stopBroadcast();

        if (broadcast) {
            DeployData memory deployData = DeployData({
                impl: address(ledgerOApp),
                proxy: ledgerOapp.proxy
            });

            writeLedger(env, "ledger_oapp", deployData);
        }
    }
}
