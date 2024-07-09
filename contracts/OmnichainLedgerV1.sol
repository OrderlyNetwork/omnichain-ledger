// SPDX-License-Identifier: MIT
pragma solidity 0.8.22;

import {IOFT} from "@layerzerolabs/lz-evm-oapp-v2/contracts/oft/interfaces/IOFT.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

import {LedgerAccessControl} from "./lib/LedgerAccessControl.sol";
import {ChainedEventIdCounter} from "./lib/ChainedEventIdCounter.sol";
import {LedgerPayloadTypes, PayloadDataType, LedgerSignedTypes} from "./lib/LedgerTypes.sol";
import {Valor} from "./lib/Valor.sol";
import {Staking} from "./lib/Staking.sol";
import {Vesting} from "./lib/Vesting.sol";
import {Revenue} from "./lib/Revenue.sol";
import {MerkleDistributor} from "./lib/MerkleDistributor.sol";
import {OCCVaultMessage, OCCLedgerMessage, LedgerToken} from "./lib/OCCTypes.sol";
import {ILedgerOCCManager} from "./lib/ILedgerOCCManager.sol";

// lz imports
import {OFTComposeMsgCodec} from "@layerzerolabs/lz-evm-oapp-v2/contracts/oft/libs/OFTComposeMsgCodec.sol";

