// SPDX-License-Identifier: MIT
pragma solidity 0.8.22;

import {LedgerToken} from "orderly-omnichain-occ/contracts/OCCInterface.sol";
import {Ledger} from "../Ledger.sol";

contract LedgerTest is Ledger {
    function claimRewards(
        uint32 _distributionId,
        address _user,
        uint256 _srcChainId,
        uint256 _cumulativeAmount,
        bytes32[] memory _merkleProof
    ) external {
        (LedgerToken token, uint256 claimableAmount) = _claimRewards(_distributionId, _user, _srcChainId, _cumulativeAmount, _merkleProof);
        if (claimableAmount != 0) {
            if (token == LedgerToken.ORDER) {
                // compose message to OCCAdapter to transfer claimableAmount of $ORDER to message.sender
            } else if (token == LedgerToken.ESORDER) {
                _stake(_user, _srcChainId, token, claimableAmount);
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
        _updateValorVarsAndCollectValor(_user);
        _redeemValor(_user, _chainId, _amount);
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
        _esOrderUnstakeAndVest(_user, _chainId, _amount);
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
}
