// SPDX-License-Identifier: MIT
pragma solidity 0.8.22;

import {EnumerableMap} from "@openzeppelin/contracts/utils/structs/EnumerableMap.sol";

import {LedgerAccessControl} from "./LedgerAccessControl.sol";
import {ChainedEventIdCounter} from "./ChainedEventIdCounter.sol";
import {Valor} from "./Valor.sol";

abstract contract Revenue is LedgerAccessControl, ChainedEventIdCounter, Valor {
    uint256 internal constant BATCH_DURATION = 14 days;

    struct Batch {
        /// @dev Admin set this by calling batchPreparedToClaim after provide USDC for batch to the contract
        bool claimable;
        /// @dev Total amount of valor, that was redeemed in the batch
        uint256 redeemedValorAmount;
        /// @dev Total amount of USDC, that was claimed in the batch
        uint256 claimedUsdcAmount;
        /// @dev When batch finished, current rate will be fixed as the rate for the batch
        uint256 fixedValorToUsdcRate;
    }

    struct UserReremprionRequest {
        uint16 batchId;
        EnumerableMap.UintToUintMap chainIdToValorAmount;
    }

    struct UserRevenue {
        uint256 redeemedAmount;
        uint256 claimedAmount;
        EnumerableMap.UintToUintMap usdcRevenueByChainId;
        UserReremprionRequest[] requests;
    }

    /// @notice The timestamp when the first batch starts
    uint256 public startTimestamp;

    Batch[] public batches;

    mapping(address => UserRevenue) private userRevenue;

    /* ========== EVENTS ========== */

    event Redeemed(uint256 eventId, address indexed user, uint16 batchId, uint256 amount);

    /* ========== ERRORS ========== */

    error RedemptionAmountIsZero();
    error AmountIsGreaterThanCollectedValor();
    error BatchIsNotFinished();

    /* ========== INITIALIZER ========== */

    function revenueInit(uint256 _startTimstamp) internal onlyInitializing {
        startTimestamp = _startTimstamp;
    }

    /* ========== EXTERNAL FUNCTIONS ========== */

    function getCurrentBatchId() public view returns (uint16) {
        uint256 currentTimestamp = block.timestamp;
        if (currentTimestamp < startTimestamp) {
            return 0;
        }
        return uint16((currentTimestamp - startTimestamp) / BATCH_DURATION);
    }

    function getBatchStartTime(uint16 batchId) public view returns (uint256) {
        return startTimestamp + batchId * BATCH_DURATION;
    }

    function getBatchEndTime(uint16 batchId) public view returns (uint256) {
        return getBatchStartTime(batchId) + BATCH_DURATION;
    }

    function getBatch(uint16 batchId) public view returns (Batch memory) {
        return batches[batchId];
    }

    function batchPreparedToClaim(uint16 batchId) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (batchId >= getCurrentBatchId()) revert BatchIsNotFinished();

        batches[batchId].claimable = true;
    }

    /* ========== INTERNAL FUNCTIONS ========== */

    /**
     * @notice Create redemption request for the user to current batch and given chainId
     *         Can redeem only collected valor, so, before calling this function it supposed that both
     *         _updateValorVars(); and _collectValor(_user); from Staking contract were called
     *         to caclulate and collect pending valor for user
     *         Also supposed that reentrancy will be checked in the caller function
     * @param _user User address
     * @param _srcChainId Source chain id
     * @param _amount Amount of valor to redeem
     */
    function _redeemValor(address _user, uint256 _srcChainId, uint256 _amount) internal {
        if (_amount == 0) revert RedemptionAmountIsZero();
        if (collectedValor[_user] < _amount) revert AmountIsGreaterThanCollectedValor();
        collectedValor[_user] -= _amount;

        uint16 currentBatchId = getCurrentBatchId();
        batches[currentBatchId].redeemedValorAmount += _amount;
        bool found = false;
        for (uint256 i = 0; i < userRevenue[_user].requests.length; i++) {
            if (userRevenue[_user].requests[i].batchId == currentBatchId) {
                (, uint256 currentAmount) = EnumerableMap.tryGet(userRevenue[_user].requests[i].chainIdToValorAmount, _srcChainId);
                EnumerableMap.set(userRevenue[_user].requests[i].chainIdToValorAmount, _srcChainId, currentAmount + _amount);
                found = true;
                break;
            }
        }

        if (!found) {
            uint256 idx = userRevenue[_user].requests.length;
            userRevenue[_user].requests.push();
            UserReremprionRequest storage request = userRevenue[_user].requests[idx];
            request.batchId = currentBatchId;
            EnumerableMap.set(request.chainIdToValorAmount, _srcChainId, _amount);
        }

        emit Redeemed(_getNextEventId(0), _user, found ? currentBatchId : 0, _amount);
    }

    /**
     * @notice Collect USDC revenue for the user for claimable batches
     * @param _user User address
     */
    function _collectRevenue(address _user) internal {
        for (uint256 i = 0; i < userRevenue[_user].requests.length; i++) {
            UserReremprionRequest storage request = userRevenue[_user].requests[i];
            if (batches[request.batchId].claimable == true) {
                for (uint256 j = 0; j < EnumerableMap.length(request.chainIdToValorAmount); j++) {
                    (uint256 chainId, uint256 amount) = EnumerableMap.at(request.chainIdToValorAmount, j);
                    uint256 usdcAmount = (amount * batches[request.batchId].fixedValorToUsdcRate);
                    (, uint256 currentUsdcAmount) = EnumerableMap.tryGet(userRevenue[_user].usdcRevenueByChainId, chainId);
                    EnumerableMap.set(userRevenue[_user].usdcRevenueByChainId, chainId, currentUsdcAmount + usdcAmount);
                }
                delete userRevenue[_user].requests[i];
            }
        }
    }
}