// ChainedEventIdCounter does not used anymore. Leaved for now to not break upgradeability. Can be removed before complete redeployment.
contract OmnichainLedgerV1 is LedgerAccessControl, UUPSUpgradeable, ChainedEventIdCounter, MerkleDistributor, Valor, Staking, Revenue, Vesting {
    /* ========== STATE VARIABLES ========== */
    address public occAdaptor;

    /* ========== ERRORS ========== */
    error UnsupportedPayloadType();

    /* ========== MODIFIERS ========== */
    modifier onlyOCCAdaptor() {
        require(msg.sender == occAdaptor, "OnlyOCCAdaptor");
        _;
    }

    function VERSION() external pure virtual returns (string memory) {
        return "1.0.1";
    }

    /* ====== UUPS AUTHORIZATION ====== */

    /// @notice upgrade the contract
    function _authorizeUpgrade(address) internal override onlyRole(DEFAULT_ADMIN_ROLE) {}

    /* ========== PREVENT INITIALIZATION FOR IMPLEMENTATION CONTRACTS ========== */

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /* ========== INITIALIZER ========== */

    function initialize(address _owner, address _occAdaptor, uint256 _valorPerSecond, uint256 _maximumValorEmission) external initializer {
        ledgerAccessControlInit(_owner);
        merkleDistributorInit(_owner);
        valorInit(_owner, _valorPerSecond, _maximumValorEmission);
        stakingInit(_owner, DEFAULT_UNSTAKE_LOCK_PERIOD);
        revenueInit(_owner, DEFAULT_BATCH_DURATION);
        vestingInit(_owner, VESTING_LOCK_PERIOD, VESTING_LINEAR_PERIOD);

        occAdaptor = _occAdaptor;
    }

    /* ========== OWNER FUNCTIONS ========== */

    function setOccAdaptor(address _occAdaptor) external onlyRole(DEFAULT_ADMIN_ROLE) {
        occAdaptor = _occAdaptor;
    }

    /* ========== EXTERNAL FUNCTIONS ========== */

    /// @notice Receives message from OCCAdapter and dispatch it
    function ledgerRecvFromVault(OCCVaultMessage memory message) external onlyOCCAdaptor {
        // ========== ClaimReward ==========
        if (message.payloadType == uint8(PayloadDataType.ClaimReward)) {
            LedgerPayloadTypes.ClaimReward memory claimRewardPayload = abi.decode(message.payload, (LedgerPayloadTypes.ClaimReward));
            _ledgerClaimRewards(
                claimRewardPayload.distributionId,
                message.sender,
                message.chainedEventId,
                message.srcChainId,
                claimRewardPayload.cumulativeAmount,
                claimRewardPayload.merkleProof
            );
        }
        // ========== Stake ==========
        else if (message.payloadType == uint8(PayloadDataType.Stake)) {
            _stake(message.sender, message.chainedEventId, message.srcChainId, message.token, message.tokenAmount);
        }
        // ========== CreateOrderUnstakeRequest ==========
        else if (message.payloadType == uint8(PayloadDataType.CreateOrderUnstakeRequest)) {
            LedgerPayloadTypes.CreateOrderUnstakeRequest memory createOrderUnstakeRequestPayload = abi.decode(
                message.payload,
                (LedgerPayloadTypes.CreateOrderUnstakeRequest)
            );
            _createOrderUnstakeRequest(message.sender, message.chainedEventId, message.srcChainId, createOrderUnstakeRequestPayload.amount);
        }
        // ========== CancelOrderUnstakeRequest ==========
        else if (message.payloadType == uint8(PayloadDataType.CancelOrderUnstakeRequest)) {
            _cancelOrderUnstakeRequest(message.sender, message.chainedEventId, message.srcChainId);
        }
        // ========== WithdrawOrder ==========
        else if (message.payloadType == uint8(PayloadDataType.WithdrawOrder)) {
            _ledgerWithdrawOrder(message.sender, message.chainedEventId, message.srcChainId);
        }
        // ========== EsOrderUnstakeAndVest ==========
        else if (message.payloadType == uint8(PayloadDataType.EsOrderUnstakeAndVest)) {
            LedgerPayloadTypes.EsOrderUnstakeAndVest memory esOrderUnstakeAndVestPayload = abi.decode(
                message.payload,
                (LedgerPayloadTypes.EsOrderUnstakeAndVest)
            );
            _ledgerEsOrderUnstakeAndVest(message.sender, message.chainedEventId, message.srcChainId, esOrderUnstakeAndVestPayload.amount);
        }
        // ========== CancelVestingRequest ==========
        else if (message.payloadType == uint8(PayloadDataType.CancelVestingRequest)) {
            LedgerPayloadTypes.CancelVestingRequest memory cancelVestingRequestPayload = abi.decode(
                message.payload,
                (LedgerPayloadTypes.CancelVestingRequest)
            );
            uint256 esOrderAmountToReStake = _cancelVestingRequest(
                message.sender,
                message.chainedEventId,
                message.srcChainId,
                cancelVestingRequestPayload.requestId
            );
            _stake(message.sender, message.chainedEventId, message.srcChainId, LedgerToken.ESORDER, esOrderAmountToReStake);
        }
        // ========== CancelAllVestingRequests ==========
        else if (message.payloadType == uint8(PayloadDataType.CancelAllVestingRequests)) {
            uint256 esOrderAmountToReStake = _cancelAllVestingRequests(message.sender, message.chainedEventId, message.srcChainId);
            _stake(message.sender, message.chainedEventId, message.srcChainId, LedgerToken.ESORDER, esOrderAmountToReStake);
        }
        // ========== ClaimVestingRequest ==========
        else if (message.payloadType == uint8(PayloadDataType.ClaimVestingRequest)) {
            LedgerPayloadTypes.ClaimVestingRequest memory claimVestingRequestPayload = abi.decode(
                message.payload,
                (LedgerPayloadTypes.ClaimVestingRequest)
            );
            _ledgerClaimVestingRequest(message.sender, message.chainedEventId, message.srcChainId, claimVestingRequestPayload.requestId);
        }
        // ========== RedeemValor ==========
        else if (message.payloadType == uint8(PayloadDataType.RedeemValor)) {
            LedgerPayloadTypes.RedeemValor memory redeemValorPayload = abi.decode(message.payload, (LedgerPayloadTypes.RedeemValor));
            _ledgerRedeemValor(message.sender, message.chainedEventId, message.srcChainId, redeemValorPayload.amount);
        }
        // ========== ClaimUsdcRevenue ==========
        else if (message.payloadType == uint8(PayloadDataType.ClaimUsdcRevenue)) {
            _ledgerClaimUsdcRevenue(message.sender, message.chainedEventId, message.srcChainId);
        }
        // ========== UnsupportedPayloadType ==========
        else {
            revert UnsupportedPayloadType();
        }
    }

    /// @notice CeFi updates the daily USDC net fee revenue, define
    /// Then check if it was last day in batch, and if so, fix this price for the batch
    /// Internally restricted to TREASURE_UPDATER_ROLE
    function dailyUsdcNetFeeRevenue(LedgerSignedTypes.UintValueData calldata data) external {
        _dailyUsdcNetFeeRevenue(data);
        _possiblyFixBatchValorToUsdcRateForPreviousBatch();
    }

    /* ========== INTERNAL FUNCTIONS ========== */

    /// @notice Implement internal reward claiming logic:
    /// $ORDER rewards are sent to user wallet on the source chain
    /// $ESORDER rewards are staked to the user
    function _ledgerClaimRewards(
        uint32 _distributionId,
        address _user,
        uint256 _chainedEventId,
        uint256 _srcChainId,
        uint256 _cumulativeAmount,
        bytes32[] memory _merkleProof
    ) internal {
        (LedgerToken token, uint256 claimedAmount) = _claimRewards(
            _distributionId,
            _user,
            _chainedEventId,
            _srcChainId,
            _cumulativeAmount,
            _merkleProof
        );

        if (claimedAmount != 0) {
            if (token == LedgerToken.ESORDER) {
                _stake(_user, _chainedEventId, _srcChainId, token, claimedAmount);
            } else if (token == LedgerToken.ORDER) {
                OCCLedgerMessage memory message = OCCLedgerMessage({
                    dstChainId: _srcChainId,
                    token: LedgerToken.ORDER,
                    tokenAmount: claimedAmount,
                    receiver: _user,
                    payloadType: uint8(PayloadDataType.ClaimRewardBackward),
                    payload: "0x0"
                });
                ILedgerOCCManager(occAdaptor).ledgerSendToVault(message);
            }
        }
    }

    /// @notice Withdrawn $ORDER tokens are sent back to the user wallet on the source chain
    function _ledgerWithdrawOrder(address _user, uint256 _chainedEventId, uint256 _chainId) internal {
        uint256 orderAmountForWithdraw = _withdrawOrder(_user, _chainedEventId, _chainId);
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
    function _ledgerClaimUsdcRevenue(address _user, uint256 _chainedEventId, uint256 _chainId) internal {
        uint256 usdcRevenueAmount = _claimUsdcRevenue(_user, _chainedEventId, _chainId);
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
    function _ledgerClaimVestingRequest(address _user, uint256 _chainedEventId, uint256 _chainId, uint256 _requestId) internal {
        (uint256 claimedOrderAmount, uint256 unclaimedOrderAmount) = _claimVestingRequest(_user, _chainedEventId, _chainId, _requestId);

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
            ILedgerOCCManager(occAdaptor).collectUnvestedOrders(unclaimedOrderAmount);
        }
    }

    /// @notice Before redeeming Valor need to collect pending Valor for the user
    function _ledgerRedeemValor(address _user, uint256 _chainedEventId, uint256 _chainId, uint256 _amount) internal {
        _updateValorVarsAndCollectUserValor(_user);
        _redeemValor(_user, _chainedEventId, _chainId, _amount);
    }

    /// @notice When $ESORDER unstaked, it should be immediately vested
    function _ledgerEsOrderUnstakeAndVest(address _user, uint256 _chainedEventId, uint256 _chainId, uint256 _amount) internal {
        _esOrderUnstake(_user, _chainedEventId, _chainId, _amount);
        _createVestingRequest(_user, _chainedEventId, _chainId, _amount);
    }
}
