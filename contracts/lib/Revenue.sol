// SPDX-License-Identifier: MIT
pragma solidity 0.8.22;

import {LedgerAccessControl} from "./LedgerAccessControl.sol";
import {ChainedEventIdCounter} from "./ChainedEventIdCounter.sol";
import {Valor} from "./Valor.sol";

abstract contract Revenue is LedgerAccessControl, ChainedEventIdCounter, Valor {
    uint256 internal constant BATCH_DURATION = 14 days;

    struct ChainedAmount {
        uint256 chainId;
        uint256 amount;
    }

    struct Batch {
        /// @dev Admin set this by calling batchPreparedToClaim after provide USDC for batch to the contract
        bool claimable;
        /// @dev Total amount of valor, that was redeemed in the batch
        uint256 redeemedValorAmount;
        /// @dev Total amount of USDC, that was claimed in the batch
        uint256 claimedUsdcAmount;
        /// @dev When batch finished, current rate will be fixed as the rate for the batch
        uint256 fixedValorToUsdcRate;
        /// @dev Total amount of valor, that was redeemed in the batch per chain
        ChainedAmount[] chainedValorAmount;
    }

    struct BatchedReremprionRequest {
        uint16 batchId;
        ChainedAmount[] chainedValorAmount;
    }

    struct UserRevenue {
        mapping(uint256 => uint256) chainedUsdcRevenue;
        BatchedReremprionRequest[] requests;
    }

    /// @notice The timestamp when the first batch starts
    uint256 public startTimestamp;

    Batch[] public batches;

    mapping(address => UserRevenue) private userRevenue;

    /* ========== EVENTS ========== */

    event RedeemValor(uint256 chainEventId, uint256 chainId, address indexed user, uint16 batchId, uint256 valorAmount);
    event ClaimUsdc(uint256 chainEventId, uint256 chainId, address indexed user, uint256 usdcAmount);

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

        // If user has pending USDC revenue for claimable batch, collect it
        _collectUserRevenueForClaimableBatch(_user);

        // Update or create redemption request for the user for current batch
        uint16 currentBatchId = getCurrentBatchId();
        _getOrCreateBatch(currentBatchId).redeemedValorAmount += _amount;
        BatchedReremprionRequest storage request = _getOrCreateBatchedRedemptionRequest(_user, currentBatchId);
        ChainedAmount storage chainedAmount = _getOrCreateChainedAmount(request.chainedValorAmount, _srcChainId);
        chainedAmount.amount += _amount;

        // Update redeemed valor amount for current batch and chain
        _getOrCreateChainedAmount(batches[currentBatchId].chainedValorAmount, _srcChainId).amount += _amount;

        emit RedeemValor(_getNextChainedEventId(0), _srcChainId, _user, currentBatchId, _amount);
    }

    function _claimUsdc(address _user, uint256 _chainId) internal returns (uint256) {
        uint256 usdcAmount = userRevenue[_user].chainedUsdcRevenue[_chainId];
        userRevenue[_user].chainedUsdcRevenue[_chainId] = 0;

        emit ClaimUsdc(_getNextChainedEventId(_chainId), _chainId, _user, usdcAmount);
        return usdcAmount;
    }

    /* ========== INTERNAL FUNCTIONS ========== */

    function _getOrCreateBatch(uint16 _batchId) internal returns (Batch storage) {
        if (_batchId >= batches.length) {
            batches.push();
        }
        return batches[_batchId];
    }

    function _getOrCreateBatchedRedemptionRequest(address _user, uint16 _batchId) internal returns (BatchedReremprionRequest storage) {
        for (uint256 i = 0; i < userRevenue[_user].requests.length; i++) {
            if (userRevenue[_user].requests[i].batchId == _batchId) {
                return userRevenue[_user].requests[i];
            }
        }

        uint256 idx = userRevenue[_user].requests.length;
        userRevenue[_user].requests.push();
        userRevenue[_user].requests[idx].batchId = _batchId;
        return userRevenue[_user].requests[idx];
    }

    function _getOrCreateChainedAmount(ChainedAmount[] storage _chainedAmounts, uint256 _chainId) internal returns (ChainedAmount storage) {
        for (uint256 i = 0; i < _chainedAmounts.length; i++) {
            if (_chainedAmounts[i].chainId == _chainId) {
                return _chainedAmounts[i];
            }
        }

        uint256 idx = _chainedAmounts.length;
        _chainedAmounts.push();
        _chainedAmounts[idx].chainId = _chainId;
        return _chainedAmounts[idx];
    }

    /**
     * @notice Traverse all user revenue requests and collect USDC revenue for claimable batch
     *         Suppose that this function will be called each time when user redeem valor or claim USDC
     *         There shouldn't be more than one request for claimable batch at the same time
     *         And no more than 3 requests for the user: claimable, finished but not prepared yet and current
     *         So, overal complexity is 3 requests to find claimable O(1) + chainNum ^ 2 to collect USDC
     */
    function _collectUserRevenueForClaimableBatch(address _user) internal {
        for (uint256 requestIndex = 0; requestIndex < userRevenue[_user].requests.length; requestIndex++) {
            BatchedReremprionRequest storage request = userRevenue[_user].requests[requestIndex];
            if (batches[request.batchId].claimable) {
                // Ok, we found request for claimable batch, let's collect USDC revenue for it
                for (uint256 chainIndex = 0; chainIndex < request.chainedValorAmount.length; chainIndex++) {
                    uint256 chainId = request.chainedValorAmount[chainIndex].chainId;
                    uint256 amount = request.chainedValorAmount[chainIndex].amount;
                    uint256 usdcAmount = amount * batches[request.batchId].fixedValorToUsdcRate;
                    userRevenue[_user].chainedUsdcRevenue[chainId] += usdcAmount;
                }
                // Now we can remove this request
                uint256 lastIndex = userRevenue[_user].requests.length - 1;
                userRevenue[_user].requests[requestIndex] = userRevenue[_user].requests[lastIndex];
                userRevenue[_user].requests.pop();
                return;
            }
        }
    }
}
