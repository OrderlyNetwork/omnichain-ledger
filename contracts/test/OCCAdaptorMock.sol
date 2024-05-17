// SPDX-License-Identifier: MIT
pragma solidity 0.8.22;

import {IOCCLedgerReceiver, LedgerToken, OCCVaultMessage, OCCLedgerMessage} from "orderly-omnichain-occ/contracts/OCCInterface.sol";
import {PayloadDataType, LedgerPayloadTypes} from "../lib/LedgerTypes.sol";

contract OCCAdaptorMock {
    address public ledgerAppAddr;

    function setLedgerAppAddr(address _ledgerAppAddr) external {
        ledgerAppAddr = _ledgerAppAddr;
    }

    function claimRewards(
        uint32 _distributionId,
        address _user,
        uint256 _srcChainId,
        uint256 _cumulativeAmount,
        bytes32[] memory _merkleProof
    ) external {
        LedgerPayloadTypes.ClaimReward memory claimRewardPayload = LedgerPayloadTypes.ClaimReward({
            distributionId: _distributionId,
            user: _user,
            cumulativeAmount: _cumulativeAmount,
            merkleProof: _merkleProof
        });

        OCCVaultMessage memory message = OCCVaultMessage({
            srcChainId: _srcChainId,
            token: LedgerToken.ORDER,
            tokenAmount: 0,
            sender: _user,
            payloadType: uint8(PayloadDataType.ClaimReward),
            payload: abi.encode(claimRewardPayload)
        });
        IOCCLedgerReceiver(ledgerAppAddr).ledgerRecvFromVault(message);
    }
}
