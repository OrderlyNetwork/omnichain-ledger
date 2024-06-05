// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import "forge-std/Script.sol";
import "./BaseScript.sol";
import "./ConfigScript.sol";

import "../../contracts/lib/LedgerOCCManager.sol";

import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

contract CallRandomFunction is BaseScript, ConfigScript {

    function run() external {

        address addr = vm.envAddress("FS_CallRandomFunction_address");
        bytes memory rawData = vm.envBytes("FS_CallRandomFunction_calldata");
        string memory network = vm.envString("FS_CallRandomFunction_network");
        uint256 value = vm.envUint("FS_CallRandomFunction_value");

        vmSelectRpcAndBroadcast(network);

        addr.call{value: value}(rawData);

        vm.stopBroadcast();
    }
}
