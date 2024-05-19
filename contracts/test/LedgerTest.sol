// SPDX-License-Identifier: MIT
pragma solidity 0.8.22;

import {Ledger} from "../Ledger.sol";

contract LedgerTest is Ledger {
    function claimRewards(
        uint32 _distributionId,
        address _user,
        uint256 _srcChainId,
        uint256 _cumulativeAmount,
        bytes32[] memory _merkleProof
    ) external {
        _claimRewards(_distributionId, _user, _srcChainId, _cumulativeAmount, _merkleProof);
    }
}
