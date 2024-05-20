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
                stake(_user, _srcChainId, token, claimableAmount);
            } else {
                revert UnsupportedToken();
            }
        }
    }
}
