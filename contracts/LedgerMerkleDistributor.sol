// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {MerkleProof} from "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/security/PausableUpgradeable.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";
import {IOFT, OFTReceipt, SendParam} from "@layerzerolabs/lz-evm-oapp-v2/contracts/oft/interfaces/IOFT.sol";
import {OptionsBuilder} from "@layerzerolabs/lz-evm-oapp-v2/contracts/oapp/libs/OptionsBuilder.sol";
import {MessagingFee, MessagingReceipt } from "@layerzerolabs/lz-evm-oapp-v2/contracts/oft/OFTCore.sol";

import {EventIdCounter} from "./lib/EventIdCounter.sol";

/**
 * @title  Orderly LedgerMerkleDistributor
 * @author Orderly Network
 * @notice This contract aimed for the distribution of
 *         - Trading rewards
 *         - Market Maker rewards
 *         - Airdrops for early orderly users, orderly NFT holders, target users
 *
 *         Distribution based on Merkle distribution mechanism similar to Uniswap's MerkleDistributor.
 *         Contract can distribute OFT tokens and also allows to claim rewards that are just records represented by IWallet interface.
 *         Contract allows multiple distributions for one token. Each distribution has its distributionId and Merkle root.
 *         That's why most of the functions in this contract take a distributionId as an argument.
 *
 *         The Merkle root fot each distribution can be updated by the address, granted with ROOT_UPDATER_ROLE.
 *         It allows to distribute continuously growing rewards.
 *         For that purpose Merkle tree contains leafs with cumulative non-decreasing reward amounts.
 *
 *         Distributed tokens should be transferred to the contract before the distribution starts.
 *
 *         Contract is pausible by DEFAULT_ADMIN_ROLE. It allows to pause claiming rewards and updates to the Merkle roots.
 *         The contract is upgradeable to allow for future changes to the rewards distribution mechanism.
 */
