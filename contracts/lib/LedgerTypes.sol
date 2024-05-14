// SPDX-License-Identifier: MIT
pragma solidity 0.8.22;

enum PayloadDataType {
    ClaimReward
}

library LedgerTypes {
    struct ClaimReward {
        uint32 distributionId;
        address user;
        uint256 cumulativeAmount;
        bytes32[] merkleProof;
    }
}