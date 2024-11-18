// SPDX-License-Identifier: MIT
pragma solidity 0.8.22;

import {LedgerToken} from "./OCCTypes.sol";

enum PayloadDataType {
    /* ====== Payloads From vault side ====== */
    ClaimReward, // 0
    Stake, // 1
    CreateOrderUnstakeRequest, // 2
    CancelOrderUnstakeRequest, // 3
    WithdrawOrder, // 4
    EsOrderUnstakeAndVest, // 5
    CancelVestingRequest, // 6
    CancelAllVestingRequests, // 7 Not supported anymore. Do not remove for backward compatibility
    ClaimVestingRequest, // 8
    RedeemValor, // 9
    ClaimUsdcRevenue, // 10
    /* ====== Backward Payloads from ledger side ====== */
    ClaimRewardBackward, // 11
    WithdrawOrderBackward, // 12
    ClaimVestingRequestBackward, // 13
    ClaimUsdcRevenueBackward, // 14
    /* ====== New Payloads ====== */
    UnstakeOrderNow // 15
}

// Suppose that in the OCCVaultMessage, the sender and chainId can be used to get the chainId and user address for all the calls
// For deposited calls like Stake, LedgerToken and amount should be filled in the OCCVaultMessage
// For calls where only the user address and chainId are needed no additional structure payload needed.
// Calls without payload: Stake, WithdrawOrder, ClaimUsdcRevenue

library LedgerPayloadTypes {
    struct ClaimReward {
        uint32 distributionId;
        uint256 cumulativeAmount;
        bytes32[] merkleProof;
    }

    struct CreateOrderUnstakeRequest {
        uint256 amount;
    }

    struct EsOrderUnstakeAndVest {
        uint256 amount;
    }

    struct CancelVestingRequest {
        uint256 requestId;
    }

    struct ClaimVestingRequest {
        uint256 requestId;
    }

    struct RedeemValor {
        uint256 amount;
    }

    struct UnstakeOrderNow {
        uint256 amount;
    }
}

library LedgerSignedTypes {
    struct UintValueData {
        bytes32 r;
        bytes32 s;
        uint8 v;
        uint256 value;
        uint64 timestamp; // timestamp in milliseconds
    }
}
