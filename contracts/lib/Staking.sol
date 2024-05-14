// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import { LedgerToken } from "./Common.sol";

abstract contract Staking {
    struct UserInfo {
        uint256[2] balance; // Amount of staken $ORDER and $esORDER
        uint256 rewardDebt; // Amount of reward, that was already claimed by user
    }

    struct PendingUnstake {
        uint256 balanceOrder;    // Amount of unstaked $ORDER; $esORDER unstake immediately
        uint256 unlockTimestamp; // Timestamp (block.timestamp) when unstaking amount will be unlocked
    }

    uint256[2] public totalStakedAmounts; // Total amount of staken $ORDER and $esORDER

    uint256 internal constant MAX_REWARD_PER_SECOND = 1 ether;
    uint256 internal constant DEFAULT_UNSTAKE_LOCK_PERIOD = 7 days;
    uint256 internal constant ACC_REWARD_PER_SHARE_PRECISION = 1e18;

    mapping(address => UserInfo) internal userInfos;
    mapping(address => PendingUnstake) internal pendingUnstakes;

    mapping(address => uint256) public collectedRewards;

    /// @notice The last time that the reward variables were updated
    uint256 public lastRewardUpdateTimestamp;

    /// @notice The amount of reward token, that will be emitted per second
    uint256 public rewardPerSecond;

    /// @notice The accrued reward share, scaled to `ACC_REWARD_PER_SHARE_PRECISION`
    uint256 public accRewardPerShareScaled;

    /// @notice Period of time, that user have to wait after unstake request, before he can withdraw tokens
    uint256 public unstakeLockPeriod;

    /* ========== EVENTS ========== */

    event UpdateRewardVars(uint256 eventId, uint256 lastRewardUpdateTimestamp, uint256 accRewardPerShareScaled);
    event Staked(
        uint256 eventId,
        address indexed staker,
        uint256 amount,
        LedgerToken token
    );
    event UnstakeRequested(
        uint256 eventId,
        address indexed staker,
        uint256 amount,
        LedgerToken token
    );
    event UnstakeCancelled(
        uint256 eventId,
        address indexed staker,
        uint256 pendingAmountOrder
    );
    event Withdraw(uint256 eventId, address indexed staker, uint256 amount);

    /* ========== ERRORS ========== */

    error OrderTokenAddressIsZero();
    error EsOrderTokenAddressIsZero();
    error RewardTokenAddressIsZero();
    error RewardPerSecondExceedsMaxValue();
    error UserHasZeroBalance();
    error AmountIsZero();
    error NoPendingUnstakeRequest();
    error UnlockTimeNotPassedYet();
    error UnstakeLockPeriodIsZero();
    error Unsupportedtoken();

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

    /// @notice Get the pending amount of reward for a given user
    /// @param _user The user to lookup
    /// @return The number of pending reward tokens for `_user`
    function getPendingReward(address _user) external view returns (uint256) {
        return _getPendingReward(_user);
    }

    /* ========== INTERNAL FUNCTIONS ========== */

    /// @notice Checks to see if a given user currently has staked ORDER or esORDER
    /// @param _user The user to check
    /// @return Whether `_user` currently has staked tokens
    function _getUserHasZeroBalance(address _user) internal view returns (bool) {
        return userInfos[_user].balance[uint256(LedgerToken.ORDER)] + userInfos[_user].balance[uint256(LedgerToken.ESORDER)] == 0;
    }

    /// @notice Get the total amount of staked ORDER and esORDER
    /// @return The total amount of staked ORDER and esORDER
    function _getTotalStaked() internal view returns (uint256) {
        return totalStakedAmounts[uint256(LedgerToken.ORDER)] + totalStakedAmounts[uint256(LedgerToken.ESORDER)];
    }

    /// @notice Get current accrued reward share, updated to the current block
    function _getCurrentAccRewardPreShare() internal view returns (uint256) {
        if (block.timestamp <= lastRewardUpdateTimestamp) {
            return accRewardPerShareScaled;
        }

        uint256 accRewardPerShareCurrentScaled = accRewardPerShareScaled;
        uint256 secondsElapsed = block.timestamp - lastRewardUpdateTimestamp;
        uint256 totalStaked = _getTotalStaked();
        if (secondsElapsed > 0 && totalStaked > 0) {
            uint256 rewardEmission = secondsElapsed * rewardPerSecond;
            accRewardPerShareCurrentScaled += ((rewardEmission * ACC_REWARD_PER_SHARE_PRECISION) / totalStaked);
        }

        return accRewardPerShareCurrentScaled;
    }

    /// @notice Get the pending amount of reward for a given user
    /// @param _user The user to lookup
    /// @return The number of pending reward tokens for `_user`
    function _getPendingReward(address _user) internal view returns (uint256) {
        if (_getUserHasZeroBalance(_user)) {
            return 0;
        }

        uint256 accRewardPerShareCurrentScaled = _getCurrentAccRewardPreShare();
        return (
            (
                (userInfos[_user].balance[uint256(LedgerToken.ORDER)] + userInfos[_user].balance[uint256(LedgerToken.ESORDER)])
                    * accRewardPerShareCurrentScaled
            ) / ACC_REWARD_PER_SHARE_PRECISION
        ) - userInfos[_user].rewardDebt;
    }

    /// @notice Get the total amount of reward debt for a given user
    /// @param _user The user to lookup
    /// @return The total amount of reward debt for `_user`
    function _getUserTotalRewardDebt(address _user) internal view returns (uint256) {
        return (
            (userInfos[_user].balance[uint256(LedgerToken.ORDER)] + userInfos[_user].balance[uint256(LedgerToken.ESORDER)])
                * accRewardPerShareScaled
        ) / ACC_REWARD_PER_SHARE_PRECISION;
    }


}
