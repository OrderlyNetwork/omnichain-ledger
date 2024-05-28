// SPDX-License-Identifier: MIT
pragma solidity 0.8.22;

// project imports
import {LedgerAccessControl} from "./LedgerAccessControl.sol";
import {OCCAdapterDatalayout} from "./OCCAdapterDatalayout.sol";
import {OCCVaultMessage, OCCLedgerMessage} from "./OCCTypes.sol";

// oz imports
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

// lz imports
import {OApp, MessagingFee, Origin} from "@layerzerolabs/lz-evm-oapp-v2/contracts/oapp/OApp.sol";
import {MessagingReceipt} from "@layerzerolabs/lz-evm-oapp-v2/contracts/oapp/OAppSender.sol";
import {OptionsBuilder} from "@layerzerolabs/lz-evm-oapp-v2/contracts/oapp/libs/OptionsBuilder.sol";
import {IOFT, SendParam, OFTReceipt} from "@layerzerolabs/lz-evm-oapp-v2/contracts/oft/interfaces/IOFT.sol";
import {IOAppComposer} from "@layerzerolabs/lz-evm-oapp-v2/contracts/oapp/interfaces/IOAppComposer.sol";
import {OFTComposeMsgCodec} from "@layerzerolabs/lz-evm-oapp-v2/contracts/oft/libs/OFTComposeMsgCodec.sol";

interface ILedgerReceiver {
    function ledgerRecvFromVault(OCCVaultMessage memory message) external;
}

/**
 * @title LedgerOCCManager for handle OCC message between ledger and vault
 * @dev This contract is used to send OCC message from ledger to vault
 */
contract LedgerOCCManager is LedgerAccessControl, OCCAdapterDatalayout {
    using OptionsBuilder for bytes;

    /// @dev ledger address
    address public ledgerAddr;

    /// @dev chain id to proxy ledger address mapping
    mapping(uint256 => address) public chainId2ProxyLedgerAddr;

    /// @dev modifier that only allow ledger to call
    modifier onlyLedger() {
        require(msg.sender == ledgerAddr, "OnlyLedger");
        _;
    }

    function initilize(address _oft, address _owner) external initializer {
        ledgerAccessControlInit(_owner);

        orderTokenOft = _oft;
    }

    /// @notice set the chain id to proxy ledger address mapping
    /// @param chainId the chain id
    /// @param _proxyLedgerAddr the proxy ledger address
    function setChainId2ProxyLedgerAddr(uint256 chainId, address _proxyLedgerAddr) external onlyRole(DEFAULT_ADMIN_ROLE) {
        chainId2ProxyLedgerAddr[chainId] = _proxyLedgerAddr;
    }

    function setLedgerAddr(address _ledgerAddr) external onlyRole(DEFAULT_ADMIN_ROLE) {
        ledgerAddr = _ledgerAddr;
    }

    /**
     * @notice construct OCCLedgerMessage for send through Layerzero
     * @param message The message to be sent.
     */
    function buildOCCLedgerMsg(OCCLedgerMessage memory message)
        internal
        view
        returns (SendParam memory sendParam)
    {

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
        bytes memory options =
            OptionsBuilder.newOptions().addExecutorLzReceiveOption(_oftGas, 0).addExecutorLzComposeOption(0, _dstGas, 0);
        sendParam = SendParam({
            dstEid: chainId2Eid[message.dstChainId],
            to: bytes32(uint256(uint160(chainId2ProxyLedgerAddr[message.dstChainId]))),
            amountLD: message.tokenAmount,
            minAmountLD: message.tokenAmount,
            extraOptions: options,
            composeMsg: abi.encode(message),
            oftCmd: bytes("")
        });

    }

    /**
     * @notice Sends a message from ledger to vault
     * @param message The message being sent.
     */
    function ledgerSendToVault(OCCLedgerMessage memory message) external payable onlyLedger {

        SendParam memory sendParam = buildOCCLedgerMsg(message);
        uint256 fee = estimateCCFeeFromLedgerToVault(sendParam);

        MessagingFee memory msgFee = MessagingFee(fee, 0);

        /// @dev test only
        _msgPayload = sendParam.composeMsg;
        _options = sendParam.extraOptions;

        (_msgReceipt, _oftReceipt) = IOFT(orderTokenOft).send{value: fee}(sendParam, msgFee, address(this));
    }

    /**
     * @notice estimate the Layerzero fee for sending a message from ledger to vault chain in native token
     * @param message The message being sent.
     */
    function estimateCCFeeFromLedgerToVault(OCCLedgerMessage memory message) internal view returns (uint256) {
        SendParam memory sendParam = buildOCCLedgerMsg(message);
        return IOFT(orderTokenOft).quoteSend(sendParam, false).nativeFee;
    }

    /**
     * @notice estimate the Layerzero fee for sending a message from ledger to vault chain in native token
     * @param sendParam The send param
     */
    function estimateCCFeeFromLedgerToVault(SendParam memory sendParam) internal view returns (uint256) {
        return IOFT(orderTokenOft).quoteSend(sendParam, false).nativeFee;
    }


    function lzCompose(address, bytes32, bytes calldata _message, address, bytes calldata /*_extraData*/) external payable {
        bytes memory _composeMsgContent = OFTComposeMsgCodec.composeMsg(_message);

        OCCVaultMessage memory message = abi.decode(_composeMsgContent, (OCCVaultMessage));
        ILedgerReceiver(ledgerAddr).ledgerRecvFromVault(message);

        // revert("TestOnly: end of lzCompose");
    }
}

