// SPDX-License-Identifier: MIT
pragma solidity ^0.8.18;

import "forge-std/Script.sol";
import "./Utils.sol";

struct DeployData {
    address impl;
    address proxy;
}

contract ConfigScript is Script {
    using StringUtils for string;

    string constant LEDGER_CONFIG_PATH = "config/ledger.json";
    string constant OFT_CONFIG_PATH = "config/oft.json";

    function readOFT(string memory env, string memory network) internal view returns (address) {
        string memory filedata = vm.readFile(OFT_CONFIG_PATH);
        return vm.parseJsonAddress(filedata, StringUtils.formJsonKey(env, network));
    }

    function readLedger(string memory env, string memory role) internal view returns (DeployData memory) {
        string memory filedata = vm.readFile(LEDGER_CONFIG_PATH);
        bytes memory jsondata = vm.parseJson(filedata, StringUtils.formJsonKey(env, role));
        return abi.decode(jsondata, (DeployData));
    }

    function readLedgerProxy(string memory env, string memory role, string memory network) internal view returns (DeployData memory) {
        string memory filedata = vm.readFile(LEDGER_CONFIG_PATH);
        bytes memory jsondata = vm.parseJson(filedata, StringUtils.formJsonKey(env, role, network));
        return abi.decode(jsondata, (DeployData));
    }

    function writeLedger(string memory env, string memory role, DeployData memory data) internal {
        string memory obj = "ledger_deploy_data"; 
        vm.serializeAddress(obj, "impl", data.impl);
        string memory output = vm.serializeAddress(obj, "proxy", data.proxy);

        vm.writeJson(output, LEDGER_CONFIG_PATH, StringUtils.formJsonKey(env, role));
    }

    function writeLedgerProxy(string memory env, string memory role, string memory network, DeployData memory data) internal {
        string memory obj = "ledger_proxy_deploy_data"; 
        vm.serializeAddress(obj, "impl", data.impl);
        string memory output = vm.serializeAddress(obj, "proxy", data.proxy);

        vm.writeJson(output, LEDGER_CONFIG_PATH, StringUtils.formJsonKey(env, role, network));
    }
}