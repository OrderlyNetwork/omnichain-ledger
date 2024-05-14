// SPDX-License-Identifier: MIT
pragma solidity 0.8.22;

import {IERC20, SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/security/PausableUpgradeable.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";
import {MerkleProof} from "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";
import {IOFT} from "@layerzerolabs/lz-evm-oapp-v2/contracts/oft/interfaces/IOFT.sol";

import {LedgerToken} from "./lib/Common.sol";
import {LedgerTypes, PayloadDataType} from "./lib/LedgerTypes.sol";
import {ChainedEventIdCounter} from "./lib/ChainedEventIdCounter.sol";
import {Distribution, MerkleTree, MerkleDistributor} from "./lib/MerkleDistributor.sol";
import {OCCVaultMessage, OCCLedgerMessage, IOCCReceiver} from "orderly-omnichain-occ/contracts/OCCInterface.sol";
import {OCCManager} from "./lib/OCCManager.sol";
import {Staking} from "./lib/Staking.sol";

contract Ledger is Initializable, AccessControlUpgradeable, ReentrancyGuardUpgradeable, PausableUpgradeable, ChainedEventIdCounter, OCCManager, MerkleDistributor, Staking {
    using SafeERC20 for IERC20;

    /* ========== STATE VARIABLES ========== */
    address public orderToken;
    address public occAdaptor;

    /* ========== ERRORS ========== */
    error OrderTokenIsZero();
    error OCCAdaptorIsZero();

    /* ========== INITIALIZER ========== */

    function initialize(address _owner, address _occAdaptor, IOFT _orderTokenOft, uint256 _valorPerSecond, uint256 totalValorAmount) external initializer {
        if (address(_orderTokenOft) == address(0)) revert OrderTokenIsZero();
        if (_occAdaptor == address(0)) revert OCCAdaptorIsZero();

        if (_valorPerSecond > Staking.MAX_VALOR_PER_SECOND) revert ValorPerSecondExceedsMaxValue();

        __AccessControl_init();
        __ReentrancyGuard_init();
        __Pausable_init();

        _setupRole(DEFAULT_ADMIN_ROLE, _owner);

        orderToken = address(_orderTokenOft);
        occAdaptor = _occAdaptor;

        // Staking parameters
        valorPerSecond = _valorPerSecond;
        totalValorAmount = totalValorAmount;
        lastValorUpdateTimestamp = block.timestamp;
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

    function ledgerRecvFromVault(OCCVaultMessage calldata message) external override {
        if(message.payloadType == uint8(PayloadDataType.ClaimReward)) {
            LedgerTypes.ClaimReward memory claimRewardPayload = abi.decode(message.payload, (LedgerTypes.ClaimReward));
            claimRewards(claimRewardPayload.distributionId, claimRewardPayload.user, message.srcChainId, claimRewardPayload.cumulativeAmount, claimRewardPayload.merkleProof);
        }
    }

    function vaultRecvFromLedger(OCCLedgerMessage calldata message) external override {}

    /*
       ███    ███ ███████ ██████  ██   ██ ██      ███████     ██████  ██ ███████ ████████ ██████  ██ ██████  ██    ██ ████████  ██████  ██████  
       ████  ████ ██      ██   ██ ██  ██  ██      ██          ██   ██ ██ ██         ██    ██   ██ ██ ██   ██ ██    ██    ██    ██    ██ ██   ██ 
       ██ ████ ██ █████   ██████  █████   ██      █████       ██   ██ ██ ███████    ██    ██████  ██ ██████  ██    ██    ██    ██    ██ ██████  
       ██  ██  ██ ██      ██   ██ ██  ██  ██      ██          ██   ██ ██      ██    ██    ██   ██ ██ ██   ██ ██    ██    ██    ██    ██ ██   ██ 
       ██      ██ ███████ ██   ██ ██   ██ ███████ ███████     ██████  ██ ███████    ██    ██   ██ ██ ██████   ██████     ██     ██████  ██   ██
    */

    /* ========== MODIFIERS ========== */

    modifier onlyUpdater() {
        _checkRole(ROOT_UPDATER_ROLE);
        _;
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

        emit DistributionCreated(_getNextEventId(0), _distributionId, _token, _merkleRoot, _startTimestamp, _ipfsCid);
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
            _getNextEventId(0),
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

            emit RewardsClaimed(_getNextEventId(0), _distributionId, _user, claimableAmount, token, _srcChainId);
        }
    }

    /* ========== INTERNAL FUNCTIONS ========== */

    function _proposeRoot(
        uint32 _distributionId,
        bytes32 _merkleRoot,
        uint256 _startTimestamp,
        bytes calldata _ipfsCid
    ) internal {
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

        emit RootProposed(_getNextEventId(0), _distributionId, _merkleRoot, _startTimestamp, _ipfsCid);
    }
    
    // ███████ ████████  █████  ██   ██ ██ ███    ██  ██████  
    // ██         ██    ██   ██ ██  ██  ██ ████   ██ ██       
    // ███████    ██    ███████ █████   ██ ██ ██  ██ ██   ███ 
    //      ██    ██    ██   ██ ██  ██  ██ ██  ██ ██ ██    ██ 
    // ███████    ██    ██   ██ ██   ██ ██ ██   ████  ██████  

    /* ========== EXTERNAL FUNCTIONS ========== */

    /// @notice Stake tokens from LedgerToken list for a given user
    function stake(address _user, LedgerToken _token, uint256 _amount) external nonReentrant whenNotPaused {
        if (_amount == 0) revert AmountIsZero();

        _updateValorVars();
        _collectValor(_user);

        totalStakedAmount += _amount;
        userInfos[_user].balance[uint256(_token)] += _amount;
        userInfos[_user].valorDebt = _getUserTotalValorDebt(_user);

        emit Staked(_getNextEventId(0), _msgSender(), _amount, LedgerToken.ORDER);        
    }

    /// @notice Create unstaking request for `_amount` of tokens
    function createUnstakeRequest(address _user, LedgerToken _token, uint256 _amount) external nonReentrant whenNotPaused {
        if (_amount == 0) revert AmountIsZero();
        if (userInfos[_user].balance[uint256(_token)] == 0) revert UserHasZeroBalance();

        _updateValorVars();
        _collectValor(_user);

        userInfos[_user].balance[uint256(_token)] -= _amount;
        pendingUnstakes[_user].balanceOrder += _amount;

        pendingUnstakes[_user].unlockTimestamp = block.timestamp + unstakeLockPeriod;
        userInfos[_user].valorDebt = _getUserTotalValorDebt(_user);

        emit UnstakeRequested(_getNextEventId(0), _msgSender(), _amount, _token);
    }

    /// @notice Cancel unstaking request
    function cancelUnstakeRequest(address _user) external nonReentrant whenNotPaused {
        if (pendingUnstakes[_user].unlockTimestamp == 0) revert NoPendingUnstakeRequest();

        _updateValorVars();
        _collectValor(_user);

        uint256 pendingAmountOrder = pendingUnstakes[_user].balanceOrder;

        if (pendingAmountOrder > 0) {
            userInfos[_user].balance[uint256(LedgerToken.ORDER)] += pendingAmountOrder;
            pendingUnstakes[_user].balanceOrder = 0;
        }

        userInfos[_user].valorDebt = _getUserTotalValorDebt(_user);
        pendingUnstakes[_user].unlockTimestamp = 0;

        emit UnstakeCancelled(_getNextEventId(0), _msgSender(), pendingAmountOrder);
    }

    /// @notice Withdraw unstaked tokens
    function withdraw(address _user) external nonReentrant whenNotPaused {
        if (pendingUnstakes[_user].unlockTimestamp == 0) revert NoPendingUnstakeRequest();
        if (block.timestamp < pendingUnstakes[_user].unlockTimestamp) revert UnlockTimeNotPassedYet();

        if (pendingUnstakes[_user].balanceOrder > 0) {
            // orderToken.safeTransfer(_msgSender(), pendingUnstakes[_user].balanceOrder);
            emit Withdraw(_getNextEventId(0), _msgSender(), pendingUnstakes[_user].balanceOrder);
            pendingUnstakes[_user].balanceOrder = 0;
        }

        pendingUnstakes[_user].unlockTimestamp = 0;        
    }

    /// @notice Claim reward for sender
    function claimReward(address _user) external nonReentrant whenNotPaused {
        if (_getUserHasZeroBalance(_user)) revert UserHasZeroBalance();
        _updateValorVars();
        _collectValor(_user);
    }

    /// @notice Update reward variables to be up-to-date.
    function updateValorVars() external {
        _updateValorVars();
    }

    /* ========== PRIVATE FUNCTIONS ========== */

    /// @notice Update reward variables to be up-to-date.
    function _updateValorVars() private {
        if (block.timestamp <= lastValorUpdateTimestamp) {
            return;
        }

        accValorPerShareScaled = _getCurrentAccValorPreShare();
        lastValorUpdateTimestamp = block.timestamp;

        emit UpdateValorVars(_getNextEventId(0), lastValorUpdateTimestamp, accValorPerShareScaled);
    }

    /// @notice Claim pending reward for a caller
    function _collectValor(address _user) private {
        uint256 pendingReward = _getPendingValor(_user);

        if (pendingReward > 0) {
            userInfos[_user].valorDebt += pendingReward;
            collectedValor[_user] += pendingReward;
        }
    }
}
