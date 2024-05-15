// SPDX-License-Identifier: MIT
pragma solidity 0.8.22;

import {LedgerToken} from "orderly-omnichain-occ/contracts/OCCInterface.sol";
import {LedgerAccessControl} from "./LedgerAccessControl.sol";
import {ChainedEventIdCounter} from "./ChainedEventIdCounter.sol";
import {Valor} from "./Valor.sol";

abstract contract Staking is LedgerAccessControl, ChainedEventIdCounter, Valor {
    struct UserInfo {
        uint256[2] balance; // Amount of staken $ORDER and $esORDER
        uint256 valorDebt; // Amount of valor, that was already claimed by user
    }

    struct PendingUnstake {
        uint256 balanceOrder; // Amount of unstaked $ORDER; $esORDER unstake immediately
        uint256 unlockTimestamp; // Timestamp (block.timestamp) when unstaking amount will be unlocked
    }

    uint256 internal constant DEFAULT_UNSTAKE_LOCK_PERIOD = 7 days;
    uint256 internal constant ACC_VALOR_PER_SHARE_PRECISION = 1e18;

    mapping(address => UserInfo) internal userInfos;
    mapping(address => PendingUnstake) internal pendingUnstakes;

    uint256 public totalStakedAmount; // Total amount of staken $ORDER and $esORDER

    /// @notice The last time that the valor variables were updated
    uint256 public lastValorUpdateTimestamp;

    /// @notice The accrued valor share, scaled to `ACC_VALOR_PER_SHARE_PRECISION`
    uint256 public accValorPerShareScaled;

    /// @notice Period of time, that user have to wait after unstake request, before he can withdraw tokens
    uint256 public unstakeLockPeriod;

    /* ========== EVENTS ========== */

    event UpdateValorVars(uint256 eventId, uint256 lastValorUpdateTimestamp, uint256 accValorPerShareScaled);
    event Staked(uint256 eventId, address indexed staker, uint256 amount, LedgerToken token);
    event UnstakeRequested(uint256 eventId, address indexed staker, uint256 amount, LedgerToken token);
    event UnstakeCancelled(uint256 eventId, address indexed staker, uint256 pendingAmountOrder);
    event Withdraw(uint256 eventId, address indexed staker, uint256 amount);

    /* ========== ERRORS ========== */

    error OrderTokenAddressIsZero();
    error EsOrderTokenAddressIsZero();
    error UserHasZeroBalance();
    error AmountIsZero();
    error NoPendingUnstakeRequest();
    error UnlockTimeNotPassedYet();
    error UnstakeLockPeriodIsZero();
    error Unsupportedtoken();

    /* ========== INITIALIZER ========== */

    function stakingInit() internal onlyInitializing {
        unstakeLockPeriod = DEFAULT_UNSTAKE_LOCK_PERIOD;
        lastValorUpdateTimestamp = block.timestamp;
    }

    /* ========== REGULAR USER VIEW FUNCTIONS ========== */

    /// @notice Get the user info for a given user
    function getUserInfo(address _user) external view returns (UserInfo memory) {
        return userInfos[_user];
    }

    /// @notice Get the pending unstake request for a given user
    function getPendingUnstake(address _user) external view returns (PendingUnstake memory) {
        return pendingUnstakes[_user];
    }

    /// @notice Get the amount of $ORDER ready to be withdrawn by `_user`
    /// @return orderAmount The amount of $ORDER ready to be withdrawn by `_user`
    function getAvailableToWithdraw(address _user) external view returns (uint256 orderAmount) {
        PendingUnstake storage userPendingUnstake = pendingUnstakes[_user];
        if (userPendingUnstake.unlockTimestamp == 0 || block.timestamp < userPendingUnstake.unlockTimestamp) {
            return 0;
        }

        orderAmount = userPendingUnstake.balanceOrder;
    }

    /// @notice Get the pending amount of valor for a given user
    /// @param _user The user to lookup
    /// @return The number of pending valor tokens for `_user`
    function getUserValor(address _user) public returns (uint256) {
        return _getPendingValor(_user) + collectedValor[_user];
    }

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

    /* ========== INTERNAL FUNCTIONS ========== */

    /// @notice Update reward variables to be up-to-date.
    function _updateValorVars() internal {
        if (block.timestamp <= lastValorUpdateTimestamp) {
            return;
        }

        accValorPerShareScaled = _getCurrentAccValorPreShare();
        lastValorUpdateTimestamp = block.timestamp;

        emit UpdateValorVars(_getNextEventId(0), lastValorUpdateTimestamp, accValorPerShareScaled);
    }

    /// @notice Claim pending reward for a caller
    function _collectValor(address _user) internal {
        uint256 pendingReward = _getPendingValor(_user);

        if (pendingReward > 0) {
            userInfos[_user].valorDebt += pendingReward;
            collectedValor[_user] += pendingReward;
        }
    }

    /// @notice Checks to see if a given user currently has staked ORDER or esORDER
    /// @param _user The user to check
    /// @return Whether `_user` currently has staked tokens
    function _getUserHasZeroBalance(address _user) internal view returns (bool) {
        return userInfos[_user].balance[uint256(LedgerToken.ORDER)] + userInfos[_user].balance[uint256(LedgerToken.ESORDER)] == 0;
    }

    /// @notice Get current accrued valor share, updated to the current block
    function _getCurrentAccValorPreShare() internal returns (uint256) {
        if (block.timestamp <= lastValorUpdateTimestamp) {
            return accValorPerShareScaled;
        }

        uint256 accValorPerShareCurrentScaled = accValorPerShareScaled;
        uint256 secondsElapsed = block.timestamp - lastValorUpdateTimestamp;
        uint256 totalStaked = totalStakedAmount;
        if (secondsElapsed > 0 && totalStaked > 0) {
            uint256 valorEmission = secondsElapsed * valorPerSecond;
            if (totalValorEmitted + valorEmission > maximumValorEmission) {
                valorEmission = maximumValorEmission - totalValorEmitted;
            }
            totalValorEmitted += valorEmission;
            totalValorAmount += valorEmission;
            accValorPerShareCurrentScaled += ((valorEmission * ACC_VALOR_PER_SHARE_PRECISION) / totalStaked);
        }

        return accValorPerShareCurrentScaled;
    }

    /** @notice Get the pending amount of valor for a given user
     *          If user has zero staked balabce, then pending valor is zero
     * @param _user The user to lookup
     * @return The number of pending valor tokens for `_user`
     */
    function _getPendingValor(address _user) internal returns (uint256) {
        if (_getUserHasZeroBalance(_user)) {
            return 0;
        }

        uint256 accValorPerShareCurrentScaled = _getCurrentAccValorPreShare();
        return
            (((userInfos[_user].balance[uint256(LedgerToken.ORDER)] + userInfos[_user].balance[uint256(LedgerToken.ESORDER)]) *
                accValorPerShareCurrentScaled) / ACC_VALOR_PER_SHARE_PRECISION) - userInfos[_user].valorDebt;
    }

    /// @notice Get the total amount of valor debt for a given user
    /// @param _user The user to lookup
    /// @return The total amount of valor debt for `_user`
    function _getUserTotalValorDebt(address _user) internal view returns (uint256) {
        return
            ((userInfos[_user].balance[uint256(LedgerToken.ORDER)] + userInfos[_user].balance[uint256(LedgerToken.ESORDER)]) *
                accValorPerShareScaled) / ACC_VALOR_PER_SHARE_PRECISION;
    }
}
