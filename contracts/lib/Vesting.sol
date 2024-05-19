// SPDX-License-Identifier: MIT
pragma solidity 0.8.22;

import {LedgerToken} from "orderly-omnichain-occ/contracts/OCCInterface.sol";
import {LedgerAccessControl} from "./LedgerAccessControl.sol";
import {ChainedEventIdCounter} from "./ChainedEventIdCounter.sol";
import {Staking} from "./Staking.sol";

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

    mapping(address => UserVestingInfo) public userVestingInfos;

    /// @notice Lock period where user can not withdraw vested $ORDER
    uint256 public lockPeriod;

    /// @notice Period after lock period, during which vesting $ORDER amount linearly increase from 50% to 100%
    uint256 public linearVestingPeriod;

    address public orderCollector;

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

    error LockPeriodIsZero();
    error LinearVestingPeriodIsZero();
    error OrderCollectorIsZero();
    error VestingAmountIsZero();
    error VestingPeriodIsOutOfRange();
    error UserDontHaveVestingRequest(address _user, uint256 _requestId);
    error LockPeriodNotPassed();
    error DepositNotEnough(uint256 amountEsorderDeposited, uint256 amountEsorderRequested);

    /* ========== INITIALIZER ========== */
    function vestingInit(uint256 _lockPeriod, uint256 _linearVestingPeriod, address _orderCollector) internal onlyInitializing {
        if (_lockPeriod == 0) revert LockPeriodIsZero();
        if (_linearVestingPeriod == 0) revert LinearVestingPeriodIsZero();
        if (_orderCollector == address(0)) revert OrderCollectorIsZero();

        lockPeriod = _lockPeriod;
        linearVestingPeriod = _linearVestingPeriod;
        orderCollector = _orderCollector;
    }

    /* ========== PUBLIC VIEW FUNCTIONS ========== */
    /// @notice Return amount of $ORDER tokens for withdraw at the moment
    /// @param _user User address
    function calculateVestingOrderAmount(address _user, uint256 _requestId) public view returns (uint256) {
        return _calculateVestingOrderAmount(userVestingInfos[_user].requests[_requestId]);
    }

    /* ========== USER FUNCTIONS ========== */

    /// @notice Create vesting request for user
    function createVestingRequest(address _user, uint256 _chainId, uint256 _amountEsorder) internal whenNotPaused nonReentrant {
        if (_amountEsorder == 0) revert VestingAmountIsZero();

        UserVestingInfo storage vestingInfo = userVestingInfos[_user];

        VestingRequest memory vestingRequest = VestingRequest(vestingInfo.currentRequestId, _amountEsorder, block.timestamp + lockPeriod);
        vestingInfo.requests.push(vestingRequest);
        vestingInfo.currentRequestId++;

        emit VestingRequested(
            _getNextChainedEventId(_chainId),
            _chainId,
            _user,
            vestingRequest.requestId,
            _amountEsorder,
            vestingRequest.unlockTimestamp
        );
    }

    /// @notice Cancel vesting request for user and return es$ORDER amount
    /// Caller should stake back es$ORDER tokens
    function cancelVestingRequest(
        address _user,
        uint256 _chainId,
        uint256 _requestId
    ) internal whenNotPaused nonReentrant returns (uint256 esOrderAmountToStakeBack) {
        VestingRequest storage userVestingRequest = _findVestingRequest(_user, _requestId);

        esOrderAmountToStakeBack = userVestingRequest.esOrderAmount;
        userVestingRequest = userVestingInfos[_user].requests[userVestingInfos[_user].requests.length - 1];
        userVestingInfos[_user].requests.pop();

        emit VestingCanceled(_getNextChainedEventId(_chainId), _chainId, _user, _requestId, esOrderAmountToStakeBack);
    }

    /// @notice Cancel all vesting requests for user
    function cancelAllVestingRequests(
        address _user,
        uint256 _chainId
    ) internal whenNotPaused nonReentrant returns (uint256 esOrderAmountToStakeBack) {
        UserVestingInfo memory userVestingInfo = userVestingInfos[_user];

        for (uint256 i = 0; i < userVestingInfo.requests.length; i++) {
            uint256 esOrderAmount = userVestingInfo.requests[i].esOrderAmount;
            esOrderAmountToStakeBack += esOrderAmount;

            emit VestingCanceled(_getNextChainedEventId(_chainId), _chainId, _user, userVestingInfo.requests[i].requestId, esOrderAmount);
        }

        delete userVestingInfos[_user];
    }

    /// @notice Withdraw $ORDER tokens for user
    /// @dev User can withdraw $ORDER tokens only after locking period passed
    function claimVestingRequest(
        address _user,
        uint256 _chainId,
        uint256 _requestId
    ) internal whenNotPaused nonReentrant returns (uint256 claimedOrderAmount) {
        VestingRequest storage vestingRequest = _findVestingRequest(_user, _requestId);

        if (block.timestamp < vestingRequest.unlockTimestamp) revert LockPeriodNotPassed();

        claimedOrderAmount = _calculateVestingOrderAmount(vestingRequest);

        emit VestingClaimed(
            _getNextChainedEventId(_chainId),
            _chainId,
            _user,
            _requestId,
            vestingRequest.esOrderAmount,
            claimedOrderAmount,
            block.timestamp - vestingRequest.unlockTimestamp
        );

        vestingRequest = userVestingInfos[_user].requests[userVestingInfos[_user].requests.length - 1];
        userVestingInfos[_user].requests.pop();
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
        if (vestedTime > linearVestingPeriod) vestedTime = linearVestingPeriod;
        return _vestingRequest.esOrderAmount / 2 + (_vestingRequest.esOrderAmount * vestedTime) / linearVestingPeriod / 2;
    }
}