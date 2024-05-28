// SPDX-License-Identifier: MIT
pragma solidity 0.8.22;

import {OCCLedgerMessage} from "./OCCTypes.sol";

interface ILedgerOCCManager {
    function ledgerSendToVault(OCCLedgerMessage memory message) external payable;
}