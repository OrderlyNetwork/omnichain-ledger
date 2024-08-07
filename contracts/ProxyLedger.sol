// SPDX-License-Identifier: MIT
pragma solidity 0.8.22;

// oz imports
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {IERC20, SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

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
    using SafeERC20 for IERC20;

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
     */
    function buildClaimRewardMessage(
        uint32 distributionId,
        address user,
        uint256 cumulativeAmount,
        bytes32[] memory merkleProof
    ) internal view returns (OCCVaultMessage memory) {
        return
            OCCVaultMessage({
                chainedEventId: chainedEventId,
                srcChainId: 0,
                token: LedgerToken.PLACEHOLDER,
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
     */
    function claimReward(uint32 distributionId, uint256 cumulativeAmount, bytes32[] memory merkleProof) external payable whenNotPaused {
        OCCVaultMessage memory message = buildClaimRewardMessage(distributionId, msg.sender, cumulativeAmount, merkleProof);
        vaultSendToLedger(message);
    }

    /**
     * @notice estimate the Layerzero fee for sending a message from vault to ledger chain in native token
     * @param distributionId the distribution id
     * @param user the user to claim reward
     * @param cumulativeAmount the cumulative amount to claim
     * @param merkleProof the merkle proof
     */
    function quoteClaimReward(
        uint32 distributionId,
        address user,
        uint256 cumulativeAmount,
        bytes32[] memory merkleProof
    ) external view returns (uint256) {
        OCCVaultMessage memory message = buildClaimRewardMessage(distributionId, user, cumulativeAmount, merkleProof);
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
    function stakeOrder(uint256 amount) external payable whenNotPaused {
        OCCVaultMessage memory message = buildStakeOrderMessage(amount, msg.sender);
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
    *  2: CreateOrderUnstakeRequest,
    *  3: CancelOrderUnstakeRequest,
    *  4: WithdrawOrder,
    *  5: EsOrderUnstakeAndVest,
    *  6: CancelVestingRequest,
    *  7: CancelAllVestingRequests,
    *  8: ClaimVestingRequest,
    *  9: RedeemValor,
    *  10: ClaimUsdcRevenue,
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
    function sendUserRequest(uint256 amount, uint8 payloadType) external payable whenNotPaused {
        OCCVaultMessage memory occMsg = buildOCCMessage(amount, msg.sender, payloadType);
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

            IERC20(IOFT(orderTokenOft).token()).safeTransfer(message.receiver, message.tokenAmount);

            emit ClaimRewardTokenTransferred(message.receiver, message.tokenAmount);
        } else if (message.payloadType == uint8(PayloadDataType.WithdrawOrderBackward)) {
            // require token is order, and amount > 0
            require(message.token == LedgerToken.ORDER && message.tokenAmount > 0, "InvalidWithdrawOrderBackward");

            IERC20(IOFT(orderTokenOft).token()).safeTransfer(message.receiver, message.tokenAmount);

            emit WithdrawOrderTokenTransferred(message.receiver, message.tokenAmount);
        } else if (message.payloadType == uint8(PayloadDataType.ClaimVestingRequestBackward)) {
            // require token is order, and amount > 0
            require(message.token == LedgerToken.ORDER && message.tokenAmount > 0, "InvalidClaimVestingRequestBackward");

            IERC20(IOFT(orderTokenOft).token()).safeTransfer(message.receiver, message.tokenAmount);

            emit ClaimVestingRequestTransferred(message.receiver, message.tokenAmount);
        } else if (message.payloadType == uint8(PayloadDataType.ClaimUsdcRevenueBackward)) {
            require(message.token == LedgerToken.USDC && message.tokenAmount > 0, "InvalidClaimUsdcRevenueBackward");
            IERC20(usdcAddr).safeTransfer(message.receiver, message.tokenAmount);

            emit ClaimUsdcRevenueTransferred(message.receiver, message.tokenAmount);
        } else {
            revert("UnsupportedPayloadType");
        }
    }

    /**
     * @notice withdraw function for native token
     * @param to the address to withdraw to
     */
    function withdrawTo(address to) external onlyRole(DEFAULT_ADMIN_ROLE) {
        payable(to).transfer(address(this).balance);
    }

    /// @notice fallback to receive
    receive() external payable {}
}
