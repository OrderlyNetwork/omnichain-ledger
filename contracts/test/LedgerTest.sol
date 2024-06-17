// SPDX-License-Identifier: MIT
pragma solidity 0.8.22;

import {LedgerToken} from "../lib/OCCTypes.sol";
import {LedgerSignedTypes} from "../lib/LedgerTypes.sol";
import {Signature} from "../lib/Signature.sol";
import {OmnichainLedgerV1} from "../OmnichainLedgerV1.sol";

contract LedgerTest is OmnichainLedgerV1 {
    function chainedEventId() internal returns (uint256) {
        return 1;
    }

    function claimRewards(
        uint32 _distributionId,
        address _user,
        uint256 _srcChainId,
        uint256 _cumulativeAmount,
        bytes32[] calldata _merkleProof
    ) external {
        (LedgerToken token, uint256 claimedAmount) = _claimRewards(
            _distributionId,
            _user,
            chainedEventId(),
            _srcChainId,
            _cumulativeAmount,
            _merkleProof
        );

        if (claimedAmount != 0) {
            if (token == LedgerToken.ORDER) {
                // $ORDER rewards are sent to user wallet on the source chain
            } else if (token == LedgerToken.ESORDER) {
                _stake(_user, chainedEventId(), _srcChainId, token, claimedAmount);
            } else {
                revert UnsupportedToken();
            }
        }
    }

    function setTotalValorAmount(uint256 _amount) external {
        totalValorAmount = _amount;
    }

    function setCollectedValor(address _user, uint256 _amount) external {
        collectedValor[_user] = _amount;
    }

    function redeemValor(address _user, uint256 _chainId, uint256 _amount) external {
        _ledgerRedeemValor(_user, chainedEventId(), _chainId, _amount);
    }

    function claimUsdcRevenue(address _user, uint256 _chainId) external {
        _claimUsdcRevenue(_user, chainedEventId(), _chainId);
    }

    function stake(address _user, uint256 _chainId, LedgerToken _token, uint256 _amount) external {
        _stake(_user, chainedEventId(), _chainId, _token, _amount);
    }

    function createOrderUnstakeRequest(address _user, uint256 _chainId, uint256 _amount) external {
        _createOrderUnstakeRequest(_user, chainedEventId(), _chainId, _amount);
    }

    function cancelOrderUnstakeRequest(address _user, uint256 _chainId) external {
        _cancelOrderUnstakeRequest(_user, chainedEventId(), _chainId);
    }

    function withdrawOrder(address _user, uint256 _chainId) external {
        _withdrawOrder(_user, chainedEventId(), _chainId);
    }

    function esOrderUnstakeAndVest(address _user, uint256 _chainId, uint256 _amount) external {
        _ledgerEsOrderUnstakeAndVest(_user, chainedEventId(), _chainId, _amount);
    }

    function createVestingRequest(address _user, uint256 _chainId, uint256 _amountEsorder) external {
        _createVestingRequest(_user, chainedEventId(), _chainId, _amountEsorder);
    }

    function cancelVestingRequest(address _user, uint256 _chainId, uint256 _requestId) external returns (uint256 esOrderAmountToStakeBack) {
        esOrderAmountToStakeBack = _cancelVestingRequest(_user, chainedEventId(), _chainId, _requestId);
    }

    function cancelAllVestingRequests(address _user, uint256 _chainId) external returns (uint256 esOrderAmountToStakeBack) {
        esOrderAmountToStakeBack = _cancelAllVestingRequests(_user, chainedEventId(), _chainId);
    }

    function claimVestingRequest(
        address _user,
        uint256 _chainId,
        uint256 _requestId
    ) external returns (uint256 claimedOrderAmount, uint256 unclaimedOrderAmount) {
        (claimedOrderAmount, unclaimedOrderAmount) = _claimVestingRequest(_user, chainedEventId(), _chainId, _requestId);
    }

    function nuberOfUsersBatchedRedemptionRequests(address _user) external view returns (uint256) {
        return userRevenue[_user].requests.length;
    }

    function dailyUsdcNetFeeRevenueTestNoSignatureCheck(uint256 _usdcNetFeeRevenue) public onlyRole(TREASURE_UPDATER_ROLE) {
        _dailyUsdcNetFeeRevenueTest(_usdcNetFeeRevenue, block.timestamp);
    }

    function dailyUsdcNetFeeRevenueTestNoTimeCheck(LedgerSignedTypes.UintValueData calldata data) external onlyRole(TREASURE_UPDATER_ROLE) {
        Signature.verifyUintValueSignature(data, usdcUpdaterAddress);
        _dailyUsdcNetFeeRevenueTest(data.value, data.timestamp);
    }

    function _dailyUsdcNetFeeRevenueTest(uint256 _usdcNetFeeRevenue, uint256 _timestamp) public onlyRole(TREASURE_UPDATER_ROLE) {
        lastUsdcNetFeeRevenueUpdateTimestamp = block.timestamp;
        totalUsdcInTreasure += _usdcNetFeeRevenue;
        _updateValorToUsdcRateScaled();
        emit DailyUsdcNetFeeRevenueUpdated(_timestamp, _usdcNetFeeRevenue, totalUsdcInTreasure, totalValorAmount, valorToUsdcRateScaled);
        _possiblyFixBatchValorToUsdcRateForPreviousBatch();
    }
}
