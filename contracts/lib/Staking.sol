// SPDX-License-Identifier: MIT
pragma solidity 0.8.22;

import {LedgerToken} from "./OCCTypes.sol";
import {LedgerAccessControl} from "./LedgerAccessControl.sol";
import {ChainedEventIdCounter} from "./ChainedEventIdCounter.sol";
import {Valor} from "./Valor.sol";

/**
 * @title Staking
 * @author Orderly Network
 * @notice Staking $ORDER and es$ORDER (record based) tokens to earn valor
 * Only $ORDER and es$ORDER tokens can be staked
 * Staked $ORDER and es$ORDER counts separately in StakingInfo but have equal weight in calculation of valor
 * User can unstake es$ORDER tokens immediately. Unstaked es$ORDER tokens will be vested to $ORDER in Vesting contract by Ledger contract
 * User can unstake $ORDER tokens after `unstakeLockPeriod` time (7 days by default) to de-incentivize unstaking
 * User have only one unstaking request for $ORDER at a time. Repeated unstake operations increase unstaking amounts but reset unlockTimestamp for whole unstaking.
 * After `unstakeLockPeriod` user can withdraw $ORDER tokens to his wallet on the Vault chain
 * User can cancel unstaking request for $ORDER any time. In this case amounts of $ORDER, that pending for unstake immediately adds to stakind amount and become count in valor calculation again.
 * When user make unstaking, amounts of $ORDER and es$ORDER, that pending for unstake, immediately subtract from staking amount and does not count in valor calculation.
 */
