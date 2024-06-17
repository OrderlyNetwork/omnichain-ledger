// SPDX-License-Identifier: MIT
pragma solidity 0.8.22;

import {LedgerToken} from "./OCCTypes.sol";
import {MerkleProof} from "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";

import {LedgerAccessControl} from "./LedgerAccessControl.sol";
import {ChainedEventIdCounter} from "./ChainedEventIdCounter.sol";

/**
 * @title MerkleDistributor
 * @author Orderly Network
 * @notice This contract aimed for the distribution of
 *         - Trading rewards
 *         - Market Maker rewards
 *
 *         Contract allows to create distributions and propose updated Merkle roots for them.
 *         Each distribution has it's own token, that can't be changed after creation.
 *         Several distributions can have the same token.
 *         Distribution supports two types of tokens: $ORDER and es$ORDER (record based).
 *         Contract supports distribution of continuously growing rewards. Wor that purpose, it supports root updates for distributions.
 *         Next root should contain cummulative (not decreasing) amount of rewards for each user from the previous root.
 *         Contract does not transfer tokens to the users, it only returns the type and amount of tokens that user claimed.
 *         Contract supposed to be a part of the Ledger contract.
 *         Parent contract should implement the claimRewards function that will call _claimRewards function from this contract.
 */

abstract contract MerkleDistributor is LedgerAccessControl, ChainedEventIdCounter {
    /// @dev May create distributions and propose updated Merkle roots for them.
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

    /// @dev Mapping of (distribution id) => (active Distribution).
    mapping(uint32 => Distribution) internal activeDistributions;

    /// @dev Mapping of (distribution id) => (proposed Merkle root).
    mapping(uint32 => MerkleTree) internal proposedRoots;

    /// @dev Mapping of (distribution id) => (user address) => (claimed amount).
    mapping(uint32 => mapping(address => uint256)) internal claimedAmounts;

    /* ========== EVENTS ========== */

    /// @notice Emitted when a new distribution is created by the ROOT_UPDATER_ROLE from Ledger chain.
    event DistributionCreated(uint32 indexed distributionId, LedgerToken token, bytes32 merkleRoot, uint256 startTimestamp, bytes ipfsCid);

    /// @notice Emitted when a new Merkle root is proposed by the ROOT_UPDATER_ROLE from Ledger chain.
    event RootProposed(uint32 indexed distributionId, bytes32 merkleRoot, uint256 startTimestamp, bytes ipfsCid);

    /// @notice Emitted when proposed Merkle root becomes active by the ROOT_UPDATER_ROLE from Ledger chain.
    event RootUpdated(uint32 indexed distributionId, bytes32 merkleRoot, uint256 startTimestamp, bytes ipfsCid);

    /// @notice Emitted when a user claims rewards from Vault chains.
    event RewardsClaimed(
        uint256 indexed chainedEventId,
        uint256 indexed chainId,
        uint32 indexed distributionId,
        address account,
        uint256 amount,
        LedgerToken token
    );

    /* ========== ERRORS ========== */

    error DistributionAlreadyExists();
    error TokenIsNotSupportedForDistribution();
    error DistributionNotFound();
    error ProposedMerkleRootIsZero();
    error StartTimestampIsInThePast();
    error ThisMerkleRootIsAlreadyProposed();
    error CannotUpdateRoot();
    error NoActiveMerkleRoot();
    error InvalidMerkleProof();

    /* ========== MODIFIERS ========== */
    modifier onlyUpdater() {
        _checkRole(ROOT_UPDATER_ROLE);
        _;
    }

    /* ========== INITIALIZER ========== */

    function merkleDistributorInit(address owner) internal onlyInitializing {
        _grantRole(ROOT_UPDATER_ROLE, owner);
    }

    /* ========== VIEW FUNCTIONS ========== */

    /**
     * @notice Get the active Merkle root for distribution id and associated parameters.
     *         If distribution has proposed root and it's start timestamp has passed, proposed root will be returned.
     *         It allows to reduce probability of collision when user claiming rewards from the old Merkle root.
     *         Because it will be updated at the beginning of the next claimReward call and become active from that moment.
     *         So, user will actually obtain the rewards from the proposed root and have to provide amount and proof for it.
     *
     * @param  _distributionId  The distribution id.
     *
     * @return  token          The type of the distributed token. Currently only $ORDER token and es$ORDER (record based) are supported.
     * @return  merkleRoot     The Merkle root.
     * @return  startTimestamp Timestamp when this Merkle root become active.
     * @return  ipfsCid        An IPFS CID pointing to the Merkle tree data (optional, can be 0x0).
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
     * @notice Check if the distribution is record based. Currently only es$ORDER token is record based.
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
     * @return  ipfsCid        An IPFS CID pointing to the Merkle tree data (optional, can be 0x0).
     */
    function getProposedRoot(uint32 _distributionId) external view returns (bytes32 merkleRoot, uint256 startTimestamp, bytes memory ipfsCid) {
        return (proposedRoots[_distributionId].merkleRoot, proposedRoots[_distributionId].startTimestamp, proposedRoots[_distributionId].ipfsCid);
    }

    /**
     * @notice Get the tokens amount claimed so far for distribution by a given user.
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
     * @notice Returns true if there is a proposed root for given distribution waiting to become active.
     *         This is the case if the proposed root for given distribution is not zero.
     *
     * @param  _distributionId  The distribution id.
     *
     * @return Boolean `true` if there is a proposed root for given distribution waiting to become active, else `false`.
     */
    function hasPendingRoot(uint32 _distributionId) public view returns (bool) {
        return proposedRoots[_distributionId].merkleRoot != bytes32(0);
    }

    /**
     * @notice Returns true if there is a proposed root for given distribution waiting to become active
     *         and the start time has passed.
     *
     * @param  _distributionId  The distribution id.
     *
     * @return Boolean `true` if the active root can be updated to the proposed root, else `false`.
     */
    function canUpdateRoot(uint32 _distributionId) public view returns (bool) {
        return hasPendingRoot(_distributionId) && block.timestamp >= proposedRoots[_distributionId].startTimestamp;
    }

    /* ========== DISTRIBUTION CREATION AND ROOT UPDATES ========== */

    /**
     * @notice Create a new distribution with the given token and propose Merkle root for it.
     *         Locked for ROOT_UPDATER_ROLE.
     *         Once created, distribution token can't be changed.
     *
     * @param  _distributionId  The distribution id.
     * @param  _token           The type of the token. Currently only $ORDER token and es$ORDER (record based) are supported.
     * @param  _merkleRoot      The Merkle root.
     * @param  _startTimestamp  The timestamp when this Merkle root become active.
     * @param  _ipfsCid         An IPFS CID pointing to the Merkle tree data. (optional, can be 0x0)
     *
     * Reverts if the distribution with the same id is already exists or Merkle root params are invalid.
     * Reverts if the token is not supported for distribution. Currently only $ORDER and es$ORDER tokens are supported.
     */
    function createDistribution(
        uint32 _distributionId,
        LedgerToken _token,
        bytes32 _merkleRoot,
        uint256 _startTimestamp,
        bytes calldata _ipfsCid
    ) external whenNotPaused nonReentrant onlyUpdater {
        if (_distributionExists(_distributionId)) revert DistributionAlreadyExists();
        if (_token != LedgerToken.ORDER && _token != LedgerToken.ESORDER) revert TokenIsNotSupportedForDistribution();

        // Creates distribution with empty merkleTree. Proposed root will be set in the next step.
        activeDistributions[_distributionId] = Distribution({
            token: _token,
            merkleTree: MerkleTree({merkleRoot: "", startTimestamp: 1, ipfsCid: ""})
        });

        // Check and propose root for the created distribution. It become active after startTimestamp passed.
        _proposeRoot(_distributionId, _merkleRoot, _startTimestamp, _ipfsCid);

        emit DistributionCreated(_distributionId, _token, _merkleRoot, _startTimestamp, _ipfsCid);
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
    ) public whenNotPaused nonReentrant onlyUpdater {
        _proposeRoot(_distributionId, _merkleRoot, _startTimestamp, _ipfsCid);
    }

    /**
     * @notice Propagate proposed root to the distribution if it can be updated.
     *         Non-reeentrant guard is disabled because this function is called from claimRewards.
     *
     * @param  _distributionId  The distribution id.
     *
     *  Reverts if root updates are paused.
     *  Reverts if the proposed root is bytes32(0).
     *  Reverts if the waiting period for the proposed root has not elapsed.
     */
    function updateRoot(uint32 _distributionId) public whenNotPaused {
        if (!canUpdateRoot(_distributionId)) revert CannotUpdateRoot();

        activeDistributions[_distributionId].merkleTree = proposedRoots[_distributionId];
        delete proposedRoots[_distributionId];

        emit RootUpdated(
            _distributionId,
            activeDistributions[_distributionId].merkleTree.merkleRoot,
            activeDistributions[_distributionId].merkleTree.startTimestamp,
            activeDistributions[_distributionId].merkleTree.ipfsCid
        );
    }

    /* ========== USER FUNCTIONS ========== */

    /**
     * @notice Check Merkle proof and claim the remaining unclaimed rewards for a user.
     *         Will propogate pending Merkle root updates before claiming if startTimestamp for pending root has passed.
     *         Return the type of token and claimable amount.
     *         Caller (Ledger contract) should transfer the token to the user or stake if token is record based.
     *
     *  Reverts if there is no active distribution for the _distributionId.
     *  Reverts if no active Merkle root is set for the _distributionId.
     *  Reverts if the provided Merkle proof is invalid.
     */
    function _claimRewards(
        uint32 _distributionId,
        address _user,
        uint256 _chainedEventId,
        uint256 _srcChainId,
        uint256 _cumulativeAmount,
        bytes32[] memory _merkleProof
    ) internal whenNotPaused nonReentrant returns (LedgerToken token, uint256 claimableAmount) {
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

        // Note: If next operation reverts, then there was an error in the Merkle tree, since the cumulative
        // amount for a given user should never decrease over time.
        claimableAmount = _cumulativeAmount - claimedAmounts[_distributionId][_user];
        token = activeDistributions[_distributionId].token;

        claimedAmounts[_distributionId][_user] = _cumulativeAmount;

        if (claimableAmount > 0) {
            emit RewardsClaimed(_chainedEventId, _srcChainId, _distributionId, _user, claimableAmount, token);
        }
    }

    /* ========== PRIVATE FUNCTIONS ========== */

    /**
     * @notice Check params and propose root for the distribution.
     */
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

        emit RootProposed(_distributionId, _merkleRoot, _startTimestamp, _ipfsCid);
    }

    /**
     * @dev Checks if the distribution exists.
     * @param _distributionId The distribution id.
     * @return Boolean `true` if the distribution exists, else `false`.
     */
    function _distributionExists(uint32 _distributionId) private view returns (bool) {
        return activeDistributions[_distributionId].merkleTree.startTimestamp != 0;
    }

    // gap for upgradeable
    uint256[50] private __gap;
}
