// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import {OCCLedgerMessage} from "../../../contracts/lib/OCCTypes.sol";

contract OappMock {
    event LedgerOappSend();

    function ledgerOappSend(OCCLedgerMessage calldata) external {
        emit LedgerOappSend();
    }
}
