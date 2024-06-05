// SPDX-License-Identifier: MIT
pragma solidity ^0.8.18;

import "forge-std/Script.sol";
import "./Utils.sol";

contract BaseScript is Script {
    using StringUtils for string;

    function vmSelectRpcAndBroadcast(string memory network) internal {
        string memory rpcUrl = getRpcUrl(network);
        uint256 pk = getPrivateKey(network);
        vm.createSelectFork(rpcUrl); 
        vm.startBroadcast(pk);
    }

    function vmSelectRpc(string memory network) internal {
        string memory rpcUrl = getRpcUrl(network);
        vm.createSelectFork(rpcUrl); 
    }

    function getRpcUrl(string memory network) internal view returns (string memory) {
        return vm.envString(string("RPC_URL_").concat(network.toUpperCase()));
    }

    function getPrivateKey(string memory network) internal view returns (uint256) {
        return vm.envUint(network.toUpperCase().concat("_PRIVATE_KEY"));
    }

    function getLzEndpoint(string memory network) internal view returns (address) {
        return vm.envAddress(network.toUpperCase().concat("_ENDPOINT"));
    }

    function getLzV2Endpoint(string memory network) internal view returns (address) {
        return vm.envAddress(network.toUpperCase().concat("_V2_ENDPOINT"));
    }

    function getChainId(string memory network) internal view returns (uint256) {
        return vm.envUint(network.toUpperCase().concat("_CHAIN_ID"));
    }

    function getLzChainId(string memory network) internal view returns (uint16) {
        return uint16(vm.envUint(network.toUpperCase().concat("_LZ_CHAIN_ID")));
    }

    function getLzEid(string memory network) internal view returns (uint32) {
        return uint32(vm.envUint(network.toUpperCase().concat("_LZ_EID")));
    }

    function getOftAddress(string memory network) internal view returns (address) {
        return vm.envAddress(network.toUpperCase().concat("_OFT_ADDRESS"));
    }

    function getUsdcAddress(string memory network) internal view returns (address) {
        return vm.envAddress(network.toUpperCase().concat("_USDC_ADDRESS"));
    }

}
