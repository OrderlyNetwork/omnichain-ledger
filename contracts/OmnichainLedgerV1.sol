// SPDX-License-Identifier: MIT
pragma solidity 0.8.22;

import {IERC20, SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IOFT} from "@layerzerolabs/lz-evm-oapp-v2/contracts/oft/interfaces/IOFT.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

import {LedgerAccessControl} from "./lib/LedgerAccessControl.sol";
import {ChainedEventIdCounter} from "./lib/ChainedEventIdCounter.sol";
import {LedgerPayloadTypes, PayloadDataType} from "./lib/LedgerTypes.sol";
import {Valor} from "./lib/Valor.sol";
import {Staking} from "./lib/Staking.sol";
import {Vesting} from "./lib/Vesting.sol";
import {Revenue} from "./lib/Revenue.sol";
import {MerkleDistributor} from "./lib/MerkleDistributor.sol";
import {OCCVaultMessage, OCCLedgerMessage, LedgerToken} from "./lib/OCCTypes.sol";
import {ILedgerOCCManager} from "./lib/ILedgerOCCManager.sol";

// lz imports
import {OFTComposeMsgCodec} from "@layerzerolabs/lz-evm-oapp-v2/contracts/oft/libs/OFTComposeMsgCodec.sol";

contract OmnichainLedgerV1 is
    LedgerAccessControl,
    UUPSUpgradeable,
    ChainedEventIdCounter,
    MerkleDistributor,
    Valor,
    Staking,
    Revenue,
    Vesting
{
    using SafeERC20 for IERC20;

    /* ========== STATE VARIABLES ========== */
    address public occAdaptor;
    address public orderTokenOft;

    /* ========== ERRORS ========== */
    error UnsupportedPayloadType();

    /* ========== MODIFIERS ========== */
    modifier onlyOCCAdaptor() {
        require(msg.sender == occAdaptor, "OnlyOCCAdaptor");
        _;
    }

    function VERSION() external pure virtual returns (string memory) {
        return "1.0.0";
    }

    /* ====== UUPS ATHORIZATION ====== */

    /// @notice upgrade the contract
    function _authorizeUpgrade(address) internal override onlyRole(DEFAULT_ADMIN_ROLE) {}

    /* ========== INITIALIZER ========== */

    function initialize(
        address _owner,
        address _occAdaptor,
        address _orderCollector,
        IOFT _orderTokenOft,
        uint256 _valorPerSecond,
        uint256 _maximumValorEmission
    ) external initializer {
        ledgerAccessControlInit(_owner);
        merkleDistributorInit(_owner);
        valorInit(_owner, _valorPerSecond, _maximumValorEmission);
        stakingInit(_owner);
        revenueInit(_owner, block.timestamp);
        vestingInit(VESTING_LOCK_PERIOD, VESTING_LINEAR_PERIOD, _orderCollector);

        orderTokenOft = address(_orderTokenOft);
        occAdaptor = _occAdaptor;
    }

    /* ========== OWNER FUNCTIONS ========== */

    function setOccAdaptor(address _occAdaptor) external onlyRole(DEFAULT_ADMIN_ROLE) {
        occAdaptor = _occAdaptor;
    }

    function setOrderTokenOft(IOFT _orderTokenOft) external onlyRole(DEFAULT_ADMIN_ROLE) {
        orderTokenOft = address(_orderTokenOft);
    }

    /* ========== INTERNAL FUNCTIONS ========== */

    /// @notice Receives message from OCCAdapter and dispatch it
    function ledgerRecvFromVault(OCCVaultMessage memory message) external onlyOCCAdaptor {
        // ========== ClaimReward ==========
        if (message.payloadType == uint8(PayloadDataType.ClaimReward)) {
            LedgerPayloadTypes.ClaimReward memory claimRewardPayload = abi.decode(message.payload, (LedgerPayloadTypes.ClaimReward));
            _ledgerClaimRewards(
                claimRewardPayload.distributionId,
                message.sender,
                message.srcChainId,
                claimRewardPayload.cumulativeAmount,
                claimRewardPayload.merkleProof
            );
        }
        // ========== Stake ==========
        else if (message.payloadType == uint8(PayloadDataType.Stake)) {
            _stake(message.sender, message.srcChainId, message.token, message.tokenAmount);
        }
        // ========== CreateOrderUnstakeRequest ==========
        else if (message.payloadType == uint8(PayloadDataType.CreateOrderUnstakeRequest)) {
            LedgerPayloadTypes.CreateOrderUnstakeRequest memory createOrderUnstakeRequestPayload = abi.decode(
                message.payload,
                (LedgerPayloadTypes.CreateOrderUnstakeRequest)
            );
            _createOrderUnstakeRequest(message.sender, message.srcChainId, createOrderUnstakeRequestPayload.amount);
        }
        // ========== CancelOrderUnstakeRequest ==========
        else if (message.payloadType == uint8(PayloadDataType.CancelOrderUnstakeRequest)) {
            _cancelOrderUnstakeRequest(message.sender, message.srcChainId);
        }
        // ========== WithdrawOrder ==========
        else if (message.payloadType == uint8(PayloadDataType.WithdrawOrder)) {
            _ledgerWithdrawOrder(message.sender, message.srcChainId);
        }
        // ========== EsOrderUnstakeAndVest ==========
        else if (message.payloadType == uint8(PayloadDataType.EsOrderUnstakeAndVest)) {
            LedgerPayloadTypes.EsOrderUnstakeAndVest memory esOrderUnstakeAndVestPayload = abi.decode(
                message.payload,
                (LedgerPayloadTypes.EsOrderUnstakeAndVest)
            );
            _ledgerEsOrderUnstakeAndVest(message.sender, message.srcChainId, esOrderUnstakeAndVestPayload.amount);
        }
        // ========== CancelVestingRequest ==========
        else if (message.payloadType == uint8(PayloadDataType.CancelVestingRequest)) {
            LedgerPayloadTypes.CancelVestingRequest memory cancelVestingRequestPayload = abi.decode(
                message.payload,
                (LedgerPayloadTypes.CancelVestingRequest)
            );
            uint256 esOrderAmountToReStake = _cancelVestingRequest(message.sender, message.srcChainId, cancelVestingRequestPayload.requestId);
            _stake(message.sender, message.srcChainId, LedgerToken.ESORDER, esOrderAmountToReStake);
        }
        // ========== CancelAllVestingRequests ==========
        else if (message.payloadType == uint8(PayloadDataType.CancelAllVestingRequests)) {
            uint256 esOrderAmountToReStake = _cancelAllVestingRequests(message.sender, message.srcChainId);
            _stake(message.sender, message.srcChainId, LedgerToken.ESORDER, esOrderAmountToReStake);
        }
        // ========== ClaimVestingRequest ==========
        else if (message.payloadType == uint8(PayloadDataType.ClaimVestingRequest)) {
            LedgerPayloadTypes.ClaimVestingRequest memory claimVestingRequestPayload = abi.decode(
                message.payload,
                (LedgerPayloadTypes.ClaimVestingRequest)
            );
            _ledgerClaimVestingRequest(message.sender, message.srcChainId, claimVestingRequestPayload.requestId);
        }
        // ========== RedeemValor ==========
        else if (message.payloadType == uint8(PayloadDataType.RedeemValor)) {
            LedgerPayloadTypes.RedeemValor memory redeemValorPayload = abi.decode(message.payload, (LedgerPayloadTypes.RedeemValor));
            _ledgerRedeemValor(message.sender, message.srcChainId, redeemValorPayload.amount);
        }
        // ========== ClaimUsdcRevenue ==========
        else if (message.payloadType == uint8(PayloadDataType.ClaimUsdcRevenue)) {
            // _claimUsdcRevenue(message.sender, message.srcChainId);
            _ledgerClaimUsdcRevenue(message.sender, message.srcChainId);
        }
        // ========== UnsupportedPayloadType ==========
        else {
            revert UnsupportedPayloadType();
        }
    }

    /* ========== INTERNAL FUNCTIONS ========== */

    /// @notice Implement internal reward claiming logic:
    /// $ORDER rewards are sent to user wallet on the source chain
    /// $ESORDER rewards are staked to the user
    function _ledgerClaimRewards(
        uint32 _distributionId,
        address _user,
        uint256 _srcChainId,
        uint256 _cumulativeAmount,
        bytes32[] memory _merkleProof
    ) internal {
        (LedgerToken token, uint256 claimedAmount) = _claimRewards(_distributionId, _user, _srcChainId, _cumulativeAmount, _merkleProof);

        if (claimedAmount != 0) {
            if (token == LedgerToken.ESORDER) {
                _stake(_user, _srcChainId, token, claimedAmount);
            }

            OCCLedgerMessage memory message = OCCLedgerMessage({
                dstChainId: _srcChainId,
                token: token,
                tokenAmount: claimedAmount,
                receiver: _user,
                payloadType: uint8(PayloadDataType.ClaimRewardBackward),
                payload: "0x0"
            });
            ILedgerOCCManager(occAdaptor).ledgerSendToVault(message);
        }
    }

    /// @notice Withdrawn $ORDER tokens are sent back to the user wallet on the source chain
    function _ledgerWithdrawOrder(address _user, uint256 _chainId) internal {
        uint256 orderAmountForWithdraw = _withdrawOrder(_user, _chainId);
        if (orderAmountForWithdraw != 0) {
            OCCLedgerMessage memory message = OCCLedgerMessage({
                dstChainId: _chainId,
                token: LedgerToken.ORDER,
                tokenAmount: orderAmountForWithdraw,
                receiver: _user,
                payloadType: uint8(PayloadDataType.WithdrawOrderBackward),
                payload: "0x0"
            });
            ILedgerOCCManager(occAdaptor).ledgerSendToVault(message);
        }
    }

    /// @notice Claimed USDC revenue is sent back to the user wallet on the source chain
    function _ledgerClaimUsdcRevenue(address _user, uint256 _chainId) internal {
        uint256 usdcRevenueAmount = _claimUsdcRevenue(_user, _chainId);
        if (usdcRevenueAmount != 0) {
            OCCLedgerMessage memory message = OCCLedgerMessage({
                dstChainId: _chainId,
                token: LedgerToken.USDC,
                tokenAmount: usdcRevenueAmount,
                receiver: _user,
                payloadType: uint8(PayloadDataType.ClaimUsdcRevenueBackward),
                payload: "0x0"
            });
            ILedgerOCCManager(occAdaptor).ledgerSendToVault(message);
        }
    }

    /// @notice Claimed ORDER tokens should be sent to the user wallet on the source chain
    function _ledgerClaimVestingRequest(address _user, uint256 _chainId, uint256 _requestId) internal {
        (uint256 claimedOrderAmount, uint256 unclaimedOrderAmount) = _claimVestingRequest(_user, _chainId, _requestId);

        if (claimedOrderAmount != 0) {
            OCCLedgerMessage memory message = OCCLedgerMessage({
                dstChainId: _chainId,
                token: LedgerToken.ORDER,
                tokenAmount: claimedOrderAmount,
                receiver: _user,
                payloadType: uint8(PayloadDataType.ClaimVestingRequestBackward),
                payload: "0x0"
            });
            ILedgerOCCManager(occAdaptor).ledgerSendToVault(message);
        }

        if (unclaimedOrderAmount != 0) {
            IERC20(orderTokenOft).safeTransfer(orderCollector, unclaimedOrderAmount);
        }
    }

    /// @notice Before redeeming Valor need to collect pending Valor for the user
    function _ledgerRedeemValor(address _user, uint256 _chainId, uint256 _amount) internal {
        _updateValorVarsAndCollectUserValor(_user);
        _redeemValor(_user, _chainId, _amount);
    }

    /// @notice When $ESORDER unstaked, it should be immediately vested
    function _ledgerEsOrderUnstakeAndVest(address _user, uint256 _chainId, uint256 _amount) internal {
        _esOrderUnstake(_user, _chainId, _amount);
        _createVestingRequest(_user, _chainId, _amount);
    }

}
