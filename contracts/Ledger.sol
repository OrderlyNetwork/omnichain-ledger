// SPDX-License-Identifier: MIT
pragma solidity 0.8.22;

import {IERC20, SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IOFT} from "@layerzerolabs/lz-evm-oapp-v2/contracts/oft/interfaces/IOFT.sol";

import {LedgerAccessControl} from "./lib/LedgerAccessControl.sol";
import {ChainedEventIdCounter} from "./lib/ChainedEventIdCounter.sol";
import {LedgerPayloadTypes, PayloadDataType} from "./lib/LedgerTypes.sol";
import {Valor} from "./lib/Valor.sol";
import {Staking} from "./lib/Staking.sol";
import {Vesting} from "./lib/Vesting.sol";
import {Revenue} from "./lib/Revenue.sol";
import {MerkleDistributor} from "./lib/MerkleDistributor.sol";
import {OCCVaultMessage, LedgerToken} from "./lib/OCCTypes.sol";
import {LedgerOCCManager} from "./lib/OCCManager.sol";

// lz imports
import {OFTComposeMsgCodec} from "@layerzerolabs/lz-evm-oapp-v2/contracts/oft/libs/OFTComposeMsgCodec.sol";

contract Ledger is LedgerAccessControl, LedgerOCCManager, ChainedEventIdCounter, MerkleDistributor, Valor, Staking, Revenue, Vesting {
    using SafeERC20 for IERC20;

    /* ========== STATE VARIABLES ========== */
    address public occAdaptor;

    /* ========== ERRORS ========== */
    error OrderTokenIsZero();
    error OCCAdaptorIsZero();
    error UnsupportedPayloadType();

    /* ========== INITIALIZER ========== */

    function initialize(
        address _owner,
        address _occAdaptor,
        IOFT _orderTokenOft,
        uint256 _valorPerSecond,
        uint256 _maximumValorEmission
    ) external initializer {
        ledgerAccessControlInit(_owner);
        merkleDistributorInit(_owner);
        valorInit(_owner, _valorPerSecond, _maximumValorEmission);
        stakingInit(_owner);
        revenueInit(_owner, block.timestamp);
        vestingInit(VESTING_LOCK_PERIOD, VESTING_LINEAR_PERIOD, _owner);

        if (address(_orderTokenOft) == address(0)) revert OrderTokenIsZero();
        if (_occAdaptor == address(0)) revert OCCAdaptorIsZero();

        orderTokenOft = address(_orderTokenOft);
        occAdaptor = _occAdaptor;
    }

    /// @notice Receives message from OCCAdapter and processes it
    function ledgerRecvFromVault(OCCVaultMessage memory message) internal {
        if (message.payloadType == uint8(PayloadDataType.ClaimReward)) {
            LedgerPayloadTypes.ClaimReward memory claimRewardPayload = abi.decode(message.payload, (LedgerPayloadTypes.ClaimReward));
            _LedgerClaimRewards(
                claimRewardPayload.distributionId,
                message.sender,
                message.srcChainId,
                claimRewardPayload.cumulativeAmount,
                claimRewardPayload.merkleProof
            );
        } else if (message.payloadType == uint8(PayloadDataType.RedeemValor)) {
            LedgerPayloadTypes.RedeemValor memory redeemValorPayload = abi.decode(message.payload, (LedgerPayloadTypes.RedeemValor));
            _LedgerRedeemValor(message.sender, message.srcChainId, redeemValorPayload.amount);
        } else if (message.payloadType == uint8(PayloadDataType.EsOrderUnstakeAndVest)) {
            LedgerPayloadTypes.EsOrderUnstakeAndVest memory esOrderUnstakeAndVestPayload = abi.decode(
                message.payload,
                (LedgerPayloadTypes.EsOrderUnstakeAndVest)
            );
            _LedgerEsOrderUnstakeAndVest(message.sender, message.srcChainId, esOrderUnstakeAndVestPayload.amount);
        } else if (message.payloadType == uint8(PayloadDataType.Stake)) {
            _stake(message.sender, message.srcChainId, message.token, message.tokenAmount);
        } else {
            revert UnsupportedPayloadType();
        }
    }

    /* ========== INTERNAL FUNCTIONS ========== */

    function _LedgerClaimRewards(
        uint32 _distributionId,
        address _user,
        uint256 _srcChainId,
        uint256 _cumulativeAmount,
        bytes32[] memory _merkleProof
    ) internal {
        (LedgerToken token, uint256 claimedAmount) = _claimRewards(_distributionId, _user, _srcChainId, _cumulativeAmount, _merkleProof);

        if (claimedAmount != 0) {
            if (token == LedgerToken.ORDER) {
                // TODO: compose message to OCCAdapter to transfer claimableAmount of $ORDER to message.sender
            } else if (token == LedgerToken.ESORDER) {
                _stake(_user, _srcChainId, token, claimedAmount);
            } else {
                revert UnsupportedToken();
            }
        }
    }

    function _LedgerRedeemValor(address _user, uint256 _chainId, uint256 _amount) internal {
        _updateValorVarsAndCollectUserValor(_user);
        _redeemValor(_user, _chainId, _amount);
    }

    function _LedgerEsOrderUnstakeAndVest(address _user, uint256 _chainId, uint256 _amount) internal {
        _esOrderUnstake(_user, _chainId, _amount);
        _createVestingRequest(_user, _chainId, _amount);
    }

    function lzCompose(address, bytes32, bytes calldata _message, address, bytes calldata /*_extraData*/ )
        external
        payable
    {
        bytes memory _composeMsgContent = OFTComposeMsgCodec.composeMsg(_message);

        OCCVaultMessage memory message = abi.decode(_composeMsgContent, (OCCVaultMessage));
        ledgerRecvFromVault(message);

        // revert("TestOnly: end of lzCompose");
    }
}
