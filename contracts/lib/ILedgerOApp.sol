// SPDX-License-Identifier: MIT
pragma solidity 0.8.22;

import {OCCLedgerMessage, EvmLedgerMessage} from "./OCCTypes.sol";

interface ILedgerOapp {
    function ledgerOappSend(OCCLedgerMessage calldata message) external;
}
