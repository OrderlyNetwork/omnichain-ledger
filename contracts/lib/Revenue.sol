// SPDX-License-Identifier: MIT
pragma solidity 0.8.22;

import {Valor} from "./Valor.sol";

abstract contract Revenue is Valor{

    uint256 internal constant BATCH_DURATION = 14 days;

    struct Batch {
        bool claimable;
        uint256 totalAmount;
        uint256 claimedAmount;
    }

    struct UserReremprionRequest {
        uint16 batchId;
        uint256 amount;
    }
    struct UserRevenue {
        uint256 totalAmount;
        uint256 claimedAmount;
        UserReremprionRequest[] requests;
    }

    uint256 public startTimestamp;

    Batch[] public batches;

    mapping(address => UserRevenue) public userRevenue;

    event Redeemed(uint256 eventId, address indexed user, uint16 batchId, uint256 amount);

    error AmountIsGreaterThanPendingValor();

    function getCurrentBatchId() public view returns (uint16) {
        uint256 currentTimestamp = block.timestamp;
        if (currentTimestamp < startTimestamp) {
            return 0;
        }
        return uint16((currentTimestamp - startTimestamp) / BATCH_DURATION);
    }
}