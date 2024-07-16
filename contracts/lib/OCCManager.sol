// SPDX-License-Identifier: MIT
pragma solidity 0.8.22;

// project imports
import {LedgerAccessControl} from "./LedgerAccessControl.sol";
import {OCCAdapterDatalayout} from "./OCCAdapterDatalayout.sol";
import {OCCVaultMessage, OCCLedgerMessage} from "./OCCTypes.sol";

// oz imports
import {IERC20, SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

// lz imports
import {OApp, MessagingFee, Origin} from "@layerzerolabs/lz-evm-oapp-v2/contracts/oapp/OApp.sol";
import {MessagingReceipt} from "@layerzerolabs/lz-evm-oapp-v2/contracts/oapp/OAppSender.sol";
import {OptionsBuilder} from "@layerzerolabs/lz-evm-oapp-v2/contracts/oapp/libs/OptionsBuilder.sol";
import {IOFT, SendParam, OFTReceipt} from "@layerzerolabs/lz-evm-oapp-v2/contracts/oft/interfaces/IOFT.sol";
import {IOAppComposer} from "@layerzerolabs/lz-evm-oapp-v2/contracts/oapp/interfaces/IOAppComposer.sol";
import {OFTComposeMsgCodec} from "@layerzerolabs/lz-evm-oapp-v2/contracts/oft/libs/OFTComposeMsgCodec.sol";

/**
 * @title VaultOCCManager for handle OCC message between vault and ledger
 * @dev This contract is used to send OCC message from vault to ledger
 */
abstract contract VaultOCCManager is LedgerAccessControl, OCCAdapterDatalayout {
    using OptionsBuilder for bytes;
    using SafeERC20 for IERC20;

    /// @dev chain id of the ledger chain
    uint256 public ledgerChainId;

    /// @dev the address of the ledger
    address public ledgerAddr;

    /// @dev usdc address
    address public usdcAddr;

    /// @dev event id tracker
    uint256 public chainedEventId;

    /// @dev additional fee for backward message mapping
    mapping(uint8 => uint256) public payloadType2BackwardFee;

    /**
     * @notice set the ledger chain id and ledger address
     * @param _ledgerChainId the ledger chain id
     * @param _ledgerAddr the ledger address
     */
    function setLedgerInfo(uint256 _ledgerChainId, address _ledgerAddr) external onlyRole(DEFAULT_ADMIN_ROLE) {
        ledgerChainId = _ledgerChainId;
        ledgerAddr = _ledgerAddr;
    }

    /**
     * @notice construct OCCVaultMessage for send through Layerzero
     * @param message The message to be sent.
     */
    function buildOCCVaultMsg(OCCVaultMessage memory message) internal view returns (SendParam memory sendParam) {
        /// set the source chain id
        message.srcChainId = myChainId;

        /// build options
        uint8 _payloadType = message.payloadType;
        uint128 _dstGas = payloadType2DstGas[_payloadType];
        if (_dstGas == 0) {
            _dstGas = 2000000;
        }
        uint128 _oftGas = defaultOftGas;
        if (_oftGas == 0) {
            _oftGas = 2000000;
        }
        bytes memory options = OptionsBuilder.newOptions().addExecutorLzReceiveOption(_oftGas, 0).addExecutorLzComposeOption(0, _dstGas, 0);
        sendParam = SendParam({
            dstEid: chainId2Eid[ledgerChainId],
            to: bytes32(uint256(uint160(ledgerAddr))),
            amountLD: message.tokenAmount,
            minAmountLD: message.tokenAmount,
            extraOptions: options,
            composeMsg: abi.encode(message),
            oftCmd: bytes("")
        });
    }

    /**
     * @notice Sends a message from vault to ledger chain
     * @param message The message being sent.
     */
    function vaultSendToLedger(OCCVaultMessage memory message) internal {
        if (message.tokenAmount > 0) {
            address erc20TokenAddr = IOFT(orderTokenOft).token();
            IERC20(erc20TokenAddr).safeTransferFrom(message.sender, address(this), message.tokenAmount);

            if (IOFT(orderTokenOft).approvalRequired()) {
                IERC20(erc20TokenAddr).approve(address(orderTokenOft), message.tokenAmount);
            }
        }

        SendParam memory sendParam = buildOCCVaultMsg(message);

        /// @dev test only
        _msgPayload = sendParam.composeMsg;
        _options = sendParam.extraOptions;

        uint256 lzFee = msg.value - payloadType2BackwardFee[message.payloadType];

        MessagingFee memory msgFee = MessagingFee(lzFee, 0);

        (_msgReceipt, _oftReceipt) = IOFT(orderTokenOft).send{value: lzFee}(sendParam, msgFee, msg.sender);
        chainedEventId += 1;
    }

    /**
     * @notice estimate the Layerzero fee for sending a message from vault to ledger chain in native token
     * @param message The message being sent.
     */
    function estimateCCFeeFromVaultToLedger(OCCVaultMessage memory message) internal view returns (uint256) {
        SendParam memory sendParam = buildOCCVaultMsg(message);
        uint256 lzFee = IOFT(orderTokenOft).quoteSend(sendParam, false).nativeFee;
        uint256 backwardFee = payloadType2BackwardFee[message.payloadType];
        return lzFee + backwardFee;
    }

    /**
     * @notice set payload type to backward fee
     * @param payloadType the payload type
     * @param backwardFee the backward fee
     */
    function setPayloadType2BackwardFee(uint8 payloadType, uint256 backwardFee) external onlyRole(DEFAULT_ADMIN_ROLE) {
        payloadType2BackwardFee[payloadType] = backwardFee;
    }

    // gap for upgradeable
    uint256[48] private __gap;
}
