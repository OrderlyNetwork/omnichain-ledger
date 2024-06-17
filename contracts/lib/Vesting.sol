// SPDX-License-Identifier: MIT
pragma solidity 0.8.22;

import {LedgerToken} from "./OCCTypes.sol";
import {LedgerAccessControl} from "./LedgerAccessControl.sol";
import {ChainedEventIdCounter} from "./ChainedEventIdCounter.sol";
import {Staking} from "./Staking.sol";

/**
 * @title Vesting
 * @author Orderly Network
 * @notice Vesting es$ORDER to $ORDER tokens
 * Full vesting period is 90 days and it is divided into two parts:
 * 1. Lock period - 15 days
 * 2. Linear period - 75 days
 * During lock period user can not withdraw vested $ORDER tokens
 * During linear period vested $ORDER tokens amount linearly increase from 50% to 100%
 * User can create multiple vesting requests
 * User can cancel vesting request and stake back es$ORDER tokens
 * Unvested amount of $ORDER tokens will be collected by orderCollector
 */
abstract contract Vesting is LedgerAccessControl, ChainedEventIdCounter {
    uint256 internal constant VESTING_LOCK_PERIOD = 15 days;
    uint256 internal constant VESTING_LINEAR_PERIOD = 75 days;

    struct VestingRequest {
        uint256 requestId;
        uint256 esOrderAmount; // Amount of es$ORDER tokens for vesting
        uint256 unlockTimestamp; // Timestamp (block.timestamp) when vested amount will be unlocked
    }

    struct UserVestingInfo {
        uint256 currentRequestId;
        VestingRequest[] requests;
    }

    mapping(address => UserVestingInfo) private userVestingInfos;

    /// @notice Lock period where user can not withdraw vested $ORDER
    uint256 public vestingLockPeriod;

    /// @notice Period after lock period, during which vesting $ORDER amount linearly increase from 50% to 100%
    uint256 public vestingLinearPeriod;

    /* ========== EVENTS ========== */
    event VestingRequested(
        uint256 indexed chainEventId,
        uint256 indexed chainId,
        address indexed user,
        uint256 requestId,
        uint256 amountEsorderRequested,
        uint256 unlockTimestamp
    );
    event VestingCanceled(
        uint256 indexed chainEventId,
        uint256 indexed chainId,
        address indexed user,
        uint256 requestId,
        uint256 amountEsorderStakedBack
    );
    event VestingClaimed(
        uint256 indexed chainEventId,
        uint256 indexed chainId,
        address indexed user,
        uint256 requestId,
        uint256 amountEsorderBurned,
        uint256 amountOrderVested,
        uint256 vestedPeriod
    );

    /* ========== ERRORS ========== */

    error VestingLockPeriodIsZero();
    error VestingLinearPeriodIsZero();
    error VestingAmountIsZero();
    error UserDontHaveVestingRequest(address _user, uint256 _requestId);
    error VestingLockPeriodNotPassed();

    /* ========== INITIALIZER ========== */
    function vestingInit(address, uint256 _vestingLockPeriod, uint256 _vestingLinearPeriod) internal onlyInitializing {
        if (_vestingLockPeriod == 0) revert VestingLockPeriodIsZero();
        if (_vestingLinearPeriod == 0) revert VestingLinearPeriodIsZero();

        vestingLockPeriod = _vestingLockPeriod;
        vestingLinearPeriod = _vestingLinearPeriod;
    }

    /* ========== PUBLIC VIEW FUNCTIONS ========== */
    /// @notice Return amount of $ORDER tokens for withdraw at the moment
    /// @param _user User address
    function calculateVestingOrderAmount(address _user, uint256 _requestId) public view returns (uint256) {
        return _calculateVestingOrderAmount(_findVestingRequest(_user, _requestId));
    }

    function getUserVestingRequests(address _user) public view returns (VestingRequest[] memory) {
        return userVestingInfos[_user].requests;
    }

    /* ========== USER FUNCTIONS ========== */

    /// @notice Create vesting request for user
    /// This call suppose to be called from Ledger contract only as part of es$ORDER unstake and vest!
    /// It does not check if user has enough es$ORDERs - it should be checked in Ledger contract as part of es$ORDER unstake.
    function _createVestingRequest(
        address _user,
        uint256 _chainedEventId,
        uint256 _chainId,
        uint256 _amountEsorder
    ) internal whenNotPaused nonReentrant {
        if (_amountEsorder == 0) revert VestingAmountIsZero();

        UserVestingInfo storage vestingInfo = userVestingInfos[_user];

        VestingRequest memory vestingRequest = VestingRequest(vestingInfo.currentRequestId, _amountEsorder, block.timestamp + vestingLockPeriod);
        vestingInfo.requests.push(vestingRequest);
        vestingInfo.currentRequestId++;

        emit VestingRequested(_chainedEventId, _chainId, _user, vestingRequest.requestId, _amountEsorder, vestingRequest.unlockTimestamp);
    }

    /// @notice Cancel vesting request for user and return es$ORDER amount
    /// Caller should stake back es$ORDER tokens
    function _cancelVestingRequest(
        address _user,
        uint256 _chainedEventId,
        uint256 _chainId,
        uint256 _requestId
    ) internal whenNotPaused nonReentrant returns (uint256 esOrderAmountToStakeBack) {
        VestingRequest storage userVestingRequest = _findVestingRequest(_user, _requestId);

        esOrderAmountToStakeBack = userVestingRequest.esOrderAmount;
        _removeUserVestingRequest(_user, userVestingRequest);

        emit VestingCanceled(_chainedEventId, _chainId, _user, _requestId, esOrderAmountToStakeBack);
    }

    /// @notice Cancel all vesting requests for user
    /// Caller should stake back es$ORDER tokens
    function _cancelAllVestingRequests(
        address _user,
        uint256 _chainedEventId,
        uint256 _chainId
    ) internal whenNotPaused nonReentrant returns (uint256 esOrderAmountToStakeBack) {
        UserVestingInfo memory userVestingInfo = userVestingInfos[_user];

        for (uint256 i = 0; i < userVestingInfo.requests.length; i++) {
            uint256 esOrderAmount = userVestingInfo.requests[i].esOrderAmount;
            esOrderAmountToStakeBack += esOrderAmount;

            emit VestingCanceled(_chainedEventId, _chainId, _user, userVestingInfo.requests[i].requestId, esOrderAmount);
        }

        delete userVestingInfos[_user];
    }

    /// @notice Withdraw $ORDER tokens for user
    /// @dev User can withdraw $ORDER tokens only after locking period passed
    function _claimVestingRequest(
        address _user,
        uint256 _chainedEventId,
        uint256 _chainId,
        uint256 _requestId
    ) internal whenNotPaused nonReentrant returns (uint256 claimedOrderAmount, uint256 unclaimedOrderAmount) {
        VestingRequest storage userVestingRequest = _findVestingRequest(_user, _requestId);

        if (block.timestamp < userVestingRequest.unlockTimestamp) revert VestingLockPeriodNotPassed();

        claimedOrderAmount = _calculateVestingOrderAmount(userVestingRequest);
        unclaimedOrderAmount = userVestingRequest.esOrderAmount - claimedOrderAmount;

        emit VestingClaimed(
            _chainedEventId,
            _chainId,
            _user,
            _requestId,
            userVestingRequest.esOrderAmount,
            claimedOrderAmount,
            block.timestamp - userVestingRequest.unlockTimestamp
        );

        _removeUserVestingRequest(_user, userVestingRequest);
    }

    /* ========== PRIVATE FUNCTIONS ========== */

    /// @notice Find a vesting request for a user by request ID
    function _findVestingRequest(address _user, uint256 _requestId) internal view returns (VestingRequest storage) {
        for (uint256 i = 0; i < userVestingInfos[_user].requests.length; i++) {
            if (userVestingInfos[_user].requests[i].requestId == _requestId) {
                return userVestingInfos[_user].requests[i];
            }
        }
        revert UserDontHaveVestingRequest(_user, _requestId);
    }

    /// @notice Calculate amount of $ORDER tokens for withdraw
    /// @dev 15 days vesting period - 50% of es$ORDER tokens amount
    /// @dev 90 days vesting period - 100% of es$ORDER tokens amount
    function _calculateVestingOrderAmount(VestingRequest memory _vestingRequest) private view returns (uint256) {
        if (_vestingRequest.esOrderAmount == 0 || block.timestamp < _vestingRequest.unlockTimestamp) {
            return 0;
        }

        uint256 vestedTime = block.timestamp - _vestingRequest.unlockTimestamp;
        if (vestedTime > vestingLinearPeriod) {
            return _vestingRequest.esOrderAmount;
        }

        return _vestingRequest.esOrderAmount / 2 + (_vestingRequest.esOrderAmount * vestedTime) / vestingLinearPeriod / 2;
    }

    function _removeUserVestingRequest(address _user, VestingRequest storage userVestingRequest) private {
        VestingRequest memory lastRequest = userVestingInfos[_user].requests[userVestingInfos[_user].requests.length - 1];
        userVestingRequest.requestId = lastRequest.requestId;
        userVestingRequest.esOrderAmount = lastRequest.esOrderAmount;
        userVestingRequest.unlockTimestamp = lastRequest.unlockTimestamp;
        userVestingInfos[_user].requests.pop();
    }

    // gap for upgradeable
    uint256[50] private __gap;
}
