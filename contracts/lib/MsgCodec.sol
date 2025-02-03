// SPDX-License-Identifier: MIT
pragma solidity 0.8.22;

import {SolanaVaultMessage, SolanaLedgerMessage, LedgerToken} from "./OCCTypes.sol";

library SolanaProxyMsgCodec {
    uint8 private constant TOKEN_TYPE_OFF_SET = 1;                      
    uint8 private constant SENDER_OFFSET = TOKEN_TYPE_OFF_SET + 32;      
    uint8 private constant PAYLOAD_TYPE_OFFSET = SENDER_OFFSET + 1;
    uint8 private constant PAYLOAD_OFFSET = PAYLOAD_TYPE_OFFSET;

    function tokenType(bytes calldata _message) internal pure returns (uint8) {
        return uint8(bytes1(_message[0: TOKEN_TYPE_OFF_SET]));
    }

    function sender(bytes calldata _message) internal pure returns (bytes32) {
        return bytes32(_message[TOKEN_TYPE_OFF_SET: SENDER_OFFSET]);
    }

    function payloadType(bytes calldata _message) internal pure returns (uint8) {
        return uint8(bytes1(_message[SENDER_OFFSET: PAYLOAD_OFFSET]));
    }

    function payload(bytes calldata _message) internal pure returns (bytes calldata) {
        return _message[PAYLOAD_OFFSET:];
    }

    function decodeSolanaVaultMessage(bytes calldata _message) internal pure returns (SolanaVaultMessage memory) {
        return SolanaVaultMessage({
            token: LedgerToken(tokenType(_message)),
            sender: sender(_message),
            payloadType: payloadType(_message),
            payload: payload(_message)
        });
    }
    

    
}