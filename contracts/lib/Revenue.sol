// SPDX-License-Identifier: MIT
pragma solidity 0.8.22;

import {LedgerAccessControl} from "./LedgerAccessControl.sol";
import {ChainedEventIdCounter} from "./ChainedEventIdCounter.sol";
import {Valor} from "./Valor.sol";

/**
 * @title Revenue
 * @author Orderly Network
 * @notice Contract that allow users to redeem valor and claim USDC revenue for valor
 *         Revenue is calculated per batch, that is 14 days long; Contract
 *         User can redeem valor only for current batch
 *         User can make several redemption requests for one batch, the amount will be summed
 *         User create redemption request for the chain, that is used in the request
 *         Redemption request can't be cancelled or revoked
 *         CeFi fixes valor to USDC rate for the batch after providing daily USDC net fee amount after batch is finished
 *         Then admin marks batch as claimable when USDC is provided for the batch
 *         User can claim USDC revenue for claimable batches
 *         User can claim all USDC revenue for claimable batches at once
 *
 * @dev    To reduse complexity, user's revenue requests for batches that are claimable are collects to chainedUsdcRevenue at the user's record
 *         So, each moment user shouldn't have more than 2 BatchedRedemptionRequest: finished but not prepared yet and current
 */
abstract contract Revenue is LedgerAccessControl, ChainedEventIdCounter, Valor {
    uint256 internal constant DEFAULT_BATCH_DURATION = 14 days;

    /// @dev Represents amount per chain
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
        uint256 fixedValorToUsdcRateScaled;
        /// @dev Total amount of valor, that was redeemed in the batch per chain
        ChainedAmount[] chainedValorAmount;
    }

    // Array of batches; batchId is an index in this array
    Batch[] public batches;

    /// @notice The timestamp when the first batch starts
    uint256 public batchStartTimestamp;

    struct BatchedRedemptionRequest {
        uint16 batchId;
        ChainedAmount[] chainedValorAmount;
    }

    struct UserRevenueRecord {
        mapping(uint256 => uint256) chainedUsdcRevenue;
        BatchedRedemptionRequest[] requests;
    }

    mapping(address => UserRevenueRecord) internal userRevenue;

    /// @notice Period of the batch in seconds
    uint256 public batchDuration;

    /* ========== EVENTS ========== */

    /// @notice Emitted when user redeem valor for the chain; batchId is the current batch
    event ValorRedeemed(uint256 indexed chainEventId, uint256 indexed chainId, address indexed user, uint16 batchId, uint256 valorAmount);

    /// @notice Emitted when user claim collected USDC revenue from chain
    event UsdcRevenueClaimed(uint256 indexed chainEventId, uint256 indexed chainId, address indexed user, uint256 usdcAmount);

    /// @notice Emitted when admin fixes valor to USDC rate for the batch
    event BatchValorToUsdcRateIsFixed(uint16 indexed batchId, uint256 fixedValorToUsdcRate);

    /// @notice Emitted when admin marks batch as claimable
    event BatchPreparedToClaim(uint16 indexed batchId);

    /* ========== ERRORS ========== */

    error RedemptionAmountIsZero();
    error AmountIsGreaterThanCollectedValor();
    error BatchIsNotCreatedYet();
    error BatchIsNotFinished();
    error BatchValorToUsdcRateIsNotFixed();
    error NothingToClaim(address user, uint256 chainId);
    error RedemptionIsNotStartedYet();

    /* ========== INITIALIZER ========== */

    function revenueInit(address, uint256 _batchStartTimstamp, uint256 _batchDuration) internal onlyInitializing {
        batchStartTimestamp = _batchStartTimstamp;
        batchDuration = _batchDuration;
        // create first batch
        batches.push();
    }

    /* ========== VIEW FUNCTIONS ========== */

    /// @notice Calculate and returns the current batch id
    /// based on the current timestamp, start timestamp and batch duration
    /// @dev Revert if the redemption is not started yet to prevent redemption before the start
    function getCurrentBatchId() public view returns (uint16) {
        uint256 currentTimestamp = block.timestamp;
        if (currentTimestamp < batchStartTimestamp) revert RedemptionIsNotStartedYet();

        return uint16((currentTimestamp - batchStartTimestamp) / batchDuration);
    }

    /// @notice Returns the batch structure by id without chained valor amount
    function getBatchInfo(
        uint16 _batchId
    )
        external
        view
        returns (uint256 batchStartTime, uint256 batchEndTime, bool claimable, uint256 redeemedValorAmount, uint256 fixedValorToUsdcRateScaled)
    {
        batchStartTime = batchStartTimestamp + _batchId * batchDuration;
        batchEndTime = batchStartTime + batchDuration;
        if (_batchId < batches.length) {
            Batch storage batch = _getBatch(_batchId);
            claimable = batch.claimable;
            redeemedValorAmount = batch.redeemedValorAmount;
            fixedValorToUsdcRateScaled = batch.fixedValorToUsdcRateScaled;
        } else {
            claimable = false;
            redeemedValorAmount = 0;
            fixedValorToUsdcRateScaled = 0;
        }
    }

    /// @notice Returns the amount of valor that user can redeem for the chain
    function getBatchChainedValorAmount(uint16 _batchId) external view returns (ChainedAmount[] memory) {
        return _getBatch(_batchId).chainedValorAmount;
    }

    /// @notice Returns the amount of USDC required for batch on each chain
    function getUsdcAmountForBatch(uint16 _batchId) external view returns (ChainedAmount[] memory chainedUsdcAmount) {
        Batch storage batch = _getBatch(_batchId);
        chainedUsdcAmount = batch.chainedValorAmount;
        for (uint256 i = 0; i < chainedUsdcAmount.length; i++) {
            chainedUsdcAmount[i].amount = (chainedUsdcAmount[i].amount * batch.fixedValorToUsdcRateScaled) / VALOR_TO_USDC_RATE_PRECISION;
        }
    }

    /// @notice Returns the amount of valor that user redeemed for the chain in the batch
    function getUserRedeemedValorAmountForBatchAndChain(address _user, uint16 _batchId, uint256 _chainId) external view returns (uint256) {
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

    /* ========== ADMIN FUNCTIONS ========== */

    /// @notice Admin marks batch as claimable when USDC is provided for the batch
    ///         This also reduce total valor amount and total USDC in treasure
    ///         This reduce shouldn't affect the valor to USDC rate because valor and USDC amounts are reduced proportionally
    function batchPreparedToClaim(uint16 _batchId) external whenNotPaused onlyRole(DEFAULT_ADMIN_ROLE) {
        if (_batchId >= getCurrentBatchId()) revert BatchIsNotFinished();
        Batch storage batch = _getBatch(_batchId);
        if (batch.fixedValorToUsdcRateScaled == 0) revert BatchValorToUsdcRateIsNotFixed();
        if (batch.claimable) return;

        totalValorAmount -= batch.redeemedValorAmount;
        totalUsdcInTreasure -= (batch.redeemedValorAmount * batch.fixedValorToUsdcRateScaled) / VALOR_TO_USDC_RATE_PRECISION;
        batch.claimable = true;

        emit BatchPreparedToClaim(_batchId);
    }

    /* ========== USER FUNCTIONS ========== */

    /**
     * @notice Create redemption request for the user to current batch and given chainId
     *         Can redeem only collected valor, so, before calling this function it supposed that
     *         _updateValorVarsAndCollectUserValor(_user) from Staking contract were called
     *         to caclulate and collect pending valor for user
     *         Also supposed that reentrancy will be checked in the caller function
     */
    function _redeemValor(address _user, uint256 _chainId, uint256 _amount) internal whenNotPaused {
        if (_amount == 0) revert RedemptionAmountIsZero();
        if (collectedValor[_user] < _amount) revert AmountIsGreaterThanCollectedValor();
        collectedValor[_user] -= _amount;

        // If user has pending USDC revenue for claimable batch, collect it
        _collectUserRevenueForClaimableBatch(_user);

        // Update or create redemption request for the user for current batch
        uint16 currentBatchId = getCurrentBatchId();
        _getOrCreateBatch(currentBatchId).redeemedValorAmount += _amount;
        BatchedRedemptionRequest storage request = _getOrCreateBatchedRedemptionRequest(_user, currentBatchId);
        _getOrCreateChainedAmount(request.chainedValorAmount, _chainId).amount += _amount;

        // Update redeemed valor amount for current batch and chain
        _getOrCreateChainedAmount(batches[currentBatchId].chainedValorAmount, _chainId).amount += _amount;

        emit ValorRedeemed(_getNextChainedEventId(_chainId), _chainId, _user, currentBatchId, _amount);
    }

    /**
     * @notice Claim USDC revenue for the user for the given chainId
     *         This function first collect USDC revenue for claimable batch
     *         This function does not transfer USDC to the user, it just returns the amount
     *         Caller (Ledger contract) should transfer USDC to the user on the Vault chain
     */
    function _claimUsdcRevenue(address _user, uint256 _chainId) internal whenNotPaused returns (uint256 claimedUsdcAmount) {
        // If user has pending USDC revenue for claimable batch, collect it
        _collectUserRevenueForClaimableBatch(_user);

        claimedUsdcAmount = userRevenue[_user].chainedUsdcRevenue[_chainId];
        if (claimedUsdcAmount == 0) revert NothingToClaim(_user, _chainId);

        userRevenue[_user].chainedUsdcRevenue[_chainId] = 0;

        emit UsdcRevenueClaimed(_getNextChainedEventId(_chainId), _chainId, _user, claimedUsdcAmount);
    }

    /* ========== INTERNAL FUNCTIONS ========== */

    /// @notice Check if previous finished batch has no fixed valor to USDC rate and fix it
    ///         batch.fixedValorToUsdcRateScaled will be set to current valorToUsdcRateScaled
    function _possiblyFixBatchValorToUsdcRateForPreviousBatch() internal whenNotPaused {
        uint16 curBatchId = getCurrentBatchId();
        if (curBatchId > 0) {
            uint16 prevBatchId = curBatchId - 1;
            // If nobody redeemed valor in the batch, batch will not be created at this moment, let's create it
            Batch storage prevBatch = _getOrCreateBatch(prevBatchId);
            if (prevBatch.fixedValorToUsdcRateScaled == 0) {
                prevBatch.fixedValorToUsdcRateScaled = valorToUsdcRateScaled;
                emit BatchValorToUsdcRateIsFixed(prevBatchId, prevBatch.fixedValorToUsdcRateScaled);
            }
        }
    }

    /* ========== PRIVATE FUNCTIONS ========== */

    /// @notice Returns the batch by id. Reverts if the batch is not created
    function _getBatch(uint16 _batchId) private view returns (Batch storage) {
        if (_batchId >= batches.length) revert BatchIsNotCreatedYet();
        return batches[_batchId];
    }

    /// @notice Returns the batch by id. Creates the batch if it is not created yet
    function _getOrCreateBatch(uint16 _batchId) private returns (Batch storage) {
        while (_batchId >= batches.length) {
            batches.push();
        }
        return _getBatch(_batchId);
    }

    /// @notice Returns the redemption request for the user for the batch. Creates the request if it is not created yet
    function _getOrCreateBatchedRedemptionRequest(address _user, uint16 _batchId) private returns (BatchedRedemptionRequest storage) {
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

    /// @notice Returns the ChainedAmount for the chain. Creates the ChainedAmount if it is not created yet
    function _getOrCreateChainedAmount(ChainedAmount[] storage _chainedAmounts, uint256 _chainId) private returns (ChainedAmount storage) {
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
     *         There shouldn't be more than 3 requests for the user: 2 claimable maximum and current
     *         Two claimable can happen when user redeem valor for the batch while previous one is in grace period
     *         and is not claimable yet.
     *         So, overal complexity is 3 requests to find claimable batch O(1) + chainNum to collect USDC O(N)
     */
    function _collectUserRevenueForClaimableBatch(address _user) private {
        uint256 requestIndex = 0;
        while (requestIndex < userRevenue[_user].requests.length) {
            BatchedRedemptionRequest storage request = userRevenue[_user].requests[requestIndex];
            if (batches[request.batchId].claimable) {
                // Ok, we found request for claimable batch, let's collect USDC revenue for it
                for (uint256 chainIndex = 0; chainIndex < request.chainedValorAmount.length; chainIndex++) {
                    uint256 chainId = request.chainedValorAmount[chainIndex].chainId;
                    uint256 valorAmount = request.chainedValorAmount[chainIndex].amount;
                    uint256 usdcAmount = (valorAmount * batches[request.batchId].fixedValorToUsdcRateScaled) / VALOR_TO_USDC_RATE_PRECISION;
                    userRevenue[_user].chainedUsdcRevenue[chainId] += usdcAmount;
                }
                // Now we can remove this request
                uint256 lastIndex = userRevenue[_user].requests.length - 1;
                userRevenue[_user].requests[requestIndex] = userRevenue[_user].requests[lastIndex];
                userRevenue[_user].requests.pop();
            } else {
                requestIndex++;
            }
        }
    }

    // gap for upgradeable
    uint256[50] private __gap;
}
