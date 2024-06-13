// SPDX-License-Identifier: MIT
pragma solidity 0.8.22;

// project imports
import {LedgerAccessControl} from "./LedgerAccessControl.sol";
import {OCCAdapterDatalayout} from "./OCCAdapterDatalayout.sol";
import {OCCVaultMessage, OCCLedgerMessage, LedgerToken} from "./OCCTypes.sol";

// oz imports
import {IERC20, SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

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
contract LedgerOCCManager is Initializable, LedgerAccessControl, OCCAdapterDatalayout, UUPSUpgradeable {
    using OptionsBuilder for bytes;
    using OFTComposeMsgCodec for bytes;
    using SafeERC20 for IERC20;

    /// @dev ledger address
    address public ledgerAddr;

    /// @dev chain id to proxy ledger address mapping
    mapping(uint256 => address) public chainId2ProxyLedgerAddr;

    /// @dev Address, that will collect unvested $ORDER when user prematurely withdraws
    address public orderCollector;

    /// @dev modifier that only allow ledger to call
    modifier onlyLedger() {
        require(msg.sender == ledgerAddr, "OnlyLedger");
        _;
    }

    // for receive native token
    receive() external payable {}

    function _authorizeUpgrade(address) internal override onlyRole(DEFAULT_ADMIN_ROLE) {}

    function initialize(address _oft, address _owner) external initializer {
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

    function setOrderCollector(address _orderCollector) external onlyRole(DEFAULT_ADMIN_ROLE) {
        orderCollector = _orderCollector;
    }

    /**
     * @notice construct OCCLedgerMessage for send through Layerzero
     * @param message The message to be sent.
     */
    function buildOCCLedgerMsg(OCCLedgerMessage memory message) internal view returns (SendParam memory sendParam) {
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

        uint256 amount = message.token == LedgerToken.ORDER ? message.tokenAmount : 0;

        bytes memory options = OptionsBuilder.newOptions().addExecutorLzReceiveOption(_oftGas, 0).addExecutorLzComposeOption(0, _dstGas, 0);
        sendParam = SendParam({
            dstEid: chainId2Eid[message.dstChainId],
            to: bytes32(uint256(uint160(chainId2ProxyLedgerAddr[message.dstChainId]))),
            amountLD: amount,
            minAmountLD: amount,
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
     * @notice Transfer unvested orders to orderCollector
     * @param amount the amount to collect
     */
    function collectUnvestedOrders(uint256 amount) external onlyLedger {
        IERC20(orderTokenOft).safeTransfer(orderCollector, amount);
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

    /**
     *
     * @param _endpoint The the caller of function lzCompose() on the relayer contract, it should be the endpoint
     * @param _localSender The composeMsg sender on local network, it should be the oft/adapter contract
     * @param _eid The eid to identify the network from where the composeMsg sent
     * @param _remoteSender The address to identiy the sender on the remote network
     */
    function _authorizeComposeMsgSender(address _endpoint, address _localSender, uint32 _eid, address _remoteSender) internal view returns (bool) {
        address remoteLedgerProxy = chainId2ProxyLedgerAddr[eid2ChainId[_eid]];
        return (lzEndpoint == _endpoint && _localSender == orderTokenOft && _remoteSender == remoteLedgerProxy);
    }

    function lzCompose(
        address _from,
        bytes32 /*_guid*/,
        bytes calldata _message,
        address /*executor*/,
        bytes calldata /*_extraData*/
    ) external payable {
        uint32 srcEid = _message.srcEid();
        address remoteSender = OFTComposeMsgCodec.bytes32ToAddress(_message.composeFrom());
        require(_authorizeComposeMsgSender(msg.sender, _from, srcEid, remoteSender), "LedgerOCCManager: composeMsg sender check failed");

        bytes memory _composeMsgContent = _message.composeMsg();

        OCCVaultMessage memory message = abi.decode(_composeMsgContent, (OCCVaultMessage));
        ILedgerReceiver(ledgerAddr).ledgerRecvFromVault(message);

        // revert("TestOnly: end of lzCompose");
    }
}
