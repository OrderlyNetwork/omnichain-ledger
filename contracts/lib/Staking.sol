// SPDX-License-Identifier: MIT
pragma solidity 0.8.22;

import {LedgerToken} from "orderly-omnichain-occ/contracts/OCCInterface.sol";
import {LedgerAccessControl} from "./LedgerAccessControl.sol";
import {ChainedEventIdCounter} from "./ChainedEventIdCounter.sol";
import {Valor} from "./Valor.sol";

abstract contract Staking is LedgerAccessControl, ChainedEventIdCounter, Valor {
    uint256 internal constant DEFAULT_UNSTAKE_LOCK_PERIOD = 7 days;
    uint256 internal constant ACC_VALOR_PER_SHARE_PRECISION = 1e18;

    struct StakingInfo {
        uint256[2] balance; // Amount of staken $ORDER and $esORDER
        uint256 valorDebt; // Amount of valor, that was already claimed by user
    }

    mapping(address => StakingInfo) public userStakingInfo;

    struct PendingUnstake {
        uint256 balanceOrder; // Amount of unstaked $ORDER; $esORDER unstake immediately
        uint256 unlockTimestamp; // Timestamp (block.timestamp) when unstaking amount will be unlocked
    }

    mapping(address => PendingUnstake) public userPendingUnstake;

    /// Total amount of staken $ORDER and $esORDER
    uint256 public totalStakedAmount;

    /// @notice The last time that the valor variables were updated
    uint256 public lastValorUpdateTimestamp;

    /// @notice The accrued valor share, scaled to `ACC_VALOR_PER_SHARE_PRECISION`
    uint256 public accValorPerShareScaled;

    /// @notice Period of time, that user have to wait after unstake request, before he can withdraw tokens
    uint256 public unstakeLockPeriod;

    /* ========== EVENTS ========== */

    event Staked(uint256 indexed chainedEventId, uint256 indexed chainId, address indexed staker, uint256 amount, LedgerToken token);
    event OrderUnstakeRequested(uint256 indexed chainedEventId, uint256 indexed chainId, address indexed staker, uint256 amount);
    event OrderUnstakeCancelled(uint256 indexed chainedEventId, uint256 indexed chainId, address indexed staker, uint256 pendingOrderAmount);
    event OrderWithdrawn(uint256 indexed chainedEventId, uint256 indexed chainId, address indexed staker, uint256 amount);
    event EsOrderUnstakeAndVest(uint256 indexed chainedEventId, uint256 indexed chainId, address indexed staker, uint256 amount);

    /* ========== ERRORS ========== */

    error UnsupportedToken();
    error AmountIsZero();
    error NoPendingUnstakeRequest();
    error UnlockTimeNotPassedYet();

    /* ========== INITIALIZER ========== */

    function stakingInit(address) internal onlyInitializing {
        unstakeLockPeriod = DEFAULT_UNSTAKE_LOCK_PERIOD;
        lastValorUpdateTimestamp = block.timestamp;
    }

    /* ========== VIEW FUNCTIONS ========== */

    /// @notice Get the total amount of $ORDER and $esORDER staked by `_user`
    function userTotalStakingBalance(address _user) public view returns (uint256) {
        return userStakingInfo[_user].balance[uint256(LedgerToken.ORDER)] + userStakingInfo[_user].balance[uint256(LedgerToken.ESORDER)];
    }

    /// @notice Get the amount of $ORDER ready to be withdrawn by `_user`
    function getOrderAvailableToWithdraw(address _user) public view returns (uint256 orderAmount) {
        PendingUnstake storage pendingUnstake = userPendingUnstake[_user];
        if (pendingUnstake.unlockTimestamp == 0 || block.timestamp < pendingUnstake.unlockTimestamp) {
            return 0;
        }

        orderAmount = pendingUnstake.balanceOrder;
    }

    /// @notice Get the pending amount of valor for a given user
    function getUserValor(address _user) public view returns (uint256) {
        return _getPendingValor(_user) + collectedValor[_user];
    }

    /* ========== USER FUNCTIONS ========== */

    /// @notice Stake tokens from LedgerToken list for a given user
    /// For now only $ORDER and es$ORDER tokens are supported
    function _stake(address _user, uint256 _chainId, LedgerToken _token, uint256 _amount) internal nonReentrant whenNotPaused {
        if (_amount == 0) revert AmountIsZero();
        if (_token > LedgerToken.ESORDER) revert UnsupportedToken();

        _updateValorVarsAndCollectValor(_user);

        userStakingInfo[_user].balance[uint256(_token)] += _amount;
        userStakingInfo[_user].valorDebt = _getUserTotalValorDebt(_user);
        totalStakedAmount += _amount;

        emit Staked(_getNextChainedEventId(_chainId), _chainId, _user, _amount, _token);
    }

    /// @notice Create unstaking request for `_amount` of $ORDER tokens
    /// If user has unstaking request, then it's amount will be updated but unlock time will reset to `unstakeLockPeriod` from now
    function _createOrderUnstakeRequest(address _user, uint256 _chainId, uint256 _amount) internal nonReentrant whenNotPaused {
        if (_amount == 0) revert AmountIsZero();

        _updateValorVarsAndCollectValor(_user);

        // If user has insufficient $ORDER balance, then next operation will be reverted
        userStakingInfo[_user].balance[uint256(LedgerToken.ORDER)] -= _amount;
        userStakingInfo[_user].valorDebt = _getUserTotalValorDebt(_user);
        totalStakedAmount -= _amount;
        userPendingUnstake[_user].balanceOrder += _amount;
        userPendingUnstake[_user].unlockTimestamp = block.timestamp + unstakeLockPeriod;

        emit OrderUnstakeRequested(_getNextChainedEventId(_chainId), _chainId, _user, _amount);
    }

    /// @notice Cancel unstaking request for $ORDER tokens and re-stake them
    function _cancelOrderUnstakeRequest(address _user, uint256 _chainId) internal nonReentrant whenNotPaused returns (uint256) {
        if (userPendingUnstake[_user].unlockTimestamp == 0) revert NoPendingUnstakeRequest();

        _updateValorVarsAndCollectValor(_user);

        uint256 pendingOrderAmount = userPendingUnstake[_user].balanceOrder;

        if (pendingOrderAmount > 0) {
            userStakingInfo[_user].balance[uint256(LedgerToken.ORDER)] += pendingOrderAmount;
            userStakingInfo[_user].valorDebt = _getUserTotalValorDebt(_user);
            totalStakedAmount += pendingOrderAmount;
            userPendingUnstake[_user].balanceOrder = 0;
            userPendingUnstake[_user].unlockTimestamp = 0;

            emit OrderUnstakeCancelled(_getNextChainedEventId(_chainId), _chainId, _user, pendingOrderAmount);
        }

        return pendingOrderAmount;
    }

    /// @notice Withdraw unstaked $ORDER tokens
    function _withdrawOrder(address _user, uint256 _chainId) internal nonReentrant whenNotPaused returns (uint256) {
        if (userPendingUnstake[_user].unlockTimestamp == 0) revert NoPendingUnstakeRequest();
        if (block.timestamp < userPendingUnstake[_user].unlockTimestamp) revert UnlockTimeNotPassedYet();

        uint256 orderAmountForWithdraw = userPendingUnstake[_user].balanceOrder;
        if (orderAmountForWithdraw > 0) {
            userPendingUnstake[_user].balanceOrder = 0;
            userPendingUnstake[_user].unlockTimestamp = 0;

            emit OrderWithdrawn(_getNextChainedEventId(_chainId), _chainId, _user, userPendingUnstake[_user].balanceOrder);
        }

        return orderAmountForWithdraw;
    }

    /// @notice Unstake es$ORDER tokens and vest them to ORDER in Vesting contract
    function _esOrderUnstakeAndVest(address _user, uint256 _chainId, uint256 _amount) internal {
        if (_amount == 0) revert AmountIsZero();

        _updateValorVarsAndCollectValor(_user);

        // If user has insufficient es$ORDER balance, then next operation will be reverted
        userStakingInfo[_user].balance[uint256(LedgerToken.ESORDER)] -= _amount;
        userStakingInfo[_user].valorDebt = _getUserTotalValorDebt(_user);
        totalStakedAmount -= _amount;

        emit EsOrderUnstakeAndVest(_getNextChainedEventId(_chainId), _chainId, _user, _amount);

        // TODO: create vesting request in Vesting contract
    }

    /* ========== INTERNAL FUNCTIONS ========== */

    /// @notice Convert pending valor to collected valor for user
    /// Should be called before any operation with user balance:
    /// stake, unstake, cancel unstake, redeem valor
    function _updateValorVarsAndCollectValor(address _user) internal {
        _updatedAccValorPerShare();

        uint256 pendingValor = _getPendingValor(_user);
        if (pendingValor > 0) {
            userStakingInfo[_user].valorDebt += pendingValor;
            collectedValor[_user] += pendingValor;
        }
    }

    /// @notice Get the pending amount of valor for a given user
    function _getPendingValor(address _user) private view returns (uint256) {
        return _getUserTotalValorDebt(_user) - userStakingInfo[_user].valorDebt;
    }

    /// @notice Get the total amount of valor debt for a given user
    function _getUserTotalValorDebt(address _user) private view returns (uint256) {
        return (userTotalStakingBalance(_user) * accValorPerShareScaled) / ACC_VALOR_PER_SHARE_PRECISION;
    }

    /// @notice Get current accrued valor share, updated to the current block
    function _updatedAccValorPerShare() private {
        if (block.timestamp > lastValorUpdateTimestamp) {
            if (totalStakedAmount > 0) {
                uint256 secondsElapsed = block.timestamp - lastValorUpdateTimestamp;
                uint256 valorEmission = secondsElapsed * valorPerSecond;
                if (totalValorEmitted + valorEmission > maximumValorEmission) {
                    valorEmission = maximumValorEmission - totalValorEmitted;
                }
                totalValorEmitted += valorEmission;
                totalValorAmount += valorEmission;
                accValorPerShareScaled += ((valorEmission * ACC_VALOR_PER_SHARE_PRECISION) / totalStakedAmount);
                lastValorUpdateTimestamp = block.timestamp;
            }
        }
    }
}
