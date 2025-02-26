// SPDX-License-Identifier: MIT
pragma solidity 0.8.22;

import {OCCLedgerMessage, EvmLedgerMessage} from "./OCCTypes.sol";
import {MessagingFee} from "@layerzerolabs/lz-evm-oapp-v2/contracts/oapp/OApp.sol";


interface ILedgerOapp {
    function ledgerOappSend(OCCLedgerMessage calldata message) external payable;
    function ledgerOappSendQuote(OCCLedgerMessage calldata message) external returns (MessagingFee memory); 
}
