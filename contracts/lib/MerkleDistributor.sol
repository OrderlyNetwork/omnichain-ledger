// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

struct MerkleTree {
    /// @dev The Merkle root.
    bytes32 merkleRoot;
    /// @dev The timestamp when this Merkle root become active.
    uint256 startTimestamp;
    /// @dev An IPFS CID pointing to the Merkle tree data.
    bytes ipfsCid;
}

struct Distribution {
    /// @dev Token address. If token is address(1), it means that the distribution is record based.
    address token;
    /// @dev The Merkle root and associated parameters.
    MerkleTree merkleTree;
}

abstract contract MerkleDistributor {

    /// @dev May propose new/updated Merkle roots for tokens.
    bytes32 public constant ROOT_UPDATER_ROLE = keccak256("ROOT_UPDATER_ROLE");

    /* ========== STATE VARIABLES ========== */

    /// @dev The active Distributions and associated parameters. Mapped on distribution id.
    mapping(uint32 => Distribution) internal activeDistributions;

    /// @dev The proposed Merkle root and associated parameters. Mapped on distribution id.
    mapping(uint32 => MerkleTree) internal proposedRoots;

    /// @dev Mapping of (distribution id) => (user address) => (claimed amount).
    mapping(uint32 => mapping(address => uint256)) internal claimedAmounts;

    /* ========== EVENTS ========== */

    /// @notice Emitted when a new distribution is created.
    event DistributionCreated(uint256 eventId, uint32 distributionId, address token, bytes32 merkleRoot, uint256 startTimestamp, bytes ipfsCid);

    /// @notice Emitted when a new Merkle root is proposed.
    event RootProposed(uint256 eventId, uint32 distributionId, bytes32 merkleRoot, uint256 startTimestamp, bytes ipfsCid);

    /// @notice Emitted when proposed Merkle root becomes active.
    event RootUpdated(uint256 eventId, uint32 distributionId, bytes32 merkleRoot, uint256 startTimestamp, bytes ipfsCid);

    /// @notice Emitted when a user (or behalf of user) claims rewards.
    event RewardsClaimed(uint256 eventId, uint32 distributionId, address account, uint256 amount, address token, uint32 dstEid);    

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

        /**
     * @notice Get the active Merkle root for distribution id and associated parameters.
     *         If there is a proposed root and the start timestamp has passed, it will be the active root.
     *         Because it will be updated at the beginning of the next claimReward call and become active from that moment.
     *         So, user will actually obtain the rewards from the proposed root and have to provide amount and proof for it.
     *
     * @param  _distributionId  The distribution id.
     *
     * @return  token          The address of the distributed token. If token is address(1), it means that the distribution is record based.
     * @return  merkleRoot     The Merkle root.
     * @return  startTimestamp Timestamp when this Merkle root become active.
     * @return  ipfsCid        An IPFS CID pointing to the Merkle tree data.
     */
    function getDistribution(
        uint32 _distributionId
    ) external view returns (address token, bytes32 merkleRoot, uint256 startTimestamp, bytes memory ipfsCid) {
        if (canUpdateRoot(_distributionId)) {
            return (
                activeDistributions[_distributionId].token,
                proposedRoots[_distributionId].merkleRoot,
                proposedRoots[_distributionId].startTimestamp,
                proposedRoots[_distributionId].ipfsCid
            );
        }
        return (
            activeDistributions[_distributionId].token,
            activeDistributions[_distributionId].merkleTree.merkleRoot,
            activeDistributions[_distributionId].merkleTree.startTimestamp,
            activeDistributions[_distributionId].merkleTree.ipfsCid
        );
    }

    /**
     * @notice Check if the distribution is record based.
     *
     * @param  _distributionId  The distribution id.
     *
     * @return Boolean `true` if the distribution is record based, else `false`.
     */
    function isDistributionRecordBased(uint32 _distributionId) external view returns (bool) {
        return activeDistributions[_distributionId].token == address(1);
    }

    /**
     * @notice Get the proposed Merkle root for token and associated parameters.
     *         When the proposed root become active, it will be removed from the proposedRoots mapping.
     *         So, this function will return non-zero values only if the proposed root is pending.
     *
     * @param  _distributionId  The distribution id.
     *
     * @return  merkleRoot     The proposed Merkle root.
     * @return  startTimestamp Timestamp when this Merkle root become active.
     * @return  ipfsCid        An IPFS CID pointing to the Merkle tree data.
     */
    function getProposedRoot(uint32 _distributionId) external view returns (bytes32 merkleRoot, uint256 startTimestamp, bytes memory ipfsCid) {
        return (proposedRoots[_distributionId].merkleRoot, proposedRoots[_distributionId].startTimestamp, proposedRoots[_distributionId].ipfsCid);
    }

    /**
     * @notice Get the tokens amount claimed so far by a given user.
     *
     * @param  _distributionId  The distribution id.
     * @param  _user  The address of the user.
     *
     * @return The amount tokens claimed so far by that user.
     */
    function getClaimed(uint32 _distributionId, address _user) external view returns (uint256) {
        return claimedAmounts[_distributionId][_user];
    }

    /**
     * @notice Returns true if there is a proposed root for given token waiting to become active.
     *         This is the case if the proposed root for given token is not zero.
     *
     * @param  _distributionId  The distribution id.
     *
     * @return Boolean `true` if there is a proposed root for given token waiting to become active, else `false`.
     */
    function hasPendingRoot(uint32 _distributionId) public view returns (bool) {
        return proposedRoots[_distributionId].merkleRoot != bytes32(0);
    }

    /**
     * @notice Returns true if there is a proposed root for given token waiting to become active
     *         and the start time has passed.
     *
     * @param  _distributionId  The distribution id.
     *
     * @return Boolean `true` if the active root can be updated to the proposed root, else `false`.
     */
    function canUpdateRoot(uint32 _distributionId) public view returns (bool) {
        return hasPendingRoot(_distributionId) && block.timestamp >= proposedRoots[_distributionId].startTimestamp;
    }    
}
