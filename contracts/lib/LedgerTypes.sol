// SPDX-License-Identifier: MIT
pragma solidity 0.8.22;

import {LedgerToken} from "./OCCTypes.sol";

enum PayloadDataType {
    /* ====== Payloads From vault side ====== */
    ClaimReward,
    Stake,
    CreateOrderUnstakeRequest,
    CancelOrderUnstakeRequest,
    WithdrawOrder,
    EsOrderUnstakeAndVest,
    RedeemValor,
    ClaimUsdcRevenue,
    /* ====== Backward Payloads from ledger side ====== */
    ClaimRewardBackward,
    WithdrawOrderBackward,
    ClaimUsdcRevenueBackward
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

    struct CancelOrderUnstakeRequest {
        uint256 amount;
    }

    struct EsOrderUnstakeAndVest {
        uint256 amount;
    }

    struct RedeemValor {
        uint256 amount;
    }
}
