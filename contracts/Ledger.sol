// SPDX-License-Identifier: MIT
pragma solidity 0.8.22;

import {IERC20, SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IOFT} from "@layerzerolabs/lz-evm-oapp-v2/contracts/oft/interfaces/IOFT.sol";

import {LedgerToken, OCCVaultMessage, OCCLedgerMessage, IOCCLedgerReceiver} from "orderly-omnichain-occ/contracts/OCCInterface.sol";

import {LedgerAccessControl} from "./lib/LedgerAccessControl.sol";
import {ChainedEventIdCounter} from "./lib/ChainedEventIdCounter.sol";
import {LedgerPayloadTypes, PayloadDataType} from "./lib/LedgerTypes.sol";
import {OCCManager} from "./lib/OCCManager.sol";
import {Valor} from "./lib/Valor.sol";
import {Staking} from "./lib/Staking.sol";
import {Vesting} from "./lib/Vesting.sol";
import {Revenue} from "./lib/Revenue.sol";
import {MerkleDistributor} from "./lib/MerkleDistributor.sol";

contract Ledger is LedgerAccessControl, ChainedEventIdCounter, OCCManager, Valor, Staking, Vesting, Revenue, MerkleDistributor {
    using SafeERC20 for IERC20;

    /* ========== STATE VARIABLES ========== */
    address public orderToken;
    address public occAdaptor;

    /* ========== ERRORS ========== */
    error OrderTokenIsZero();
    error OCCAdaptorIsZero();

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
        valorInit(_valorPerSecond, _maximumValorEmission);
        stakingInit();
        revenueInit(block.timestamp);

        if (address(_orderTokenOft) == address(0)) revert OrderTokenIsZero();
        if (_occAdaptor == address(0)) revert OCCAdaptorIsZero();

        orderToken = address(_orderTokenOft);
        occAdaptor = _occAdaptor;
    }

    function ledgerRecvFromVault(OCCVaultMessage calldata message) external override {
        if (message.payloadType == uint8(PayloadDataType.ClaimReward)) {
            LedgerPayloadTypes.ClaimReward memory claimRewardPayload = abi.decode(message.payload, (LedgerPayloadTypes.ClaimReward));
            (LedgerToken token, uint256 claimableAmount) = _claimRewards(
                claimRewardPayload.distributionId,
                message.sender,
                message.srcChainId,
                claimRewardPayload.cumulativeAmount,
                claimRewardPayload.merkleProof
            );

            stake(message.sender, message.srcChainId, token, claimableAmount);
        }
    }

    /* ========== EXTERNAL FUNCTIONS ========== */

    function redeemValor(address _user, uint256 _srcChainId, uint256 _amount) external nonReentrant {
        _updateValorVarsAndCollectValor(_user);

        _redeemValor(_user, _srcChainId, _amount);
    }
}