abstract contract Staking is LedgerAccessControl, ChainedEventIdCounter, Valor {
    uint256 internal constant DEFAULT_UNSTAKE_LOCK_PERIOD = 7 days;
    uint256 internal constant ACC_VALOR_PER_SHARE_PRECISION = 1e18;

    struct StakingInfo {
        uint256[2] balance; // Amount of staken $ORDER and es$ORDER
        uint256 valorDebt; // Amount of valor, that was already claimed by user
    }

    mapping(address => StakingInfo) private userStakingInfo;

    struct PendingUnstake {
        uint256 balanceOrder; // Amount of unstaked $ORDER; es$ORDER unstake immediately
        uint256 unlockTimestamp; // Timestamp (block.timestamp) when unstaking amount will be unlocked
    }

    mapping(address => PendingUnstake) public userPendingUnstake;

    /// Total amount of staken $ORDER and es$ORDER
    uint256 public totalStakedAmount;

    /// @notice The last time that the valor variables were updated
    uint256 public lastValorUpdateTimestamp;

    /// @notice The accrued valor share, scaled to `ACC_VALOR_PER_SHARE_PRECISION`
    uint256 public accValorPerShareScaled;

    /// @notice Period of time, that user have to wait after unstake request, before he can withdraw tokens
    uint256 public unstakeLockPeriod;

    /* ========== EVENTS ========== */

    /// @notice Emitted when user stakes $ORDER or es$ORDER tokens
    event Staked(uint256 indexed chainedEventId, uint256 indexed chainId, address indexed staker, uint256 amount, LedgerToken token);

    /// @notice Emitted when user requests unstake $ORDER tokens
    event OrderUnstakeRequested(uint256 indexed chainedEventId, uint256 indexed chainId, address indexed staker, uint256 amount);

    /// @notice Emitted when user cancels unstake $ORDER tokens request
    event OrderUnstakeCancelled(uint256 indexed chainedEventId, uint256 indexed chainId, address indexed staker, uint256 pendingOrderAmount);

    /// @notice Emitted when user withdraws $ORDER tokens
    event OrderWithdrawn(uint256 indexed chainedEventId, uint256 indexed chainId, address indexed staker, uint256 amount);

    /// @notice Emitted when user unstakes es$ORDER tokens
    event EsOrderUnstake(uint256 indexed chainedEventId, uint256 indexed chainId, address indexed staker, uint256 amount);

    /// @notice Emitted for _createOrderUnstakeRequest, _cancelOrderUnstakeRequest and _withdrawOrder functions
    event OrderUnstakeAmount(address indexed staker, uint256 totalUnstakedAmount, uint256 unlockTimestamp);

    /* ========== ERRORS ========== */

    error UnsupportedToken();
    error AmountIsZero();
    error StakingBalanceInsufficient(LedgerToken token);
    error NoPendingUnstakeRequest();
    error UnlockTimeNotPassedYet();

    /* ========== INITIALIZER ========== */

    function stakingInit(address, uint256 _unstakeLockPeriod) internal onlyInitializing {
        unstakeLockPeriod = _unstakeLockPeriod;
        lastValorUpdateTimestamp = block.timestamp;
    }

    /* ========== VIEW FUNCTIONS ========== */

    /// @notice Get the staking balances for a given _user
    function getStakingInfo(address _user) external view returns (uint256 orderBalance, uint256 esOrderBalance) {
        return (userStakingInfo[_user].balance[uint256(LedgerToken.ORDER)], userStakingInfo[_user].balance[uint256(LedgerToken.ESORDER)]);
    }

    /// @notice Get the total amount of $ORDER and es$ORDER staked by `_user`
    function userTotalStakingBalance(address _user) public view returns (uint256) {
        return userStakingInfo[_user].balance[uint256(LedgerToken.ORDER)] + userStakingInfo[_user].balance[uint256(LedgerToken.ESORDER)];
    }

    /// @notice Get the amount of $ORDER ready to be withdrawn by `_user`
    function getOrderAvailableToWithdraw(address _user) external view returns (uint256 orderAmount) {
        PendingUnstake storage pendingUnstake = userPendingUnstake[_user];
        if (pendingUnstake.unlockTimestamp == 0 || block.timestamp < pendingUnstake.unlockTimestamp) {
            return 0;
        }

        orderAmount = pendingUnstake.balanceOrder;
    }

    /// @notice Get the pending amount of valor up to now for a given _user
    function getUserValor(address _user) external view returns (uint256) {
        return _getPendingValor(_user) + collectedValor[_user];
    }

    /// @notice Calculate and update valor per share changed over time
    function updateValorVars() public whenNotPaused {
        if (block.timestamp > lastValorUpdateTimestamp) {
            accValorPerShareScaled = _getCurrentAccValorPreShareScaled();
            lastValorUpdateTimestamp = block.timestamp;
        }
    }

    /* ========== USER FUNCTIONS ========== */

    /// @notice Stake tokens from LedgerToken list for a given user
    /// For now only $ORDER and es$ORDER tokens are supported
    function _stake(address _user, uint256 _chainId, LedgerToken _token, uint256 _amount) internal nonReentrant whenNotPaused {
        if (_amount == 0) revert AmountIsZero();
        if (_token > LedgerToken.ESORDER) revert UnsupportedToken();

        _updateValorVarsAndCollectUserValor(_user);

        userStakingInfo[_user].balance[uint256(_token)] += _amount;
        userStakingInfo[_user].valorDebt = _getUserTotalValorDebt(_user);
        totalStakedAmount += _amount;

        emit Staked(_getNextChainedEventId(_chainId), _chainId, _user, _amount, _token);
    }

    /// @notice Create unstaking request for `_amount` of $ORDER tokens
    /// If user has unstaking request, then it's amount will be updated but unlock time will reset to `unstakeLockPeriod` from now
    function _createOrderUnstakeRequest(address _user, uint256 _chainId, uint256 _amount) internal nonReentrant whenNotPaused {
        if (_amount == 0) revert AmountIsZero();

        if (userStakingInfo[_user].balance[uint256(LedgerToken.ORDER)] < _amount) revert StakingBalanceInsufficient(LedgerToken.ORDER);

        _updateValorVarsAndCollectUserValor(_user);

        userStakingInfo[_user].balance[uint256(LedgerToken.ORDER)] -= _amount;
        userStakingInfo[_user].valorDebt = _getUserTotalValorDebt(_user);
        totalStakedAmount -= _amount;
        userPendingUnstake[_user].balanceOrder += _amount;
        userPendingUnstake[_user].unlockTimestamp = block.timestamp + unstakeLockPeriod;

        emit OrderUnstakeRequested(_getNextChainedEventId(_chainId), _chainId, _user, _amount);
        emit OrderUnstakeAmount(_user, userPendingUnstake[_user].balanceOrder, userPendingUnstake[_user].unlockTimestamp);
    }

    /// @notice Cancel unstaking request for $ORDER tokens and re-stake them
    function _cancelOrderUnstakeRequest(address _user, uint256 _chainId) internal nonReentrant whenNotPaused returns (uint256 pendingOrderAmount) {
        if (userPendingUnstake[_user].unlockTimestamp == 0) revert NoPendingUnstakeRequest();

        _updateValorVarsAndCollectUserValor(_user);

        pendingOrderAmount = userPendingUnstake[_user].balanceOrder;

        userStakingInfo[_user].balance[uint256(LedgerToken.ORDER)] += pendingOrderAmount;
        userStakingInfo[_user].valorDebt = _getUserTotalValorDebt(_user);
        totalStakedAmount += pendingOrderAmount;

        emit OrderUnstakeCancelled(_getNextChainedEventId(_chainId), _chainId, _user, pendingOrderAmount);

        userPendingUnstake[_user].balanceOrder = 0;
        userPendingUnstake[_user].unlockTimestamp = 0;
        emit OrderUnstakeAmount(_user, 0, 0);
    }

    /// @notice Withdraw unstaked $ORDER tokens. Contract does not tansfer tokens to user, it just returns amount of tokens to Ledger
    /// Caller (Ledger contract) should transfer tokens to user
    function _withdrawOrder(address _user, uint256 _chainId) internal nonReentrant whenNotPaused returns (uint256 orderAmountForWithdraw) {
        if (userPendingUnstake[_user].unlockTimestamp == 0) revert NoPendingUnstakeRequest();
        if (block.timestamp < userPendingUnstake[_user].unlockTimestamp) revert UnlockTimeNotPassedYet();

        orderAmountForWithdraw = userPendingUnstake[_user].balanceOrder;
        if (orderAmountForWithdraw > 0) {
            emit OrderWithdrawn(_getNextChainedEventId(_chainId), _chainId, _user, orderAmountForWithdraw);

            userPendingUnstake[_user].balanceOrder = 0;
            userPendingUnstake[_user].unlockTimestamp = 0;
            emit OrderUnstakeAmount(_user, 0, 0);
        }
    }

    /// @notice Unstake es$ORDER tokens immediately.
    /// Caller (Ledger contract) should vest _amount of es$ORDER tokens to Vesting contract
    function _esOrderUnstake(address _user, uint256 _chainId, uint256 _amount) internal nonReentrant whenNotPaused {
        if (_amount == 0) revert AmountIsZero();

        if (userStakingInfo[_user].balance[uint256(LedgerToken.ESORDER)] < _amount) revert StakingBalanceInsufficient(LedgerToken.ESORDER);

        _updateValorVarsAndCollectUserValor(_user);

        userStakingInfo[_user].balance[uint256(LedgerToken.ESORDER)] -= _amount;
        userStakingInfo[_user].valorDebt = _getUserTotalValorDebt(_user);
        totalStakedAmount -= _amount;

        emit EsOrderUnstake(_getNextChainedEventId(_chainId), _chainId, _user, _amount);
    }

    /* ========== INTERNAL FUNCTIONS ========== */

    /// @notice Convert pending valor to collected valor for user
    /// Should be called before any operation with user balance:
    /// stake, unstake, cancel unstake, redeem valor
    function _updateValorVarsAndCollectUserValor(address _user) internal {
        updateValorVars();

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
        return (userTotalStakingBalance(_user) * _getCurrentAccValorPreShareScaled()) / ACC_VALOR_PER_SHARE_PRECISION;
    }

    /// @notice Get current accrued valor share, updated to the current block
    function _getCurrentAccValorPreShareScaled() private view returns (uint256) {
        if (block.timestamp <= lastValorUpdateTimestamp || totalStakedAmount == 0) {
            return accValorPerShareScaled;
        }

        uint256 accValorPerShareCurrentScaled = accValorPerShareScaled;
        uint256 secondsElapsed = block.timestamp - lastValorUpdateTimestamp;
        uint256 valorEmission = secondsElapsed * valorPerSecond;
        if (totalValorEmitted + valorEmission > maximumValorEmission) {
            valorEmission = maximumValorEmission - totalValorEmitted;
        }
        accValorPerShareCurrentScaled += ((valorEmission * ACC_VALOR_PER_SHARE_PRECISION) / totalStakedAmount);
        return accValorPerShareCurrentScaled;
    }
}
