// SPDX-License-Identifier: MIT
pragma solidity 0.8.22;

import {OCCVaultMessage, OCCLedgerMessage, IOCCLedgerReceiver, IOCCSender} from "orderly-omnichain-occ/contracts/OCCInterface.sol";
import {LedgerAccessControl} from "./LedgerAccessControl.sol";

abstract contract OCCManager is IOCCLedgerReceiver, IOCCSender, LedgerAccessControl {
    address public occAdapterAddr;

    function setOccAdapterAddr(address _occAdapterAddr) external {
        occAdapterAddr = _occAdapterAddr;
    }

    /**
     * @notice Sends a message from vault to ledger chain
     * @param message The message being sent.
     */
    function vaultSendToLedger(OCCVaultMessage calldata message) external payable override {}

    /**
     * @notice estimate the Layerzero fee for sending a message from vault to ledger chain in native token
     */
    function estimateCCFeeFromVaultToLedger(OCCVaultMessage calldata) external pure override returns (uint256) {
        return 0;
    }

    /**
     * @notice Sends a message from ledger to vault
     * @param message The message being sent.
     */
    function ledgerSendToVault(OCCLedgerMessage calldata message) external payable override {}

    /**
     * @notice estimate the Layerzero fee for sending a message from ledger to vault chain in native token
     */
    function estimateCCFeeFromLedgerToVault(OCCLedgerMessage calldata) external pure returns (uint256) {
        return 0;
    }
}
