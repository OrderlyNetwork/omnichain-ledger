// SPDX-License-Identifier: MIT
pragma solidity 0.8.22;

import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import {LedgerSignedTypes} from "./LedgerTypes.sol";

/**
 * @title Signature library
 * @author Orderly Network
 * @notice Check signatures for messages
 */
library Signature {
    error InvalidSignature();

    function verify(bytes32 hash, bytes32 r, bytes32 s, uint8 v, address signer) internal pure {
        if (ECDSA.recover(hash, v, r, s) != signer) revert InvalidSignature();
    }

    function verifyUintValueSignature(LedgerSignedTypes.UintValueData memory data, address signer) internal pure {
        verify(MessageHashUtils.toEthSignedMessageHash(keccak256(abi.encode(data.value))), data.r, data.s, data.v, signer);
    }
}
