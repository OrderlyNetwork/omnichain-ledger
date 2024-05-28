// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

library MerkleTreeHelper {
    event VerifyLog(bytes32 computedHash, bytes32 root);

    struct Tree {
        bytes32 root;
        bytes32[] hashes;
        uint256 depth;
    }

    function buildTree(address[] memory users, uint256[] memory amounts) internal pure returns (Tree memory) {
        require(users.length == amounts.length, "Users and amounts array must be of the same length");

        uint256 n = users.length;
        uint256 hashLength = 0;
        uint256 layerLength = n;
        uint256 depth = 0;
        for (;layerLength>0;) {
            hashLength += layerLength;
            depth++;
            if (layerLength == 1) {
                break;
            }
            layerLength = (layerLength + 1) / 2;
        }
        bytes32[] memory hashes = new bytes32[](hashLength);

        // Calculate leaf nodes
        for (uint256 i = 0; i < n; i++) {
            hashes[i] = keccak256(bytes.concat(keccak256(abi.encode(users[i], amounts[i]))));
        }

        // Calculate internal nodes
        uint256 offset = n;
        uint256 layerOffset = 0;
        layerLength = n;
        for(uint256 i = 1; i < depth; i++) {
            uint256 newlayerLength = (layerLength + 1) / 2;
            for (uint256 j = 0; j < newlayerLength; j++) {
                bytes32 hashLeft = hashes[layerOffset + j * 2];
                bytes32 hashRight = j * 2 + 1 < offset? hashes[layerOffset + j * 2 + 1] : bytes32(0);
                if (hashLeft < hashRight) {
                    hashes[offset + j] = keccak256(abi.encodePacked(hashLeft, hashRight));
                } else {
                    hashes[offset + j] = keccak256(abi.encodePacked(hashRight, hashLeft));
                }
            }
            offset += newlayerLength;
            layerOffset += layerLength;
            layerLength = newlayerLength;
        }


        return Tree({
            root: hashes[hashes.length - 1],
            hashes: hashes,
            depth: depth
        });
    }

    function getProof(Tree memory tree, uint256 index, uint256 nodeLength) internal pure returns (bytes32[] memory) {
        uint256 proofLength = tree.depth - 1;
        bytes32[] memory proof = new bytes32[](proofLength);

        uint256 nodeIndex = index;
        uint256 layerLength = nodeLength;
        uint256 offset = 0;
        for (uint i = 0; i < proofLength; i++) {
            uint256 siblingIndex = nodeIndex + 1;
            if (siblingIndex >= layerLength) {
                proof[i] = bytes32(0);
            } else {
                proof[i] = tree.hashes[offset + siblingIndex];
            }
            offset += layerLength;
            nodeIndex = nodeIndex / 2;
        }

        return proof;
    }

    function verifyProof(bytes32 root, bytes32 leaf, bytes32[] memory proof) internal {
        bytes32 computedHash = leaf;

        for (uint256 i = 0; i < proof.length; i++) {
            // compare the computed hash with the provided hash in the proof
            if (computedHash < proof[i]) {
                computedHash = keccak256(abi.encodePacked(computedHash, proof[i]));
            } else {
                computedHash = keccak256(abi.encodePacked(proof[i], computedHash));
            }
        }
        emit VerifyLog(computedHash, root); 
        require(computedHash == root, "MerkleTreeHelper: Invalid proof");
    }
}