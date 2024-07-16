// SPDX-License-Identifier: MIT
pragma solidity 0.8.22;

import {IERC20, SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {MerkleProof} from "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

import {EventIdCounter} from "./lib/EventIdCounter.sol";

/**
 * @title  Orderly MerkleDistributor for Layer 1
 * @author Orderly Network
 * @notice This contract aimed for the distribution of airdrops for early orderly users, orderly NFT holders, target users
 *
 *         Distribution based on Merkle distribution mechanism similar to Uniswap's MerkleDistributor.
 *
 *         The Merkle root can be updated by owner.
 *         It allows to distribute continuously growing rewards.
 *         For that purpose Merkle tree contains leafs with cumulative non-decreasing reward amounts.
 *
 *         Contract is pausible by owner. It allows to pause claiming rewards.
 *         The contract is upgradeable to allow for future changes to the rewards distribution mechanism.
 */
contract MerkleDistributorL1 is Initializable, UUPSUpgradeable, OwnableUpgradeable, ReentrancyGuardUpgradeable, PausableUpgradeable, EventIdCounter {
    using SafeERC20 for IERC20;

    /// @dev The parameters related to a certain Merkle tree.
    struct MerkleTree {
        /// @dev The Merkle root.
        bytes32 merkleRoot;
        /// @dev The timestamp when this Merkle root become active.
        uint256 startTimestamp;
        /// @dev The timestamp when distribution stops. Zero means no end time.
        uint256 endTimestamp;
        /// @dev An IPFS CID pointing to the Merkle tree data.
        bytes ipfsCid;
    }

    /* ========== STATE VARIABLES ========== */

    address public token;

    /// @dev The active Merkle root and associated parameters.
    MerkleTree internal activeRoot;

    /// @dev The proposed Merkle root and associated parameters.
    MerkleTree internal proposedRoot;

    /// @dev Mapping of (user address) => (number of tokens claimed).
    mapping(address => uint256) internal claimedAmounts;

    /* ========== EVENTS ========== */

    /// @notice Emitted when a new Merkle root is proposed.
    event RootProposed(uint256 eventId, bytes32 merkleRoot, uint256 startTimestamp, uint256 endTimestamp, bytes ipfsCid);

    /// @notice Emitted when proposed Merkle root becomes active.
    event RootUpdated(uint256 eventId, bytes32 merkleRoot, uint256 startTimestamp, uint256 endTimestamp, bytes ipfsCid);

    /// @notice Emitted when a user claims rewards.
    event RewardsClaimed(uint256 eventId, address account, uint256 amount);

    /* ========== ERRORS ========== */

    error ProposedMerkleRootIsZero();
    error StartTimestampIsInThePast();
    error InvalidEndTimestamp();
    error ThisMerkleRootIsAlreadyProposed();
    error CannotUpdateRoot();
    error NoActiveMerkleRoot();
    error DistributionHasEnded();
    error DistributionStillActive();
    error InvalidMerkleProof();
    error ZeroClaim();
    error TokenAddressNotSet();
    error TokenAddressAlreadySet();

    function VERSION() external pure virtual returns (string memory) {
        return "1.0.2";
    }

    /* ====== UUPS AUTHORIZATION ====== */

    /// @notice upgrade the contract
    function _authorizeUpgrade(address) internal override onlyOwner {}

    /* ========== PREVENT INITIALIZATION FOR IMPLEMENTATION CONTRACTS ========== */

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /* ========== INITIALIZATION ========== */

    function initialize(address owner, IERC20 _token) external initializer {
        _transferOwnership(owner);
        __ReentrancyGuard_init();
        __Pausable_init();

        token = address(_token);
    }

    /* ========== VIEWS ========== */

    /**
     * @notice Get the actual Merkle root and associated parameters.
     *         In most cases it will be the active Merkle root.
     *         But if there is a proposed root and the start timestamp has passed, it will be the proposed root.
     *         Because it will be updated at the beginning of the next claimReward call and become active from that moment.
     *         So, user will actually obtain the rewards from the proposed root and have to provide amount and proof for it.
     *
     * @return  merkleRoot     The actual Merkle root.
     * @return  startTimestamp Timestamp when this Merkle root become active.
     * @return  endTimestamp   Timestamp when distribution stops. Zero means no end time.
     * @return  ipfsCid        An IPFS CID pointing to the Merkle tree data.
     */
    function getActualRoot() external view returns (bytes32 merkleRoot, uint256 startTimestamp, uint256 endTimestamp, bytes memory ipfsCid) {
        if (canUpdateRoot()) {
            return (proposedRoot.merkleRoot, proposedRoot.startTimestamp, proposedRoot.endTimestamp, proposedRoot.ipfsCid);
        }
        return (activeRoot.merkleRoot, activeRoot.startTimestamp, activeRoot.endTimestamp, activeRoot.ipfsCid);
    }

    /**
     * @notice Get the proposed Merkle root and associated parameters.
     *         When the proposed root become active, it will be zeroed.
     *         So, this function will return non-zero values only if the proposed root is pending.
     *
     * @return  merkleRoot     The proposed Merkle root.
     * @return  startTimestamp Timestamp when this Merkle root become active.
     * @return  endTimestamp   Timestamp when distribution stops. Zero means no end time.
     * @return  ipfsCid        An IPFS CID pointing to the Merkle tree data.
     */
    function getProposedRoot() external view returns (bytes32 merkleRoot, uint256 startTimestamp, uint256 endTimestamp, bytes memory ipfsCid) {
        return (proposedRoot.merkleRoot, proposedRoot.startTimestamp, proposedRoot.endTimestamp, proposedRoot.ipfsCid);
    }

    /**
     * @notice Get the tokens amount claimed so far by a given user.
     *
     * @param  _user  The address of the user.
     *
     * @return The amount tokens claimed so far by that user.
     */
    function getClaimed(address _user) external view returns (uint256) {
        return claimedAmounts[_user];
    }

    /**
     * @notice Returns true if there is a proposed root waiting to become active.
     *         This is the case if the proposed root  is not zero.
     */
    function hasPendingRoot() public view returns (bool) {
        return proposedRoot.merkleRoot != bytes32(0);
    }

    /**
     * @notice Returns true if there is a proposed root waiting to become active
     *         and the start time has passed.
     *
     * @return Boolean `true` if the active root can be updated to the proposed root, else `false`.
     */
    function canUpdateRoot() public view returns (bool) {
        return hasPendingRoot() && block.timestamp >= proposedRoot.startTimestamp;
    }

    /* ========== ROOT UPDATES ========== */

    /**
     * @notice Set the proposed root parameters.
     *         Locked for owner.
     *         Allows to update proposed root before startTimestamp passed.
     *         If startTimestamp passed, proposed root will be propogated to active root.
     *
     * @param  _merkleRoot     The Merkle root.
     * @param  _startTimestamp The timestamp when this Merkle root become active
     * @param  _endTimestamp   Timestamp when distribution stops. Zero means no end time.
     * @param  _ipfsCid        An IPFS CID pointing to the Merkle tree data.
     *
     *  Reverts if the proposed root is bytes32(0).
     *  Reverts if the proposed startTimestamp is in the past.
     *  Reverts if the proposed endTimestamp is less than or equal to the proposed startTimestamp.
     *  Reverts if the proposed root is already proposed.
     */
    function proposeRoot(
        bytes32 _merkleRoot,
        uint256 _startTimestamp,
        uint256 _endTimestamp,
        bytes calldata _ipfsCid
    ) external whenNotPaused nonReentrant onlyOwner {
        if (token == address(0)) revert TokenAddressNotSet();

        if (_merkleRoot == bytes32(0)) revert ProposedMerkleRootIsZero();

        if (_startTimestamp < block.timestamp) revert StartTimestampIsInThePast();

        if (_endTimestamp != 0 && _endTimestamp <= _startTimestamp) revert InvalidEndTimestamp();

        if (
            _merkleRoot == proposedRoot.merkleRoot &&
            _startTimestamp == proposedRoot.startTimestamp &&
            _endTimestamp == proposedRoot.endTimestamp &&
            keccak256(_ipfsCid) == keccak256(proposedRoot.ipfsCid)
        ) revert ThisMerkleRootIsAlreadyProposed();

        if (canUpdateRoot()) {
            updateRoot();
        }

        // Set the proposed root and the start timestamp when proposed root to become active.
        proposedRoot = MerkleTree({merkleRoot: _merkleRoot, startTimestamp: _startTimestamp, endTimestamp: _endTimestamp, ipfsCid: _ipfsCid});

        emit RootProposed(_getNextEventId(), _merkleRoot, _startTimestamp, _endTimestamp, _ipfsCid);
    }

    /**
     * @notice Set the active root parameters to the proposed root parameters.
     *         Non-reeentrant guard is disabled because this function is called from claimRewards.
     *
     *  Reverts if root updates are paused.
     *  Reverts if the proposed root is bytes32(0).
     *  Reverts if the waiting period for the proposed root has not elapsed.
     */
    function updateRoot() public whenNotPaused {
        if (!canUpdateRoot()) revert CannotUpdateRoot();

        activeRoot = proposedRoot;
        proposedRoot = MerkleTree({merkleRoot: bytes32(0), startTimestamp: 0, endTimestamp: 0, ipfsCid: ""});

        emit RootUpdated(_getNextEventId(), activeRoot.merkleRoot, activeRoot.startTimestamp, activeRoot.endTimestamp, activeRoot.ipfsCid);
    }

    /* ========== CLAIMING ========== */

    /**
     * @notice Claim the remaining unclaimed rewards for the sender.
     *
     * @param  _cumulativeAmount  The total all-time rewards this user has earned.
     * @param  _merkleProof       The Merkle proof for the user and cumulative amount.
     *
     * @return The number of rewards tokens claimed.
     *
     *  Reverts if no active Merkle root is set.
     *  Reverts if the provided Merkle proof is invalid.
     */
    function claimRewards(uint256 _cumulativeAmount, bytes32[] calldata _merkleProof) external whenNotPaused nonReentrant returns (uint256) {
        if (canUpdateRoot()) {
            updateRoot();
        }

        // Get the active Merkle root.
        if (activeRoot.merkleRoot == bytes32(0)) revert NoActiveMerkleRoot();

        if (activeRoot.endTimestamp != 0 && block.timestamp > activeRoot.endTimestamp) revert DistributionHasEnded();

        // Verify the Merkle proof.
        bytes32 leaf = keccak256(bytes.concat(keccak256(abi.encode(_msgSender(), _cumulativeAmount))));
        if (!MerkleProof.verify(_merkleProof, activeRoot.merkleRoot, leaf)) revert InvalidMerkleProof();

        // Get the claimable amount.
        //
        // Note: If this reverts, then there was an error in the Merkle tree, since the cumulative
        // amount for a given user should never decrease over time.
        uint256 claimableAmount = _cumulativeAmount - claimedAmounts[_msgSender()];

        if (claimableAmount > 0) {
            IERC20(token).safeTransfer(_msgSender(), claimableAmount);

            // Mark the user as having claimed the full amount.
            claimedAmounts[_msgSender()] = _cumulativeAmount;

            emit RewardsClaimed(_getNextEventId(), _msgSender(), claimableAmount);
        } else {
            revert ZeroClaim();
        }

        return claimableAmount;
    }

    /* ========== OWNER FUNCTIONS ========== */

    /// @notice Pause external functionality
    function pause() external onlyOwner {
        _pause();
    }

    /// @notice Unpause external functionality
    function unpause() external onlyOwner {
        _unpause();
    }

    /// @notice Withdraw the remaining tokens from the contract after the distribution has ended.
    function withdraw() external onlyOwner {
        if (activeRoot.endTimestamp == 0 || block.timestamp <= activeRoot.endTimestamp) revert DistributionStillActive();
        IERC20(token).safeTransfer(owner(), IERC20(token).balanceOf(address(this)));
    }

    /// @notice Set the token address
    function setTokenAddress(IERC20 _token) external onlyOwner {
        if (token != address(0)) revert TokenAddressAlreadySet();
        token = address(_token);
    }
}
