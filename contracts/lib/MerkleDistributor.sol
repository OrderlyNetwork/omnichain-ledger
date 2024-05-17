// SPDX-License-Identifier: MIT
pragma solidity 0.8.22;

import {LedgerToken} from "orderly-omnichain-occ/contracts/OCCInterface.sol";
import {MerkleProof} from "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";

import {LedgerAccessControl} from "./LedgerAccessControl.sol";
import {ChainedEventIdCounter} from "./ChainedEventIdCounter.sol";

abstract contract MerkleDistributor is LedgerAccessControl, ChainedEventIdCounter {
    /// @dev May propose new/updated Merkle roots for tokens.
    bytes32 public constant ROOT_UPDATER_ROLE = keccak256("ROOT_UPDATER_ROLE");

    struct MerkleTree {
        /// @dev The Merkle root.
        bytes32 merkleRoot;
        /// @dev The timestamp when this Merkle root become active.
        uint256 startTimestamp;
        /// @dev An IPFS CID pointing to the Merkle tree data.
        bytes ipfsCid;
    }

    struct Distribution {
        /// @dev Token of the distribution.
        LedgerToken token;
        /// @dev The Merkle root and associated parameters.
        MerkleTree merkleTree;
    }

    /* ========== STATE VARIABLES ========== */

    /// @dev The active Distributions and associated parameters. Mapped on distribution id.
    mapping(uint32 => Distribution) internal activeDistributions;

    /// @dev The proposed Merkle root and associated parameters. Mapped on distribution id.
    mapping(uint32 => MerkleTree) internal proposedRoots;

    /// @dev Mapping of (distribution id) => (user address) => (claimed amount).
    mapping(uint32 => mapping(address => uint256)) internal claimedAmounts;

    /* ========== EVENTS ========== */

    /// @notice Emitted when a new distribution is created.
    event DistributionCreated(uint256 eventId, uint32 distributionId, LedgerToken token, bytes32 merkleRoot, uint256 startTimestamp, bytes ipfsCid);

    /// @notice Emitted when a new Merkle root is proposed.
    event RootProposed(uint256 eventId, uint32 distributionId, bytes32 merkleRoot, uint256 startTimestamp, bytes ipfsCid);

    /// @notice Emitted when proposed Merkle root becomes active.
    event RootUpdated(uint256 eventId, uint32 distributionId, bytes32 merkleRoot, uint256 startTimestamp, bytes ipfsCid);

    /// @notice Emitted when a user (or behalf of user) claims rewards.
    event RewardsClaimed(uint256 eventId, uint32 distributionId, address account, uint256 amount, LedgerToken token, uint256 dstEid);

    /* ========== ERRORS ========== */

    error DistributionAlreadyExists();
    error DistributionNotFound();
    error ProposedMerkleRootIsZero();
    error StartTimestampIsInThePast();
    error ThisMerkleRootIsAlreadyProposed();
    error CannotUpdateRoot();
    error NoActiveMerkleRoot();
    error InvalidMerkleProof();
    error OFTTransferFailed();

    /* ========== MODIFIERS ========== */
    modifier onlyUpdater() {
        _checkRole(ROOT_UPDATER_ROLE);
        _;
    }

    /* ========== INITIALIZER ========== */

    function merkleDistributorInit(address owner) internal onlyInitializing {
        // _setupRole(ROOT_UPDATER_ROLE, owner);
    }

    /* ========== PUBLIC FUNCTIONS ========== */

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
    ) external view returns (LedgerToken token, bytes32 merkleRoot, uint256 startTimestamp, bytes memory ipfsCid) {
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
        return activeDistributions[_distributionId].token == LedgerToken.ESORDER;
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

    /* ========== ROOT UPDATES ========== */

    /**
     * @notice Create a new distribution with the given token and propose Merkle root for it.
     *         Locked for ROOT_UPDATER_ROLE.
     *         Once created, distribution token can't be changed.
     *
     * @param  _distributionId  The distribution id.
     * @param  _token           The address of the token.
     * @param  _merkleRoot      The Merkle root.
     * @param  _startTimestamp  The timestamp when this Merkle root become active.
     * @param  _ipfsCid         An IPFS CID pointing to the Merkle tree data.
     *
     *  Reverts if the distribution with the same id is already exists or Merkle root params are invalid.
     */
    function createDistribution(
        uint32 _distributionId,
        LedgerToken _token,
        bytes32 _merkleRoot,
        uint256 _startTimestamp,
        bytes calldata _ipfsCid
    ) external nonReentrant onlyUpdater {
        if (_distributionExists(_distributionId)) revert DistributionAlreadyExists();

        activeDistributions[_distributionId] = Distribution({
            token: _token,
            merkleTree: MerkleTree({merkleRoot: "", startTimestamp: 1, ipfsCid: ""})
        });

        _proposeRoot(_distributionId, _merkleRoot, _startTimestamp, _ipfsCid);

        emit DistributionCreated(_getNextChainedEventId(0), _distributionId, _token, _merkleRoot, _startTimestamp, _ipfsCid);
    }

    /**
     * @notice Set the proposed root parameters.
     *         Locked for ROOT_UPDATER_ROLE.
     *         Allows to update proposed root for token before startTimestamp passed.
     *         If startTimestamp passed, proposed root will be propogated to active root.
     *
     * @param  _distributionId  The distribution id.
     * @param  _merkleRoot     The Merkle root.
     * @param  _startTimestamp The timestamp when this Merkle root become active
     * @param  _ipfsCid        An IPFS CID pointing to the Merkle tree data.
     *
     *  Reverts if the proposed root is bytes32(0).
     *  Reverts if the proposed startTimestamp is in the past.
     *  Reverts if the proposed root is already proposed.
     */
    function proposeRoot(
        uint32 _distributionId,
        bytes32 _merkleRoot,
        uint256 _startTimestamp,
        bytes calldata _ipfsCid
    ) public nonReentrant onlyUpdater {
        _proposeRoot(_distributionId, _merkleRoot, _startTimestamp, _ipfsCid);
    }

    /**
     * @notice Set the active root parameters to the proposed root parameters.
     *         Non-reeentrant guard is disabled because this function is called from claimRewards.
     *
     * @param  _distributionId  The distribution id.
     *  Reverts if root updates are paused.
     *  Reverts if the proposed root is bytes32(0).
     *  Reverts if the proposed root epoch is not equal to the next root epoch.
     *  Reverts if the waiting period for the proposed root has not elapsed.
     */
    function updateRoot(uint32 _distributionId) public whenNotPaused {
        if (!canUpdateRoot(_distributionId)) revert CannotUpdateRoot();

        activeDistributions[_distributionId].merkleTree = proposedRoots[_distributionId];
        delete proposedRoots[_distributionId];

        emit RootUpdated(
            _getNextChainedEventId(0),
            _distributionId,
            activeDistributions[_distributionId].merkleTree.merkleRoot,
            activeDistributions[_distributionId].merkleTree.startTimestamp,
            activeDistributions[_distributionId].merkleTree.ipfsCid
        );
    }

    /* ========== USER FUNCTIONS ========== */

    /**
     * @notice Claim the remaining unclaimed rewards for a user, and send them to that user on the chain, pointed by _dstEid.
     * Works only if distribution is OFT token based.
     * Send tokens using LZ bridge to the
     * Claim the remaining unclaimed rewards for a user, and send them to that user.
     *         Will propogate pending Merkle root updates before claiming if startTimestamp has
     *         passed for the token.
     *
     * @param  _distributionId  The distribution id.
     * @param  _user            Address of the user.
     * @param  _srcChainId      The source chain id.
     * @param  _cumulativeAmount The total all-time rewards this user has earned.
     * @param  _merkleProof      The Merkle proof for the user and cumulative amount.
     *
     * @return claimableAmount  The number of rewards tokens claimed.
     *
     *  Reverts if the distribution is not OFT token based.
     *  Reverts if no active Merkle root is set for the _distributionId.
     *  Reverts if the provided Merkle proof is invalid.
     */
    function claimRewards(
        uint32 _distributionId,
        address _user,
        uint256 _srcChainId,
        uint256 _cumulativeAmount,
        bytes32[] memory _merkleProof
    ) internal whenNotPaused nonReentrant returns (uint256 claimableAmount) {
        if (canUpdateRoot(_distributionId)) {
            updateRoot(_distributionId);
        }

        // Distribution should be created (has not null token address).
        if (!_distributionExists(_distributionId)) revert DistributionNotFound();

        // Verify the Merkle proof.
        {
            // Get the active Merkle root.
            MerkleTree storage activeMerkleTree = activeDistributions[_distributionId].merkleTree;
            if (activeMerkleTree.merkleRoot == bytes32(0)) revert NoActiveMerkleRoot();
            bytes32 merkleRoot = activeMerkleTree.merkleRoot;

            // Verify the Merkle proof.
            bytes32 leaf = keccak256(bytes.concat(keccak256(abi.encode(_user, _cumulativeAmount))));
            if (!MerkleProof.verify(_merkleProof, merkleRoot, leaf)) revert InvalidMerkleProof();
        }

        // Get the claimable amount.
        //
        // Note: If this reverts, then there was an error in the Merkle tree, since the cumulative
        // amount for a given user should never decrease over time.
        claimableAmount = _cumulativeAmount - claimedAmounts[_distributionId][_user];

        if (claimableAmount > 0) {
            // Mark the user as having claimed the full amount.
            claimedAmounts[_distributionId][_user] = _cumulativeAmount;

            LedgerToken token = activeDistributions[_distributionId].token;

            // If distribution is token based, send the claimable amount to the user on the destination chain.
            // Record based distributions just return the claimable amount.
            if (token == LedgerToken.ORDER) {
                // TODO: just send $ORDER tokens to the OCC adaptor
            } else {
                // TODO: implement staking!
                // Record based distribution. Stake the claimable amount.
                return claimableAmount;
            }

            emit RewardsClaimed(_getNextChainedEventId(0), _distributionId, _user, claimableAmount, token, _srcChainId);
        }
    }

    /* ========== PRIVATE FUNCTIONS ========== */

    function _proposeRoot(uint32 _distributionId, bytes32 _merkleRoot, uint256 _startTimestamp, bytes calldata _ipfsCid) private {
        if (!_distributionExists(_distributionId)) revert DistributionNotFound();

        if (_merkleRoot == bytes32(0)) revert ProposedMerkleRootIsZero();

        if (_startTimestamp < block.timestamp) revert StartTimestampIsInThePast();

        if (
            _merkleRoot == proposedRoots[_distributionId].merkleRoot &&
            _startTimestamp == proposedRoots[_distributionId].startTimestamp &&
            keccak256(_ipfsCid) == keccak256(proposedRoots[_distributionId].ipfsCid)
        ) revert ThisMerkleRootIsAlreadyProposed();

        if (canUpdateRoot(_distributionId)) {
            updateRoot(_distributionId);
        }

        // Set the proposed root and the start timestamp when proposed root to become active.
        proposedRoots[_distributionId] = MerkleTree({merkleRoot: _merkleRoot, startTimestamp: _startTimestamp, ipfsCid: _ipfsCid});

        emit RootProposed(_getNextChainedEventId(0), _distributionId, _merkleRoot, _startTimestamp, _ipfsCid);
    }

    /**
     * @dev Converts an address to bytes32.
     * @param _addr The address to convert.
     * @return The bytes32 representation of the address.
     */
    function _addressToBytes32(address _addr) private pure returns (bytes32) {
        return bytes32(uint256(uint160(_addr)));
    }

    /**
     * @dev Checks if the distribution exists.
     * @param _distributionId The distribution id.
     * @return Boolean `true` if the distribution exists, else `false`.
     */
    function _distributionExists(uint32 _distributionId) private view returns (bool) {
        return activeDistributions[_distributionId].merkleTree.startTimestamp != 0;
    }
}
