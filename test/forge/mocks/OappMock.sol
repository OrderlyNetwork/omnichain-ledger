// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import {OCCLedgerMessage} from "../../../contracts/lib/OCCTypes.sol";
import {MessagingFee} from "@layerzerolabs/lz-evm-oapp-v2/contracts/oapp/OApp.sol";

contract OappMock {
    event LedgerOappSend();
    event LedgerOappSendQuoted();

    function ledgerOappSend(OCCLedgerMessage calldata) external payable {
        emit LedgerOappSend();
    }

    function ledgerOappSendQuote(OCCLedgerMessage calldata) external returns (MessagingFee memory) {
        emit LedgerOappSendQuoted();
        return MessagingFee(1_000_000, 0);
    }
}