contract LedgerMerkleDistributor is
    Initializable,
    AccessControlUpgradeable,
    ReentrancyGuardUpgradeable, 
    PausableUpgradeable,
    EventIdCounter
{
    /* ========== TYPES ========== */

    /// @dev The parameters related to a certain Merkle tree.
    /// @dev Each token have separate Merkle root.
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

    /* ========== ROLES ========== */

    /// @dev May propose new/updated Merkle roots for tokens.
    bytes32 public constant ROOT_UPDATER_ROLE = keccak256("ROOT_UPDATER_ROLE");

    /* ========== STATE VARIABLES ========== */

    /// @dev The active Distributions and associated parameters. Mapped on distribution id.
    mapping(uint32 => Distribution) internal activeDistributions;

    /// @dev The proposed Merkle root and associated parameters. Mapped on distribution id.
    mapping(uint32 => MerkleTree) internal proposedRoots;

    /// @dev Mapping of (distribution id) => (user address) => (claimed amount).
    mapping(uint32 => mapping(address => uint256)) internal claimedAmounts;

    /* ========== MODIFIERS ========== */

    modifier onlyUpdater() {
        _checkRole(ROOT_UPDATER_ROLE);
        _;
    }

    /* ========== EVENTS ========== */

    /// @notice Emitted when a new distribution is created.
    event DistributionCreated(uint256 eventId, uint32 distributionId, address token, bytes32 merkleRoot, uint256 startTimestamp, bytes ipfsCid);

    /// @notice Emitted when a new Merkle root is proposed.
    event RootProposed(uint256 eventId, uint32 distributionId, bytes32 merkleRoot, uint256 startTimestamp, bytes ipfsCid);

    /// @notice Emitted when proposed Merkle root becomes active.
    event RootUpdated(uint256 eventId, uint32 distributionId, bytes32 merkleRoot, uint256 startTimestamp, bytes ipfsCid);

    /// @notice Emitted when a user (or behalf of user) claims rewards.
    event RewardsClaimed(uint256 eventId, uint32 distributionId, address account, uint256 amount, address token, uint32 dstEid);

    /* ========== ERRORS ========== */

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

    /* ========== INITIALIZATION ========== */

    function initialize(address owner) external initializer {
        __AccessControl_init();
        __ReentrancyGuard_init();
        __Pausable_init();

        _setupRole(DEFAULT_ADMIN_ROLE, owner);
    }

    /* ========== VIEWS ========== */

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
    function getDistribution(uint32 _distributionId) external view returns (address token, bytes32 merkleRoot, uint256 startTimestamp, bytes memory ipfsCid) {
        if (canUpdateRoot(_distributionId)) {
            return
                (activeDistributions[_distributionId].token,
                 proposedRoots[_distributionId].merkleRoot,
                 proposedRoots[_distributionId].startTimestamp,
                 proposedRoots[_distributionId].ipfsCid);
        }
        return (activeDistributions[_distributionId].token,
                activeDistributions[_distributionId].merkleTree.merkleRoot,
                activeDistributions[_distributionId].merkleTree.startTimestamp,
                activeDistributions[_distributionId].merkleTree.ipfsCid);
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
    function getProposedRoot(uint32 _distributionId)
        external
        view
        returns (bytes32 merkleRoot, uint256 startTimestamp, bytes memory ipfsCid)
    {
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
    function createDistribution(uint32 _distributionId, address _token, bytes32 _merkleRoot, uint256 _startTimestamp, bytes calldata _ipfsCid)
        external
        nonReentrant
        onlyUpdater
    {
        if (activeDistributions[_distributionId].token != address(0)) revert DistributionAlreadyExists();

        if (_token == address(0)) revert TokenIsZero();

        activeDistributions[_distributionId] = Distribution({token: _token, merkleTree: MerkleTree({merkleRoot: "", startTimestamp: 0, ipfsCid: ""})});

        proposeRoot(_distributionId, _merkleRoot, _startTimestamp, _ipfsCid);

        emit DistributionCreated(_getNextEventId(), _distributionId, _token, _merkleRoot, _startTimestamp, _ipfsCid);
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
    function proposeRoot(uint32 _distributionId, bytes32 _merkleRoot, uint256 _startTimestamp, bytes calldata _ipfsCid)
        public
        nonReentrant
        onlyUpdater
    {
        if (activeDistributions[_distributionId].token == address(0)) revert DistributionNotFound();

        if (_merkleRoot == bytes32(0)) revert ProposedMerkleRootIsZero();

        if (_startTimestamp < block.timestamp) revert StartTimestampIsInThePast();

        if (
            _merkleRoot == proposedRoots[_distributionId].merkleRoot && _startTimestamp == proposedRoots[_distributionId].startTimestamp
                && keccak256(_ipfsCid) == keccak256(proposedRoots[_distributionId].ipfsCid)
        ) revert ThisMerkleRootIsAlreadyProposed();

        if (canUpdateRoot(_distributionId)) {
            updateRoot(_distributionId);
        }

        // Set the proposed root and the start timestamp when proposed root to become active.
        proposedRoots[_distributionId] =
            MerkleTree({merkleRoot: _merkleRoot, startTimestamp: _startTimestamp, ipfsCid: _ipfsCid});

        emit RootProposed(_getNextEventId(), _distributionId, _merkleRoot, _startTimestamp, _ipfsCid);
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
            _getNextEventId(),
            _distributionId,
            activeDistributions[_distributionId].merkleTree.merkleRoot,
            activeDistributions[_distributionId].merkleTree.startTimestamp,
            activeDistributions[_distributionId].merkleTree.ipfsCid
        );
    }

    /* ========== CLAIMING ========== */

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
     * @param  _dstEid          Destination LZ endpoint ID.
     * @param  _cumulativeAmount The total all-time rewards this user has earned.
     * @param  _merkleProof      The Merkle proof for the user and cumulative amount.
     *
     * @return claimableAmount  The number of rewards tokens claimed.
     *
     *  Reverts if the distribution is not OFT token based.
     *  Reverts if no active Merkle root is set for the _distributionId.
     *  Reverts if the provided Merkle proof is invalid.
     */
    function claimRewards(uint32 _distributionId, address _user, uint32 _dstEid, uint256 _cumulativeAmount, bytes32[] calldata _merkleProof)
        external
        whenNotPaused
        nonReentrant
        returns (uint256 claimableAmount)
    {
        if (canUpdateRoot(_distributionId)) {
            updateRoot(_distributionId);
        }

        address token = activeDistributions[_distributionId].token;

        // Distribution should be created (has not null token address).
        if (token == address(0)) revert DistributionNotFound();

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
            
            // If distribution is token based, send the claimable amount to the user on the destination chain.
            // Record based distributions just return the claimable amount.
            if (token != address(1))
            {
                SendParam memory sendParam = SendParam(
                    _dstEid,
                    addressToBytes32(_user),
                    claimableAmount,
                    claimableAmount,
                    OptionsBuilder.addExecutorLzReceiveOption(OptionsBuilder.newOptions(), 200000, 0),
                    "",
                    ""
                );
                IOFT oftRewardToken = IOFT(token);
                MessagingFee memory fee = oftRewardToken.quoteSend(sendParam, false);

                (MessagingReceipt memory msgReceipt, OFTReceipt memory oftReceipt) = oftRewardToken.send{ value: fee.nativeFee }(sendParam, fee, payable(address(this)));
                if (oftReceipt.amountSentLD != claimableAmount || msgReceipt.fee.lzTokenFee != 0) {
                    revert OFTTransferFailed();
                }
            }

            emit RewardsClaimed(_getNextEventId(), _distributionId, _user, claimableAmount, token, _dstEid);
        }
    }


    /* ========== ADMIN FUNCTIONS ========== */

    /// @notice Pause external functionality
    function pause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _pause();
    }

    /// @notice Unpause external functionality
    function unpause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _unpause();
    }

    /* ========== INTERNAL FUNCTIONS ========== */

    /**
     * @dev Converts an address to bytes32.
     * @param _addr The address to convert.
     * @return The bytes32 representation of the address.
     */
    function addressToBytes32(address _addr) internal pure returns (bytes32) {
        return bytes32(uint256(uint160(_addr)));
    }
}
