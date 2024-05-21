// SPDX-License-Identifier: MIT
pragma solidity 0.8.22;

// oz imports
import { Initializable } from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import { OwnableUpgradeable } from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import { UUPSUpgradeable } from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

import { OCCVaultMessage, OCCLedgerMessage, IOCCSender, IOCCVaultReceiver, LedgerToken } from "orderly-omnichain-occ/contracts/OCCInterface.sol";

import { PayloadDataType } from "./lib/LedgerTypes.sol";

/**
 * @title ProxyLedger for proxy requests to ledger
 * @dev proxy staking, claiming and other ledger operations from vault chains, like Ethereum, Arbitrum, etc.
 */
contract ProxyLedger is IOCCVaultReceiver, Initializable, OwnableUpgradeable, UUPSUpgradeable {

    /// @notice the address of the OCCAdapter contract
    address public occAdapterAddr;

    /// @notice constructor to set the OCCAdapter address
    constructor() {
        // _disableInitializers();
    }

    /* ====== initializer ====== */

    /// @notice initialize the contract
    function initialize(address _occAdapterAddr, address _owner) external initializer {
        __Ownable_init(_owner);
        occAdapterAddr = _occAdapterAddr;
    }

    /* ====== upgradeable ====== */

    /// @notice upgrade the contract
    function _authorizeUpgrade(address) internal override onlyOwner {}

    /* ====== staking ====== */

    /**
     * @notice construct OCCVaultMessage for stake operation
     * @param amount the amount to stake
     * @param sender the sender of the stake
     * @param isEsOrder whether the stake is for esOrder
     */
    function buildStakeMessage(uint256 amount, address sender, bool isEsOrder) internal pure returns (OCCVaultMessage memory) {

        return OCCVaultMessage({
            srcChainId: 0,
            token: isEsOrder ? LedgerToken.ESORDER : LedgerToken.ORDER,
            tokenAmount: amount,
            sender: sender,
            payloadType: uint8(PayloadDataType.Stake),
            payload: bytes("")
        });
    }

    /**
     * @notice stake the amount to the ledger
     * @param amount the amount to stake
     * @param sender the sender of the stake
     * @param isEsOrder whether the stake is for esOrder
     */
    function stake(uint256 amount, address sender, bool isEsOrder) external payable {
        OCCVaultMessage memory message = buildStakeMessage(amount, sender, isEsOrder);
        IOCCSender(occAdapterAddr).vaultSendToLedger{value: msg.value}(message);
    }


    /**
     * @notice estimate the Layerzero fee for sending a message from vault to ledger chain in native token
     * @param amount the amount to stake
     * @param sender the sender of the stake
     * @param isEsOrder whether the stake is for esOrder
     */
    function qouteStake(uint256 amount, address sender, bool isEsOrder) external view returns (uint256) {
        OCCVaultMessage memory message = buildStakeMessage(amount, sender, isEsOrder);
        return IOCCSender(occAdapterAddr).estimateCCFeeFromVaultToLedger(message);
    }

    function vaultRecvFromLedger(OCCLedgerMessage calldata message) external override {
        /// TODO
    }

    /// @notice fallback to receive
    receive() external payable {}
}