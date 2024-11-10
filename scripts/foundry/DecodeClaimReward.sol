// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import "forge-std/Script.sol";
import "./BaseScript.sol";
import "./ConfigScript.sol";

import "../../contracts/lib/LedgerTypes.sol";
import "../../contracts/lib/OCCTypes.sol";
import {LedgerPayloadTypes} from "../../contracts/lib/LedgerTypes.sol";
import {MerkleProof} from "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";

contract DecodeClaimReward is BaseScript, ConfigScript {
    function run() external {
        bytes memory data = vm.envBytes("FS_DecodeClaimReward_calldata");

        OCCVaultMessage memory message = abi.decode(data, (OCCVaultMessage));
        LedgerPayloadTypes.ClaimReward memory claimRewardPayload = abi.decode(message.payload, (LedgerPayloadTypes.ClaimReward));
        // claimRewardPayload.distributionId,
        // message.sender,
        // message.chainedEventId,
        // message.srcChainId,
        // claimRewardPayload.cumulativeAmount,
        // claimRewardPayload.merkleProof
        // print them all
        console.log("distributionId:", claimRewardPayload.distributionId);
        console.log("sender:", message.sender);
        console.log("cumulativeAmount:", claimRewardPayload.cumulativeAmount);
        for (uint256 i = 0; i < claimRewardPayload.merkleProof.length; i++) {
            console.logBytes32(claimRewardPayload.merkleProof[i]);
        }
        bytes32 leaf = keccak256(bytes.concat(keccak256(abi.encode(message.sender, 2831296040126116310300))));
        console.log("leaf:");
        console.logBytes32(leaf);
        bytes32 computeHash = MerkleProof.processProof(claimRewardPayload.merkleProof, leaf);
        console.log("computeHash:");
        console.logBytes32(computeHash);
    }
}
