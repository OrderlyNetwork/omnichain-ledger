// SPDX-License-Identifier: MIT
pragma solidity 0.8.22;

// lz imports
import { MessagingReceipt } from "@layerzerolabs/lz-evm-oapp-v2/contracts/oapp/OAppSender.sol";
import { OFTReceipt } from "@layerzerolabs/lz-evm-oapp-v2/contracts/oft/interfaces/IOFT.sol";

// project imports
import { LedgerAccessControl } from "./LedgerAccessControl.sol";

contract LzTestData {
    /// @dev for lz testing purpose
    MessagingReceipt public _msgReceipt;
    OFTReceipt public _oftReceipt;
    bytes public _msgPayload;
    bytes public _options;

    function getLzSendReceipt()
        external
        view
        returns (MessagingReceipt memory, OFTReceipt memory, bytes memory, bytes memory)
    {
        return (_msgReceipt, _oftReceipt, _msgPayload, _options);
    }

}

abstract contract OCCAdapterDatalayout is LzTestData, LedgerAccessControl {
    /* ====== orderly settings ====== */

    /// @dev Chain ID of the current chain
    uint256 public myChainId;
    
    /// @dev The address of the order token Oft
    address public orderTokenOft;

    /* ====== Layerzero related settings ====== */

    /// @dev chainId2Eid is a mapping from chainId to endpoint ID
    mapping(uint256 => uint32) public chainId2Eid;

    /// @dev payloadType2Fee is a mapping from payload type to fee
    mapping(uint8 => uint128) public payloadType2DstGas;

    uint128 public defaultOftGas;

    /// @dev lzEndpoint is the address of the LayerZero endpoint
    address public lzEndpoint;

    /// @dev eid2ChainId is a mapping from endpoint ID to chain ID
    mapping(uint32 => uint256) public eid2ChainId;

    /* ====== set functions for orderly ====== */

    function setMyChainId(uint256 _myChainId) external onlyRole(DEFAULT_ADMIN_ROLE) {
        myChainId = _myChainId;
    }

    function setOrderTokenOft(address _orderTokenOft) external onlyRole(DEFAULT_ADMIN_ROLE) {
        orderTokenOft = _orderTokenOft;
    }

    /* ====== set functions for Layerzero ====== */

    function setLzEndpoint(address _lzEndpoint) external onlyRole(DEFAULT_ADMIN_ROLE) {
        lzEndpoint = _lzEndpoint;
    }

    function setChainId2Eid(uint256 chainId, uint32 eid) external onlyRole(DEFAULT_ADMIN_ROLE) {
        chainId2Eid[chainId] = eid;
        eid2ChainId[eid] = chainId;
    }

    function setPayloadType2DstGas(uint8 payloadType, uint128 dstGas) external onlyRole(DEFAULT_ADMIN_ROLE) {
        payloadType2DstGas[payloadType] = dstGas;
    }

    function setDefaultOftGas(uint128 _defaultOftGas) external onlyRole(DEFAULT_ADMIN_ROLE) {
        defaultOftGas = _defaultOftGas;
    }


    /// @dev for upgradeable gap
    uint256[50] private __gap;
}
