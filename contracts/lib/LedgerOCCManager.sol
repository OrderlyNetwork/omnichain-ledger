// SPDX-License-Identifier: MIT
pragma solidity 0.8.22;

// project imports
import {LedgerAccessControl} from "./LedgerAccessControl.sol";
import {OCCAdapterDatalayout} from "./OCCAdapterDatalayout.sol";
import {OCCVaultMessage, EvmVaultMessage, OCCLedgerMessage, EvmLedgerMessage, LedgerToken} from "./OCCTypes.sol";
import {PayloadDataType} from "./LedgerTypes.sol";
import {ILedgerOapp} from "./ILedgerOApp.sol";

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
    function ledgerRecvFromVault(EvmVaultMessage memory message) external;
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

    /// @dev mapping Solana address to EVM address for Solana users
    mapping(bytes32 => address) public userSolana2EvmAddress;

    /// @dev mapping EVM address to Solana address for Solana users
    mapping(address => bytes32) public userEvm2SolanaAddress;

    uint32 public solanaEid;

    /// @dev ledger Oapp address
    address public ledgerOappAddr;

    event NewSolanaUser(bytes32 indexed solanaAddress, address indexed evmAddress);

    /// @dev modifier that only allow ledger to call
    modifier onlyLedger() {
        require(msg.sender == ledgerAddr, "OnlyLedger");
        _;
    }

    /// @dev modifier that only allow ledgerOapp to call
    modifier onlyLedgerOapp() {
        require(msg.sender == ledgerOappAddr, "OnlyLedgerOapp");
        _;
    }

    function VERSION() external pure virtual returns (string memory) {
        return "1.0.5";
    }

    // for receive native token
    receive() external payable {}

    function _authorizeUpgrade(address) internal override onlyRole(DEFAULT_ADMIN_ROLE) {}

    /* ========== prevent initialization for implementation contracts ========== */

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /* ====== initializer ====== */

    function initialize(address _oft, address _owner) external initializer {
        ledgerAccessControlInit(_owner);

        orderTokenOft = _oft;
        orderCollector = _owner;
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

    function setSolanaEid(uint32 _solanaEid) external onlyRole(DEFAULT_ADMIN_ROLE) {
        solanaEid = _solanaEid;
    }

    function setLedgerOappAddr(address _ledgerOappAddr) external onlyRole(DEFAULT_ADMIN_ROLE) {
        ledgerOappAddr = _ledgerOappAddr;
    }

    /**
     * @notice construct OCCLedgerMessage for send through Layerzero
     * @param message The message to be sent.
     */
    function buildOCCLedgerMsg(EvmLedgerMessage memory message) internal view returns (SendParam memory sendParam) {
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

        uint32 dstEid = chainId2Eid[message.dstChainId];
        uint256 amount = message.token == LedgerToken.ORDER ? message.tokenAmount : 0;

        if (dstEid == solanaEid) {
            // For Solana chain we send OFT directly to user, so we need to convert EVM address to Solana address
            // Also skip composeMsg for Solana chain
            bytes memory options = OptionsBuilder.newOptions().addExecutorLzReceiveOption(_oftGas, 0);
            bytes32 receiver = userEvm2SolanaAddress[message.receiver];
            require(receiver != bytes32(0), "LedgerOCCManager: Solana receiver address not found");

            sendParam = SendParam({
                dstEid: dstEid,
                to: receiver,
                amountLD: amount,
                minAmountLD: amount,
                extraOptions: options,
                composeMsg: bytes(""),
                oftCmd: bytes("")
            });
        } else {
            bytes memory options = OptionsBuilder.newOptions().addExecutorLzReceiveOption(_oftGas, 0).addExecutorLzComposeOption(0, _dstGas, 0);

            // Ledger operates by EvmVaultMessage, but LZ operates by OCCVaultMessage, so we need to convert it
            OCCLedgerMessage memory occMessage = OCCLedgerMessage({
                dstChainId: message.dstChainId,
                token: message.token,
                tokenAmount: message.tokenAmount,
                receiver: OFTComposeMsgCodec.addressToBytes32(message.receiver),
                payloadType: message.payloadType,
                payload: message.payload
            });

            sendParam = SendParam({
                dstEid: dstEid,
                to: bytes32(uint256(uint160(chainId2ProxyLedgerAddr[message.dstChainId]))),
                amountLD: amount,
                minAmountLD: amount,
                extraOptions: options,
                composeMsg: abi.encode(occMessage),
                oftCmd: bytes("")
            });
        }
    }

    /**
     * @notice Sends a message from ledger to vault
     * @param message The message being sent.
     */
    function ledgerSendToVault(EvmLedgerMessage memory message) external payable onlyLedger {
        // Here we have special case for Solana chain when ClaimUsdcRevenueBackward payload is sent
        if (chainId2Eid[message.dstChainId] == solanaEid && message.payloadType == uint8(PayloadDataType.ClaimUsdcRevenueBackward)) {
            bytes32 receiver = userEvm2SolanaAddress[message.receiver];
            require(receiver != bytes32(0), "LedgerOCCManager: Solana receiver address not found");

            OCCLedgerMessage memory occMessage = OCCLedgerMessage({
                dstChainId: message.dstChainId,
                token: message.token,
                tokenAmount: message.tokenAmount,
                receiver: receiver,
                payloadType: message.payloadType,
                payload: message.payload
            });
            ILedgerOapp(ledgerOappAddr).ledgerOappSend(occMessage);
        } else {
            SendParam memory sendParam = buildOCCLedgerMsg(message);
            uint256 fee = estimateCCFeeFromLedgerToVault(sendParam);

            MessagingFee memory msgFee = MessagingFee(fee, 0);

            /// @dev test only
            _msgPayload = sendParam.composeMsg;
            _options = sendParam.extraOptions;

            (_msgReceipt, _oftReceipt) = IOFT(orderTokenOft).send{value: fee}(sendParam, msgFee, address(this));
        }
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
    function estimateCCFeeFromLedgerToVault(EvmLedgerMessage memory message) internal view returns (uint256) {
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
        bytes memory _composeMsgContent = _message.composeMsg();
        OCCVaultMessage memory occVaultMessage = abi.decode(_composeMsgContent, (OCCVaultMessage));

        if (srcEid == solanaEid) {
            bytes32 remoteSender = _message.composeFrom();
            require(remoteSender == occVaultMessage.sender, "LedgerOCCManager: composeMsg sender check failed");

            uint256 amountLD = _message.amountLD();
            if (PayloadDataType(occVaultMessage.payloadType) == PayloadDataType.Stake) {
                require(amountLD == occVaultMessage.tokenAmount, "LedgerOCCManager: composeMsg stake amount check failed");
                require(occVaultMessage.token == LedgerToken.ORDER, "LedgerOCCManager: only ORDER token can be staked");
            } else {
                require(amountLD == 0, "LedgerOCCManager: composeMsg amount should be zero for this payload");
                require(
                    occVaultMessage.token == LedgerToken.PLACEHOLDER,
                    "LedgerOCCManager: composeMsg token should be PLACEHOLDER for this payload"
                );
            }
        } else {
            address remoteSender = OFTComposeMsgCodec.bytes32ToAddress(_message.composeFrom());
            require(_authorizeComposeMsgSender(msg.sender, _from, srcEid, remoteSender), "LedgerOCCManager: composeMsg sender check failed");
        }

        // In case of Solana user, we need to convert Solana address to EVM address and store it
        address sender = srcEid == solanaEid
            ? getEvmBySolanaAddress(occVaultMessage.sender)
            : OFTComposeMsgCodec.bytes32ToAddress(occVaultMessage.sender);

        // We receive OCCVaultMessage from LZ and need to convert it to EvmVaultMessage for internal ledger use
        EvmVaultMessage memory evmVaultMessage = EvmVaultMessage({
            chainedEventId: occVaultMessage.chainedEventId,
            srcChainId: occVaultMessage.srcChainId,
            token: occVaultMessage.token,
            tokenAmount: occVaultMessage.tokenAmount,
            sender: sender,
            payloadType: occVaultMessage.payloadType,
            payload: occVaultMessage.payload
        });

        ILedgerReceiver(ledgerAddr).ledgerRecvFromVault(evmVaultMessage);

        // revert("TestOnly: end of lzCompose");
    }

    function ledgerOappReceive(OCCVaultMessage calldata _message) external onlyLedgerOapp {
        // For now only ClaimReward payload is supported
        require(_message.payloadType == uint8(PayloadDataType.ClaimReward), "LedgerOCCManager: unsupported payload type");

        // Now we can receive message here only from Solana, so,
        // we need to convert Solana address to EVM address and store it
        address sender = getEvmBySolanaAddress(_message.sender);

        // We receive OCCVaultMessage from LZ and need to convert it to EvmVaultMessage for internal ledger use
        EvmVaultMessage memory evmVaultMessage = EvmVaultMessage({
            chainedEventId: _message.chainedEventId,
            srcChainId: _message.srcChainId,
            token: _message.token,
            tokenAmount: _message.tokenAmount,
            sender: sender,
            payloadType: _message.payloadType,
            payload: _message.payload
        });

        ILedgerReceiver(ledgerAddr).ledgerRecvFromVault(evmVaultMessage);
    }

    /**
     * @notice withdraw eth to
     * @param to the address to withdraw
     */
    function withdrawTo(address to) external onlyRole(DEFAULT_ADMIN_ROLE) {
        payable(to).transfer(address(this).balance);
    }

    /**
     * @notice withdraw all order
     * @param to the address to withdraw
     */
    function withdrawOrderTo(address to) external onlyRole(DEFAULT_ADMIN_ROLE) {
        IERC20(orderTokenOft).safeTransfer(to, IERC20(orderTokenOft).balanceOf(address(this)));
    }

    /**
     * @notice convert Solana address to correspondent EVM address
     * @param solanaAddress the solana address
     */
    function getEvmBySolanaAddress(bytes32 solanaAddress) internal returns (address evmAddress) {
        evmAddress = userSolana2EvmAddress[solanaAddress];
        if (evmAddress == address(0)) {
            evmAddress = calculateUserSolana2EvmAddress(solanaAddress);
            userSolana2EvmAddress[solanaAddress] = evmAddress;
            userEvm2SolanaAddress[evmAddress] = solanaAddress;

            emit NewSolanaUser(solanaAddress, evmAddress);
        }
    }

    function calculateUserSolana2EvmAddress(bytes32 solanaAddress) public pure returns (address evmAddress) {
        evmAddress = OFTComposeMsgCodec.bytes32ToAddress(keccak256(abi.encode(solanaAddress)));
    }

    /// gap for upgradeable
    uint256[46] private __gap;
}
