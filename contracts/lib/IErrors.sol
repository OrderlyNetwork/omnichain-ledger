// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

interface IErrors {
    error DistributionAlreadyExists();
    error DistributionNotFound();
    error TokenIsZero();
    error ProposedMerkleRootIsZero();
    error StartTimestampIsInThePast();
    error ThisMerkleRootIsAlreadyProposed();
    error CannotUpdateRoot();
    error NoActiveMerkleRoot();
    error InvalidMerkleProof();
    error OFTTransferFailed();
}
