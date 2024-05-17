// SPDX-License-Identifier: MIT
pragma solidity 0.8.22;

import {LedgerToken} from "orderly-omnichain-occ/contracts/OCCInterface.sol";

enum PayloadDataType {
    ClaimReward,
    Stake,
    CreateOrderUnstakeRequest,
    CancelOrderUnstakeRequest,
    WithdrawOrder,
    EsOrderUnstakeAndVest
}

library LedgerPayloadTypes {
    struct ClaimReward {
        uint32 distributionId;
        address user;
        uint256 cumulativeAmount;
        bytes32[] merkleProof;
    }

    // I believe chainId, sender, LedgerToken, and amount I can get from the OCCVaultMessage
    // It is enough for staking, no need for more information, so no Stake struct needed
    struct Stake {
        address user;
    }

    struct CreateOrderUnstakeRequest {
        address user;
        LedgerToken _token;
        uint256 _amount;
    }
}
