// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import "forge-std/Script.sol";
import "./BaseScript.sol";
import "./ConfigScript.sol";
import "./Utils.sol";

import "../../contracts/LedgerOApp.sol";

import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

contract LedgerOAppSetup is BaseScript, ConfigScript {
    using StringUtils for string;

    function run() external {

        string memory env = vm.envString("FS_LedgerOAppSetup_env");
        string memory network;
        if (env.equal("production")) {
            network = "orderly";
        } else {
            network = "orderlysepolia";
        }

        DeployData memory ledgerOapp = readLedger(env, "ledger_oapp");
        DeployData memory ledger_occ_manager= readLedger(env, "ledger_occ_manager");

        address lzEndpoint = getLzV2Endpoint(network);

        console.log("[LedgerOAppSetup]env: ", env);
        console.log("[LedgerOAppSetup]network: ", network);
        console.log("[LedgerOAppSetup]ledgerOappAddress: ", ledgerOapp.proxy);
        console.log("[LedgerOAppSetup]ledgerOccManagerAddress: ", ledger_occ_manager.proxy);

        LedgerOApp ledgerOApp = LedgerOApp(payable(ledgerOapp.proxy));

        vmSelectRpcAndBroadcast(network);

        

        LedgerOApp.setSolanaEid(40168);
        LedgerOApp.setChainId2Eid(901901901,40168);

        vm.stopBroadcast();
    }
}
