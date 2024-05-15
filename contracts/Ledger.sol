// SPDX-License-Identifier: MIT
pragma solidity 0.8.22;

import {IERC20, SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IOFT} from "@layerzerolabs/lz-evm-oapp-v2/contracts/oft/interfaces/IOFT.sol";

import {LedgerToken, OCCVaultMessage, OCCLedgerMessage, IOCCReceiver} from "orderly-omnichain-occ/contracts/OCCInterface.sol";

import {LedgerAccessControl} from "./lib/LedgerAccessControl.sol";
import {ChainedEventIdCounter} from "./lib/ChainedEventIdCounter.sol";
import {LedgerTypes, PayloadDataType} from "./lib/LedgerTypes.sol";
import {MerkleDistributor} from "./lib/MerkleDistributor.sol";
import {OCCManager} from "./lib/OCCManager.sol";
import {Revenue} from "./lib/Revenue.sol";
import {Staking} from "./lib/Staking.sol";
import {Valor} from "./lib/Valor.sol";

contract Ledger is LedgerAccessControl, ChainedEventIdCounter, OCCManager, MerkleDistributor, Valor, Staking, Revenue {
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
        if (address(_orderTokenOft) == address(0)) revert OrderTokenIsZero();
        if (_occAdaptor == address(0)) revert OCCAdaptorIsZero();

        if (_valorPerSecond > Staking.MAX_VALOR_PER_SECOND) revert ValorPerSecondExceedsMaxValue();

        ledgerAccessControlInit(_owner);
        merkleDistributorInit(_owner);

        orderToken = address(_orderTokenOft);
        occAdaptor = _occAdaptor;

        // Staking parameters
        valorPerSecond = _valorPerSecond;
        maximumValorEmission = _maximumValorEmission;
        lastValorUpdateTimestamp = block.timestamp;
    }

    function ledgerRecvFromVault(OCCVaultMessage calldata message) external override {
        if (message.payloadType == uint8(PayloadDataType.ClaimReward)) {
            LedgerTypes.ClaimReward memory claimRewardPayload = abi.decode(message.payload, (LedgerTypes.ClaimReward));
            claimRewards(
                claimRewardPayload.distributionId,
                claimRewardPayload.user,
                message.srcChainId,
                claimRewardPayload.cumulativeAmount,
                claimRewardPayload.merkleProof
            );
        }
    }

    function vaultRecvFromLedger(OCCLedgerMessage calldata message) external override {}

    /* ========== INTERNAL FUNCTIONS ========== */

    // ███████ ████████  █████  ██   ██ ██ ███    ██  ██████
    // ██         ██    ██   ██ ██  ██  ██ ████   ██ ██
    // ███████    ██    ███████ █████   ██ ██ ██  ██ ██   ███
    //      ██    ██    ██   ██ ██  ██  ██ ██  ██ ██ ██    ██
    // ███████    ██    ██   ██ ██   ██ ██ ██   ████  ██████

    /* ========== EXTERNAL FUNCTIONS ========== */

    /// @notice Stake tokens from LedgerToken list for a given user
    function stake(address _user, LedgerToken _token, uint256 _amount) external nonReentrant whenNotPaused {
        if (_amount == 0) revert AmountIsZero();

        _updateValorVars();
        _collectValor(_user);

        totalStakedAmount += _amount;
        userInfos[_user].balance[uint256(_token)] += _amount;
        userInfos[_user].valorDebt = _getUserTotalValorDebt(_user);

        emit Staked(_getNextEventId(0), _msgSender(), _amount, LedgerToken.ORDER);
    }

    /// @notice Create unstaking request for `_amount` of tokens
    function createUnstakeRequest(address _user, LedgerToken _token, uint256 _amount) external nonReentrant whenNotPaused {
        if (_amount == 0) revert AmountIsZero();
        if (userInfos[_user].balance[uint256(_token)] == 0) revert UserHasZeroBalance();

        _updateValorVars();
        _collectValor(_user);

        userInfos[_user].balance[uint256(_token)] -= _amount;
        pendingUnstakes[_user].balanceOrder += _amount;

        pendingUnstakes[_user].unlockTimestamp = block.timestamp + unstakeLockPeriod;
        userInfos[_user].valorDebt = _getUserTotalValorDebt(_user);

        emit UnstakeRequested(_getNextEventId(0), _msgSender(), _amount, _token);
    }

    /// @notice Cancel unstaking request
    function cancelUnstakeRequest(address _user) external nonReentrant whenNotPaused {
        if (pendingUnstakes[_user].unlockTimestamp == 0) revert NoPendingUnstakeRequest();

        _updateValorVars();
        _collectValor(_user);

        uint256 pendingAmountOrder = pendingUnstakes[_user].balanceOrder;

        if (pendingAmountOrder > 0) {
            userInfos[_user].balance[uint256(LedgerToken.ORDER)] += pendingAmountOrder;
            pendingUnstakes[_user].balanceOrder = 0;
        }

        userInfos[_user].valorDebt = _getUserTotalValorDebt(_user);
        pendingUnstakes[_user].unlockTimestamp = 0;

        emit UnstakeCancelled(_getNextEventId(0), _msgSender(), pendingAmountOrder);
    }

    /// @notice Withdraw unstaked $ORDER tokens
    function withdraw(address _user) external nonReentrant whenNotPaused {
        if (pendingUnstakes[_user].unlockTimestamp == 0) revert NoPendingUnstakeRequest();
        if (block.timestamp < pendingUnstakes[_user].unlockTimestamp) revert UnlockTimeNotPassedYet();

        if (pendingUnstakes[_user].balanceOrder > 0) {
            // orderToken.safeTransfer(_msgSender(), pendingUnstakes[_user].balanceOrder);
            emit Withdraw(_getNextEventId(0), _msgSender(), pendingUnstakes[_user].balanceOrder);
            pendingUnstakes[_user].balanceOrder = 0;
        }

        pendingUnstakes[_user].unlockTimestamp = 0;
    }

    /// @notice Claim reward for sender
    function claimReward(address _user) external nonReentrant whenNotPaused {
        if (_getUserHasZeroBalance(_user)) revert UserHasZeroBalance();
        _updateValorVars();
        _collectValor(_user);
    }

    /// @notice Update reward variables to be up-to-date.
    function updateValorVars() external {
        _updateValorVars();
    }

    /* ========== PRIVATE FUNCTIONS ========== */

    /// @notice Update reward variables to be up-to-date.
    function _updateValorVars() private {
        if (block.timestamp <= lastValorUpdateTimestamp) {
            return;
        }

        accValorPerShareScaled = _getCurrentAccValorPreShare();
        lastValorUpdateTimestamp = block.timestamp;

        emit UpdateValorVars(_getNextEventId(0), lastValorUpdateTimestamp, accValorPerShareScaled);
    }

    /// @notice Claim pending reward for a caller
    function _collectValor(address _user) private {
        uint256 pendingReward = _getPendingValor(_user);

        if (pendingReward > 0) {
            userInfos[_user].valorDebt += pendingReward;
            collectedValor[_user] += pendingReward;
        }
    }

    // ██████  ███████ ██    ██ ███████ ███    ██ ██    ██ ███████
    // ██   ██ ██      ██    ██ ██      ████   ██ ██    ██ ██
    // ██████  █████   ██    ██ █████   ██ ██  ██ ██    ██ █████
    // ██   ██ ██       ██  ██  ██      ██  ██ ██ ██    ██ ██
    // ██   ██ ███████   ████   ███████ ██   ████  ██████  ███████

    function redeemValor(address _user, uint256 _amount) external nonReentrant {
        if (_amount == 0) revert AmountIsZero();
        if (getUserValor(_user) < _amount) revert AmountIsGreaterThanPendingValor();

        _updateValorVars();
        _collectValor(_user);

        collectedValor[_user] -= _amount;

        uint16 currentBatchId = getCurrentBatchId();
        batches[currentBatchId].totalAmount += _amount;
        bool found = false;
        for (uint256 i = 0; i < userRevenue[_user].requests.length; i++) {
            if (userRevenue[_user].requests[i].batchId == currentBatchId) {
                userRevenue[_user].requests[i].amount += _amount;
                found = true;
                break;
            }
        }

        if (!found) {
            userRevenue[_user].requests.push(UserReremprionRequest({batchId: currentBatchId, amount: _amount}));
        }

        emit Redeemed(_getNextEventId(0), _user, found ? currentBatchId : 0, _amount);
    }
}
