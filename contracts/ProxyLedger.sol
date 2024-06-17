// SPDX-License-Identifier: MIT
pragma solidity 0.8.22;

// oz imports
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

// lz imports
import {OFTComposeMsgCodec} from "@layerzerolabs/lz-evm-oapp-v2/contracts/oft/libs/OFTComposeMsgCodec.sol";
import {IOFT} from "@layerzerolabs/lz-evm-oapp-v2/contracts/oft/interfaces/IOFT.sol";

import {VaultOCCManager} from "./lib/OCCManager.sol";
import {OCCVaultMessage, OCCLedgerMessage, LedgerToken} from "./lib/OCCTypes.sol";
import {LedgerPayloadTypes, PayloadDataType} from "./lib/LedgerTypes.sol";

/**
 * @title ProxyLedger for proxy requests to ledger
 * @dev proxy staking, claiming and other ledger operations from vault chains, like Ethereum, Arbitrum, etc.
 */
contract ProxyLedger is Initializable, VaultOCCManager, UUPSUpgradeable {
    using OFTComposeMsgCodec for bytes;

    event ClaimRewardTokenTransferred(address indexed user, uint256 amount);
    event WithdrawOrderTokenTransferred(address indexed user, uint256 amount);
    event ClaimUsdcRevenueTransferred(address indexed user, uint256 amount);
    event ClaimVestingRequestTransferred(address indexed user, uint256 amount);

    /* ========== prevent initialization for implementation contracts ========== */

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /* ====== initializer ====== */

    /// @notice initialize the contract
    function initialize(address _oft, address _usdc, address _owner) external initializer {
        orderTokenOft = _oft;
        usdcAddr = _usdc;
        ledgerAccessControlInit(_owner);
    }

    /* ====== upgradeable ====== */

    /// @notice upgrade the contract
    function _authorizeUpgrade(address) internal override onlyRole(DEFAULT_ADMIN_ROLE) {}

    /* ====== Claim Reward ====== */

    /**
     * @notice construct OCCVaultMessage for claim reward operation
     * @param distributionId the distribution id
     * @param user the user to claim reward
     * @param cumulativeAmount the cumulative amount to claim
     * @param merkleProof the merkle proof
     * @param isEsOrder whether the claim is for esOrder
     */
    function buildClaimRewardMessage(
        uint32 distributionId,
        address user,
        uint256 cumulativeAmount,
        bytes32[] memory merkleProof,
        bool isEsOrder
    ) internal view returns (OCCVaultMessage memory) {
        return
            OCCVaultMessage({
                chainedEventId: chainedEventId,
                srcChainId: 0,
                token: isEsOrder ? LedgerToken.ESORDER : LedgerToken.ORDER,
                tokenAmount: 0,
                sender: user,
                payloadType: uint8(PayloadDataType.ClaimReward),
                payload: abi.encode(
                    LedgerPayloadTypes.ClaimReward({distributionId: distributionId, cumulativeAmount: cumulativeAmount, merkleProof: merkleProof})
                )
            });
    }

    /**
     * @notice claim reward from the ledger
     * @param distributionId the distribution id
     * @param cumulativeAmount the cumulative amount to claim
     * @param merkleProof the merkle proof
     * @param isEsOrder whether the claim is for esOrder
     */
    function claimReward(uint32 distributionId, uint256 cumulativeAmount, bytes32[] memory merkleProof, bool isEsOrder) external payable {
        OCCVaultMessage memory message = buildClaimRewardMessage(distributionId, msg.sender, cumulativeAmount, merkleProof, isEsOrder);
        chainedEventId += 1;
        vaultSendToLedger(message);
    }

    /**
     * @notice estimate the Layerzero fee for sending a message from vault to ledger chain in native token
     * @param distributionId the distribution id
     * @param user the user to claim reward
     * @param cumulativeAmount the cumulative amount to claim
     * @param merkleProof the merkle proof
     * @param isEsOrder whether the claim is for esOrder
     */
    function quoteClaimReward(
        uint32 distributionId,
        address user,
        uint256 cumulativeAmount,
        bytes32[] memory merkleProof,
        bool isEsOrder
    ) external view returns (uint256) {
        OCCVaultMessage memory message = buildClaimRewardMessage(distributionId, user, cumulativeAmount, merkleProof, isEsOrder);
        return estimateCCFeeFromVaultToLedger(message);
    }

    /* ====== staking ====== */

    /**
     * @notice construct OCCVaultMessage for stake operation
     * @param amount the amount to stake
     * @param sender the sender of the stake
     */
    function buildStakeOrderMessage(uint256 amount, address sender) internal view returns (OCCVaultMessage memory) {
        return
            OCCVaultMessage({
                chainedEventId: chainedEventId,
                srcChainId: 0,
                token: LedgerToken.ORDER,
                tokenAmount: amount,
                sender: sender,
                payloadType: uint8(PayloadDataType.Stake),
                payload: bytes("")
            });
    }

    /**
     * @notice stake the amount to the ledger
     * @param amount the amount to stake
     */
    function stakeOrder(uint256 amount) external payable {
        OCCVaultMessage memory message = buildStakeOrderMessage(amount, msg.sender);
        chainedEventId += 1;
        vaultSendToLedger(message);
    }

    /**
     * @notice estimate the Layerzero fee for sending a message from vault to ledger chain in native token
     * @param amount the amount to stake
     * @param sender the sender of the stake
     */
    function quoteStakeOrder(uint256 amount, address sender) external view returns (uint256) {
        OCCVaultMessage memory message = buildStakeOrderMessage(amount, sender);
        return estimateCCFeeFromVaultToLedger(message);
    }

    /* ====== Other Operations Including only Amount and User ====== */

    /**
     * @notice construct OCCVaultMessage for other operations
     * @param amount the amount to send
     * @param user the user to send
     * @param payloadType the payload type
     *  - 2: CreateOrderUnstakeRequest,
     *  - 3: CancelOrderUnstakeRequest,
     *  - 4: WithdrawOrder,
     *  - 5: EsOrderUnstakeAndVest,
     *  - 6: RedeemValor,
     *  - 7: ClaimUsdcRevenue,
     */
    function buildOCCMessage(uint256 amount, address user, uint8 payloadType) internal view returns (OCCVaultMessage memory) {
        // require correct payloadType
        require(payloadType >= 2 && payloadType <= 10, "UnsupportedPayloadType");
        return
            OCCVaultMessage({
                chainedEventId: chainedEventId,
                srcChainId: 0,
                token: LedgerToken.PLACEHOLDER,
                tokenAmount: 0,
                sender: user,
                payloadType: payloadType,
                payload: abi.encode(amount)
            });
    }

    /**
     * @notice send user request to the ledger
     * @param amount the amount to send
     * @param payloadType the payload type
     */
    function sendUserRequest(uint256 amount, uint8 payloadType) external payable {
        OCCVaultMessage memory occMsg = buildOCCMessage(amount, msg.sender, payloadType);
        chainedEventId += 1;
        vaultSendToLedger(occMsg);
    }

    /**
     * @notice estimate the Layerzero fee for sending a message from vault to ledger chain in native token
     * @param amount the amount to send
     * @param user the user to send
     * @param payloadType the payload type
     */
    function quoteSendUserRequest(uint256 amount, address user, uint8 payloadType) external view returns (uint256) {
        OCCVaultMessage memory occMsg = buildOCCMessage(amount, user, payloadType);
        return estimateCCFeeFromVaultToLedger(occMsg);
    }

    /**
     *
     * @param _endpoint The the caller of function lzCompose() on the relayer contract, it should be the endpoint
     * @param _localSender The composeMsg sender on local network, it should be the oft/adapter contract
     * @param _eid The eid to identify the network from where the composeMsg sent
     * @param _remoteSender The address to identiy the sender on the remote network
     */
    function _authorizeComposeMsgSender(address _endpoint, address _localSender, uint32 _eid, address _remoteSender) internal view returns (bool) {
        return (lzEndpoint == _endpoint && _localSender == orderTokenOft && _remoteSender == ledgerAddr && eid2ChainId[_eid] == ledgerChainId);
    }

    /* ====== Receive Message From Ledger ====== */

    function lzCompose(
        address from,
        bytes32 /*guid*/,
        bytes calldata _message,
        address /*executor*/,
        bytes calldata /*_extraData*/
    ) external payable {
        uint32 srcEid = _message.srcEid();
        address remoteSender = OFTComposeMsgCodec.bytes32ToAddress(_message.composeFrom());
        require(_authorizeComposeMsgSender(msg.sender, from, srcEid, remoteSender), "OrderlyBox: composeMsg sender check failed");

        bytes memory _composeMsgContent = OFTComposeMsgCodec.composeMsg(_message);

        OCCLedgerMessage memory message = abi.decode(_composeMsgContent, (OCCLedgerMessage));
        vaultRecvFromLedger(message);
    }

    function vaultRecvFromLedger(OCCLedgerMessage memory message) internal {
        if (message.payloadType == uint8(PayloadDataType.ClaimRewardBackward)) {
            // require token is order, and amount > 0
            require(message.token == LedgerToken.ORDER && message.tokenAmount > 0, "InvalidClaimRewardBackward");

            bool success = IERC20(IOFT(orderTokenOft).token()).transfer(message.receiver, message.tokenAmount);

            require(success, "OrderTokenTransferFailed");

            emit ClaimRewardTokenTransferred(message.receiver, message.tokenAmount);
        } else if (message.payloadType == uint8(PayloadDataType.WithdrawOrderBackward)) {
            // require token is order, and amount > 0
            require(message.token == LedgerToken.ORDER && message.tokenAmount > 0, "InvalidWithdrawOrderBackward");

            bool success = IERC20(IOFT(orderTokenOft).token()).transfer(message.receiver, message.tokenAmount);

            require(success, "OrderTokenTransferFailed");

            emit WithdrawOrderTokenTransferred(message.receiver, message.tokenAmount);
        } else if (message.payloadType == uint8(PayloadDataType.ClaimVestingRequestBackward)) {
            // require token is order, and amount > 0
            require(message.token == LedgerToken.ORDER && message.tokenAmount > 0, "InvalidClaimVestingRequestBackward");

            bool success = IERC20(IOFT(orderTokenOft).token()).transfer(message.receiver, message.tokenAmount);

            require(success, "OrderTokenTransferFailed");

            emit ClaimVestingRequestTransferred(message.receiver, message.tokenAmount);
        } else if (message.payloadType == uint8(PayloadDataType.ClaimUsdcRevenueBackward)) {
            require(message.token == LedgerToken.USDC && message.tokenAmount > 0, "InvalidClaimUsdcRevenueBackward");
            bool success = IERC20(usdcAddr).transfer(message.receiver, message.tokenAmount);

            require(success, "USDCTokenTransferFailed");

            emit ClaimUsdcRevenueTransferred(message.receiver, message.tokenAmount);
        } else {
            revert("UnsupportedPayloadType");
        }
    }

    /// @notice fallback to receive
    receive() external payable {}
}
