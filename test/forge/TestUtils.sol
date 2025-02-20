// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

library TestUtils {
    // Helper function to convert bytes to bytes32
    function bytesToBytes32(bytes memory source) internal pure returns (bytes32 result) {
        if (source.length == 0) {
            return 0x0;
        }

        assembly {
            result := mload(add(source, 32))
        }
    }
}
