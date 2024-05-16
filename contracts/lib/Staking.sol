// SPDX-License-Identifier: MIT
pragma solidity 0.8.22;

import {LedgerToken} from "orderly-omnichain-occ/contracts/OCCInterface.sol";
import {LedgerAccessControl} from "./LedgerAccessControl.sol";
import {ChainedEventIdCounter} from "./ChainedEventIdCounter.sol";
import {Valor} from "./Valor.sol";

abstract contract Staking is LedgerAccessControl, ChainedEventIdCounter, Valor {
    uint256 internal constant DEFAULT_UNSTAKE_LOCK_PERIOD = 7 days;
    uint256 internal constant ACC_VALOR_PER_SHARE_PRECISION = 1e18;

    struct UserInfo {
        uint256[2] balance; // Amount of staken $ORDER and $esORDER
        uint256 valorDebt; // Amount of valor, that was already claimed by user
    }

    mapping(address => UserInfo) public userInfos;

    struct PendingUnstake {
        uint256 balanceOrder; // Amount of unstaked $ORDER; $esORDER unstake immediately
        uint256 unlockTimestamp; // Timestamp (block.timestamp) when unstaking amount will be unlocked
    }

    mapping(address => PendingUnstake) public pendingUnstakes;

    /// Total amount of staken $ORDER and $esORDER
    uint256 public totalStakedAmount;

    /// @notice The last time that the valor variables were updated
    uint256 public lastValorUpdateTimestamp;

    /// @notice The accrued valor share, scaled to `ACC_VALOR_PER_SHARE_PRECISION`
    uint256 public accValorPerShareScaled;

    /// @notice Period of time, that user have to wait after unstake request, before he can withdraw tokens
    uint256 public unstakeLockPeriod;

    /* ========== EVENTS ========== */

    event UpdateValorVars(uint256 eventId, uint256 lastValorUpdateTimestamp, uint256 accValorPerShareScaled);
    event Staked(uint256 indexed chainedEventId, uint256 indexed chainId, address indexed staker, uint256 amount, LedgerToken token);
    event OrderUnstakeRequested(uint256 indexed chainedEventId, uint256 indexed chainId, address indexed staker, uint256 amount);
    event OrderUnstakeCancelled(uint256 indexed chainedEventId, uint256 indexed chainId, address indexed staker, uint256 pendingOrderAmount);
    event OrderWithdrawn(uint256 indexed chainedEventId, uint256 indexed chainId, address indexed staker, uint256 amount);
    event EsOrderUnstakeAndVest(uint256 indexed chainedEventId, uint256 indexed chainId, address indexed staker, uint256 amount);

    /* ========== ERRORS ========== */

    error OrderTokenAddressIsZero();
    error EsOrderTokenAddressIsZero();
    error UserHasZeroBalance();
    error AmountIsZero();
    error NoPendingUnstakeRequest();
    error UnlockTimeNotPassedYet();
    error UnstakeLockPeriodIsZero();
    error UnsupportedToken();

    /* ========== INITIALIZER ========== */

    function stakingInit() internal onlyInitializing {
        unstakeLockPeriod = DEFAULT_UNSTAKE_LOCK_PERIOD;
        lastValorUpdateTimestamp = block.timestamp;
    }

    /* ========== VIEW FUNCTIONS ========== */

    /// @notice Get the amount of $ORDER ready to be withdrawn by `_user`
    function getOrderAvailableToWithdraw(address _user) external view returns (uint256 orderAmount) {
        PendingUnstake storage userPendingUnstake = pendingUnstakes[_user];
        if (userPendingUnstake.unlockTimestamp == 0 || block.timestamp < userPendingUnstake.unlockTimestamp) {
            return 0;
        }

        orderAmount = userPendingUnstake.balanceOrder;
    }

    /// @notice Get the pending amount of valor for a given user
    function getUserValor(address _user) public returns (uint256) {
        return _getPendingValor(_user) + collectedValor[_user];
    }

    /* ========== CALL FUNCTIONS ========== */

    /// @notice Stake tokens from LedgerToken list for a given user
    /// For now only $ORDER and es$ORDER tokens are supported
    function stake(address _user, uint256 _chainId, LedgerToken _token, uint256 _amount) internal nonReentrant whenNotPaused {
        if (_amount == 0) revert AmountIsZero();
        if (_token > LedgerToken.ESORDER) revert UnsupportedToken();

        _updateValorVars();
        _collectValor(_user);

        userInfos[_user].balance[uint256(_token)] += _amount;
        userInfos[_user].valorDebt = _getUserTotalValorDebt(_user);
        totalStakedAmount += _amount;

        emit Staked(_getNextChainedEventId(_chainId), _chainId, _user, _amount, _token);
    }

    /// @notice Create unstaking request for `_amount` of $ORDER tokens
    /// If user has unstaking request, then it's amount will be updated but unlock time will reset to `unstakeLockPeriod` from now
    function createOrderUnstakeRequest(address _user, uint256 _chainId, uint256 _amount) internal nonReentrant whenNotPaused {
        if (_amount == 0) revert AmountIsZero();

        _updateValorVars();
        _collectValor(_user);

        // If user has insufficient $ORDER balance, then next operation will be reverted
        userInfos[_user].balance[uint256(LedgerToken.ORDER)] -= _amount;
        userInfos[_user].valorDebt = _getUserTotalValorDebt(_user);
        totalStakedAmount -= _amount;
        pendingUnstakes[_user].balanceOrder += _amount;
        pendingUnstakes[_user].unlockTimestamp = block.timestamp + unstakeLockPeriod;

        emit OrderUnstakeRequested(_getNextChainedEventId(_chainId), _chainId, _user, _amount);
    }

    /// @notice Cancel unstaking request for $ORDER tokens and re-stake them
    function cancelOrderUnstakeRequest(address _user, uint256 _chainId) internal nonReentrant whenNotPaused returns (uint256) {
        if (pendingUnstakes[_user].unlockTimestamp == 0) revert NoPendingUnstakeRequest();

        _updateValorVars();
        _collectValor(_user);

        uint256 pendingOrderAmount = pendingUnstakes[_user].balanceOrder;

        if (pendingOrderAmount > 0) {
            userInfos[_user].balance[uint256(LedgerToken.ORDER)] += pendingOrderAmount;
            userInfos[_user].valorDebt = _getUserTotalValorDebt(_user);
            totalStakedAmount += pendingOrderAmount;
            pendingUnstakes[_user].balanceOrder = 0;
            pendingUnstakes[_user].unlockTimestamp = 0;

            emit OrderUnstakeCancelled(_getNextChainedEventId(_chainId), _chainId, _user, pendingOrderAmount);
        }

        return pendingOrderAmount;
    }

    /// @notice Withdraw unstaked $ORDER tokens
    function withdrawOrder(address _user, uint256 _chainId) internal nonReentrant whenNotPaused returns (uint256) {
        if (pendingUnstakes[_user].unlockTimestamp == 0) revert NoPendingUnstakeRequest();
        if (block.timestamp < pendingUnstakes[_user].unlockTimestamp) revert UnlockTimeNotPassedYet();

        uint256 orderAmountForWithdraw = pendingUnstakes[_user].balanceOrder;
        if (orderAmountForWithdraw > 0) {
            pendingUnstakes[_user].balanceOrder = 0;
            pendingUnstakes[_user].unlockTimestamp = 0;

            emit OrderWithdrawn(_getNextChainedEventId(_chainId), _chainId, _user, pendingUnstakes[_user].balanceOrder);
        }

        return orderAmountForWithdraw;
    }

    /// @notice Unstake es$ORDER tokens and vest them to ORDER in Vesting contract
    function esOrderUnstakeAndVest(address _user, uint256 _chainId, uint256 _amount) internal {
        if (_amount == 0) revert AmountIsZero();

        _updateValorVars();
        _collectValor(_user);

        // If user has insufficient es$ORDER balance, then next operation will be reverted
        userInfos[_user].balance[uint256(LedgerToken.ESORDER)] -= _amount;
        userInfos[_user].valorDebt = _getUserTotalValorDebt(_user);
        totalStakedAmount -= _amount;

        emit EsOrderUnstakeAndVest(_getNextChainedEventId(_chainId), _chainId, _user, _amount);

        // TODO: create vesting request in Vesting contract
    }

    /* ========== INTERNAL FUNCTIONS ========== */

    /// @notice Update reward variables to be up-to-date.
    function _updateValorVars() internal {
        if (block.timestamp <= lastValorUpdateTimestamp) {
            return;
        }

        accValorPerShareScaled = _getCurrentAccValorPerShare();
        lastValorUpdateTimestamp = block.timestamp;

        emit UpdateValorVars(_getNextChainedEventId(0), lastValorUpdateTimestamp, accValorPerShareScaled);
    }

    /// @notice Convert pending valor to collected valor for user
    function _collectValor(address _user) internal {
        uint256 pendingReward = _getPendingValor(_user);

        if (pendingReward > 0) {
            userInfos[_user].valorDebt += pendingReward;
            collectedValor[_user] += pendingReward;
        }
    }

    /// @notice Checks to see if a given user currently has staked ORDER or esORDER
    function _userTotalStakingBalance(address _user) internal view returns (uint256) {
        return userInfos[_user].balance[uint256(LedgerToken.ORDER)] + userInfos[_user].balance[uint256(LedgerToken.ESORDER)];
    }

    /// @notice Get current accrued valor share, updated to the current block
    function _getCurrentAccValorPerShare() internal returns (uint256) {
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

    /// @notice Get the pending amount of valor for a given user
    ///         If user has zero staked balabce, then pending valor is zero
    function _getPendingValor(address _user) internal returns (uint256) {
        if (_userTotalStakingBalance(_user) == 0) return 0;

        return _getUserTotalValorDebt(_user) - userInfos[_user].valorDebt;
    }

    /// @notice Get the total amount of valor debt for a given user
    function _getUserTotalValorDebt(address _user) internal returns (uint256) {
        return (_userTotalStakingBalance(_user) * _getCurrentAccValorPerShare()) / ACC_VALOR_PER_SHARE_PRECISION;
    }
}
