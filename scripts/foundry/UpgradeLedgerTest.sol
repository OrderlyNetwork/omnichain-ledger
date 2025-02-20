// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import "forge-std/Script.sol";
import "./BaseScript.sol";
import "./ConfigScript.sol";

import "../../contracts/test/OmnichainLedgerTestV1.sol";

import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

contract UpgradeLedger is BaseScript, ConfigScript {
    function run() external {
        string memory network = "orderlysepolia";
        string memory env = vm.envString("FS_UpgradeLedgerTest_env");
        bool broadcast = vm.envBool("FS_UpgradeLedgerTest_broadcast");

        DeployData memory deployedLedgerTest = readLedger(env, "ledger");

        console.log("[UpgradeLedgerTest]env: ", env);
        console.log("[UpgradeLedgerTest]network: ", network);
        console.log("[UpgradeLedgerTest]ledgerAddress: ", deployedLedgerTest.proxy);

        vmSelectRpcAndBroadcast(network);

        OmnichainLedgerTestV1 ledgerTestImpl = new OmnichainLedgerTestV1();
        OmnichainLedgerTestV1(payable(deployedLedgerTest.proxy)).upgradeToAndCall(address(ledgerTestImpl), bytes(""));

        vm.stopBroadcast();

        if (broadcast) {
            DeployData memory deployData = DeployData({impl: address(ledgerTestImpl), proxy: deployedLedgerTest.proxy});

            writeLedger(env, "ledger", deployData);
        }
    }
}
