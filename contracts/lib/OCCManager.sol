// SPDX-License-Identifier: MIT
pragma solidity 0.8.22;

import {OCCVaultMessage, OCCLedgerMessage, IOCCLedgerReceiver} from "orderly-omnichain-occ/contracts/OCCInterface.sol";

abstract contract OCCManager is IOCCLedgerReceiver {}
