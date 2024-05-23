// SPDX-License-Identifier: MIT
pragma solidity 0.8.22;

import {LedgerToken} from "../lib/OCCTypes.sol";
import {Ledger} from "../Ledger.sol";

contract LedgerTest is Ledger {
    function claimRewards(
        uint32 _distributionId,
        address _user,
        uint256 _srcChainId,
        uint256 _cumulativeAmount,
        bytes32[] calldata _merkleProof
    ) external {
        (LedgerToken token, uint256 claimedAmount) = _claimRewards(_distributionId, _user, _srcChainId, _cumulativeAmount, _merkleProof);

        if (claimedAmount != 0) {
            if (token == LedgerToken.ORDER) {
                // $ORDER rewards are sent to user wallet on the source chain
            } else if (token == LedgerToken.ESORDER) {
                _stake(_user, _srcChainId, token, claimedAmount);
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
        _ledgerRedeemValor(_user, _chainId, _amount);
    }

    function claimUsdcRevenue(address _user, uint256 _chainId) external {
        _claimUsdcRevenue(_user, _chainId);
    }

    function stake(address _user, uint256 _chainId, LedgerToken _token, uint256 _amount) external {
        _stake(_user, _chainId, _token, _amount);
    }

    function createOrderUnstakeRequest(address _user, uint256 _chainId, uint256 _amount) external {
        _createOrderUnstakeRequest(_user, _chainId, _amount);
    }

    function cancelOrderUnstakeRequest(address _user, uint256 _chainId) external {
        _cancelOrderUnstakeRequest(_user, _chainId);
    }

    function withdrawOrder(address _user, uint256 _chainId) external {
        _withdrawOrder(_user, _chainId);
    }

    function esOrderUnstakeAndVest(address _user, uint256 _chainId, uint256 _amount) external {
        _ledgerEsOrderUnstakeAndVest(_user, _chainId, _amount);
    }

    function createVestingRequest(address _user, uint256 _chainId, uint256 _amountEsorder) external {
        _createVestingRequest(_user, _chainId, _amountEsorder);
    }

    function cancelVestingRequest(address _user, uint256 _chainId, uint256 _requestId) external returns (uint256 esOrderAmountToStakeBack) {
        esOrderAmountToStakeBack = _cancelVestingRequest(_user, _chainId, _requestId);
    }

    function cancelAllVestingRequests(address _user, uint256 _chainId) external returns (uint256 esOrderAmountToStakeBack) {
        esOrderAmountToStakeBack = _cancelAllVestingRequests(_user, _chainId);
    }

    function claimVestingRequest(address _user, uint256 _chainId, uint256 _requestId) external returns (uint256 claimedOrderAmount) {
        claimedOrderAmount = _claimVestingRequest(_user, _chainId, _requestId);
    }

    function nuberOfUsersBatchedReremprionRequests(address _user) external view returns (uint256) {
        return userRevenue[_user].requests.length;
    }
}
