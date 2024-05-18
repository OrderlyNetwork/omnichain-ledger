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
        /// @dev When batch finished, current rate will be fixed as the rate for the batch
        uint256 fixedValorToUsdcRate;
        /// @dev Total amount of valor, that was redeemed in the batch per chain
        ChainedAmount[] chainedValorAmount;
    }

    struct BatchedReremprionRequest {
        uint16 batchId;
        ChainedAmount[] chainedValorAmount;
    }

    struct UserRevenueRecord {
        mapping(uint256 => uint256) chainedUsdcRevenue;
        BatchedReremprionRequest[] requests;
    }

    /// @notice The timestamp when the first batch starts
    uint256 public startTimestamp;

    Batch[] public batches;

    mapping(address => UserRevenueRecord) private userRevenue;

    /* ========== EVENTS ========== */

    event ValorRedeemed(uint256 indexed chainEventId, uint256 indexed chainId, address indexed user, uint16 batchId, uint256 valorAmount);
    event UsdcClaimed(uint256 indexed chainEventId, uint256 indexed chainId, address indexed user, uint256 usdcAmount);

    /* ========== ERRORS ========== */

    error RedemptionAmountIsZero();
    error AmountIsGreaterThanCollectedValor();
    error BatchIsNotFinished();
    error BatchIsAlreadyBurned();

    /* ========== INITIALIZER ========== */

    function revenueInit(uint256 _startTimstamp) internal onlyInitializing {
        startTimestamp = _startTimstamp;
    }

    /* ========== VIEW FUNCTIONS ========== */

    function getCurrentBatchId() public view returns (uint16) {
        uint256 currentTimestamp = block.timestamp;
        if (currentTimestamp < startTimestamp) {
            return 0;
        }
        return uint16((currentTimestamp - startTimestamp) / BATCH_DURATION);
    }

    function getBatchStartTime(uint16 _batchId) public view returns (uint256) {
        return startTimestamp + _batchId * BATCH_DURATION;
    }

    function getBatchEndTime(uint16 _batchId) public view returns (uint256) {
        return getBatchStartTime(_batchId) + BATCH_DURATION;
    }

    function getBatch(uint16 _batchId) public view returns (Batch memory) {
        return batches[_batchId];
    }

    function isBatchFinished(uint16 _batchId) public view returns (bool) {
        return block.timestamp >= getBatchEndTime(_batchId);
    }

    function getUsdcAmountForBatch(uint16 _batchId) public view returns (ChainedAmount[] memory chainedUsdcAmount) {
        chainedUsdcAmount = batches[_batchId].chainedValorAmount;
        for (uint256 i = 0; i < chainedUsdcAmount.length; i++) {
            chainedUsdcAmount[i].amount *= batches[_batchId].fixedValorToUsdcRate;
        }
    }

    function getUserRedeemedValorAmountForBatchAndChain(address _user, uint16 _batchId, uint256 _chainId) public view returns (uint256) {
        for (uint256 i = 0; i < userRevenue[_user].requests.length; i++) {
            if (userRevenue[_user].requests[i].batchId == _batchId) {
                for (uint256 j = 0; j < userRevenue[_user].requests[i].chainedValorAmount.length; j++) {
                    if (userRevenue[_user].requests[i].chainedValorAmount[j].chainId == _chainId) {
                        return userRevenue[_user].requests[i].chainedValorAmount[j].amount;
                    }
                }
            }
        }
        return 0;
    }

    function getUserBudgetForChain(
        address _user,
        uint256 _chainId
    ) public view returns (uint256 redeemingValor, uint256 pendingInTwoDays, uint256 usdcAvailableNow) {
        usdcAvailableNow = userRevenue[_user].chainedUsdcRevenue[_chainId];
        for (uint256 i = 0; i < userRevenue[_user].requests.length; i++) {
            uint16 batchId = userRevenue[_user].requests[i].batchId;
            uint256 redeemedValorForChain = _getRedeemedValorAmountForChain(userRevenue[_user].requests[i], _chainId);
            if (batches[batchId].claimable) {
                usdcAvailableNow += redeemedValorForChain * batches[batchId].fixedValorToUsdcRate;
            } else if (batches[batchId].fixedValorToUsdcRate != 0) {
                pendingInTwoDays += redeemedValorForChain * batches[batchId].fixedValorToUsdcRate;
            } else {
                redeemingValor += redeemedValorForChain;
            }
        }
    }

    /* ========== ADMIN FUNCTIONS ========== */

    function fixBatchPrice(uint16 _batchId) external onlyRole(DEFAULT_ADMIN_ROLE) returns (uint256) {
        if (_batchId >= getCurrentBatchId()) revert BatchIsNotFinished();
        if (batches[_batchId].fixedValorToUsdcRate == 0) {
            batches[_batchId].fixedValorToUsdcRate = valorToUsdcRate;
        }
        return batches[_batchId].fixedValorToUsdcRate;
    }

    function batchPreparedToClaim(uint16 _batchId) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (_batchId >= getCurrentBatchId()) revert BatchIsNotFinished();
        if (batches[_batchId].claimable) return;

        totalValorAmount -= batches[_batchId].redeemedValorAmount;
        totalUsdcInTreasure -= batches[_batchId].redeemedValorAmount * batches[_batchId].fixedValorToUsdcRate;
        batches[_batchId].claimable = true;
    }

    /* ========== USER FUNCTIONS ========== */

    /**
     * @notice Create redemption request for the user to current batch and given chainId
     *         Can redeem only collected valor, so, before calling this function it supposed that both
     *         _updateValorVars(); and _collectValor(_user); from Staking contract were called
     *         to caclulate and collect pending valor for user
     *         Also supposed that reentrancy will be checked in the caller function
     */
    function _redeemValor(address _user, uint256 _chainId, uint256 _amount) internal {
        if (_amount == 0) revert RedemptionAmountIsZero();
        if (collectedValor[_user] < _amount) revert AmountIsGreaterThanCollectedValor();
        collectedValor[_user] -= _amount;

        // If user has pending USDC revenue for claimable batch, collect it
        _collectUserRevenueForClaimableBatch(_user);

        // Update or create redemption request for the user for current batch
        uint16 currentBatchId = getCurrentBatchId();
        _getOrCreateBatch(currentBatchId).redeemedValorAmount += _amount;
        BatchedReremprionRequest storage request = _getOrCreateBatchedRedemptionRequest(_user, currentBatchId);
        _getOrCreateChainedAmount(request.chainedValorAmount, _chainId).amount += _amount;

        // Update redeemed valor amount for current batch and chain
        _getOrCreateChainedAmount(batches[currentBatchId].chainedValorAmount, _chainId).amount += _amount;

        emit ValorRedeemed(_getNextChainedEventId(0), _chainId, _user, currentBatchId, _amount);
    }

    function _claimUsdcRevenue(address _user, uint256 _chainId) internal returns (uint256) {
        // If user has pending USDC revenue for claimable batch, collect it
        _collectUserRevenueForClaimableBatch(_user);

        uint256 usdcAmount = userRevenue[_user].chainedUsdcRevenue[_chainId];
        userRevenue[_user].chainedUsdcRevenue[_chainId] = 0;

        emit UsdcClaimed(_getNextChainedEventId(_chainId), _chainId, _user, usdcAmount);
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

    function _getRedeemedValorAmountForChain(BatchedReremprionRequest storage request, uint256 _chainId) internal view returns (uint256) {
        for (uint256 i = 0; i < request.chainedValorAmount.length; i++) {
            if (request.chainedValorAmount[i].chainId == _chainId) {
                return request.chainedValorAmount[i].amount;
            }
        }
        return 0;
    }

    /**
     * @notice Traverse all user revenue requests and collect USDC revenue for claimable batch
     *         Suppose that this function will be called each time when user redeem valor or claim USDC
     *         There shouldn't be more than one request for claimable batch at the same time
     *         And no more than 3 requests for the user: claimable, finished but not prepared yet and current
     *         So, overal complexity is 3 requests to find claimable batch O(1) + chainNum to collect USDC O(N)
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
