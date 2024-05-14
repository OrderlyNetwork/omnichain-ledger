// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import {IERC20, SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/security/PausableUpgradeable.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";
import {MerkleProof} from "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";
import {IOFT, OFTReceipt, SendParam} from "@layerzerolabs/lz-evm-oapp-v2/contracts/oft/interfaces/IOFT.sol";
import {OptionsBuilder} from "@layerzerolabs/lz-evm-oapp-v2/contracts/oapp/libs/OptionsBuilder.sol";
import {MessagingFee, MessagingReceipt} from "@layerzerolabs/lz-evm-oapp-v2/contracts/oft/OFTCore.sol";

import {LedgerToken} from "./lib/Common.sol";
import {ChainedEventIdCounter} from "./lib/ChainedEventIdCounter.sol";
import {Distribution, MerkleTree, MerkleDistributor} from "./lib/MerkleDistributor.sol";
import {Staking} from "./lib/Staking.sol";

contract Ledger is Initializable, AccessControlUpgradeable, ReentrancyGuardUpgradeable, PausableUpgradeable, ChainedEventIdCounter, MerkleDistributor, Staking {
    using SafeERC20 for IERC20;
    /* ========== STATE VARIABLES ========== */
    /// @dev The address of the Order OFT token.
    address public orderToken;

    /* ========== ERRORS ========== */
    error OrderTokenIsZero();

    /* ========== INITIALIZER ========== */

    function initialize(address _owner, IOFT _orderTokenOft, uint256 _rewardPerSecond) external initializer {
        if (address(_orderTokenOft) == address(0)) revert OrderTokenIsZero();
        if (_rewardPerSecond > Staking.MAX_REWARD_PER_SECOND) revert RewardPerSecondExceedsMaxValue();

        __AccessControl_init();
        __ReentrancyGuard_init();
        __Pausable_init();

        _setupRole(DEFAULT_ADMIN_ROLE, _owner);

        orderToken = address(_orderTokenOft);

        // Staking parameters
        // rewardPerSecond = _rewardPerSecond;
        // lastRewardUpdateTimestamp = block.timestamp;
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
    function claimRewards(
        uint32 _distributionId,
        address _user,
        uint32 _dstEid,
        uint256 _cumulativeAmount,
        bytes32[] calldata _merkleProof
    ) external whenNotPaused nonReentrant returns (uint256 claimableAmount) {
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
                SendParam memory sendParam = SendParam(
                    _dstEid,
                    _addressToBytes32(_user),
                    claimableAmount,
                    claimableAmount,
                    OptionsBuilder.addExecutorLzReceiveOption(OptionsBuilder.newOptions(), 200000, 0),
                    "",
                    ""
                );
                IOFT oftRewardToken = IOFT(orderToken);
                MessagingFee memory fee = oftRewardToken.quoteSend(sendParam, false);

                (MessagingReceipt memory msgReceipt, OFTReceipt memory oftReceipt) = oftRewardToken.send{value: fee.nativeFee}(
                    sendParam,
                    fee,
                    payable(address(this))
                );
                if (oftReceipt.amountSentLD != claimableAmount || msgReceipt.fee.lzTokenFee != 0) {
                    revert OFTTransferFailed();
                }
            } else {
                // TODO: implement staking!
                // Record based distribution. Stake the claimable amount.
                return claimableAmount;
            }

            emit RewardsClaimed(_getNextEventId(0), _distributionId, _user, claimableAmount, token, _dstEid);
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

    /* ========== REGULAR USER CALL FUNCTIONS ========== */

    /// @notice Stake tokens from LedgerToken list for a given user
    function stake(LedgerToken _token, uint256 _amount) external nonReentrant whenNotPaused {
        _stake(userInfos[_msgSender()], _amount, _token);
    }

    /// @notice Create unstaking request for `_amount` of tokens
    function createUnstakeRequest(LedgerToken _token, uint256 _amount) external nonReentrant whenNotPaused {
        _unstake(userInfos[_msgSender()], pendingUnstakes[_msgSender()], _amount, _token);
    }

    /// @notice Cancel unstaking request
    function cancelUnstakeRequest() external nonReentrant whenNotPaused {
        _cancelUnstake(userInfos[_msgSender()], pendingUnstakes[_msgSender()]);
    }

    /// @notice Withdraw unstaked tokens
    function withdraw() external nonReentrant whenNotPaused {
        _withdraw(pendingUnstakes[_msgSender()]);
    }

    /// @notice Claim reward for sender
    function claimReward() external nonReentrant whenNotPaused {
        UserInfo storage userInfo = userInfos[_msgSender()];
        if (_getUserHasZeroBalance(userInfo)) revert UserHasZeroBalance();
        _updateRewardVars();
        _claimReward(userInfo);
    }

    /// @notice Update reward variables to be up-to-date.
    function updateRewardVars() external {
        _updateRewardVars();
    }

    /// @notice Update reward variables to be up-to-date.
    function _updateRewardVars() private {
        if (block.timestamp <= lastRewardUpdateTimestamp) {
            return;
        }

        accRewardPerShareScaled = _getCurrentAccRewardPreShare();
        lastRewardUpdateTimestamp = block.timestamp;

        emit UpdateRewardVars(_getNextEventId(0), lastRewardUpdateTimestamp, accRewardPerShareScaled);
    }

    /* ========== PRIVATE FUNCTIONS ========== */

    /// @notice Claim pending reward for a caller
    function _claimReward(UserInfo storage _userInfo, address rewardReceiver) private {
        uint256 pendingReward = _getPendingReward(_userInfo);

        if (pendingReward > 0) {
            _userInfo.rewardDebt += pendingReward;
            collectedRewards[_user] += pendingReward;
    }


    /// @notice Stake ORDER or esORDER tokens
    /// @param _userInfo The user info to update
    /// @param _amount The amount of tokens to stake
    /// @param _token The token to stake
    function _stake(UserInfo storage _userInfo, address rewardReceiver, uint256 _amount, LedgerToken _token) private {
        if (_amount == 0) revert AmountIsZero();

        _updateRewardVars();
        _claimReward(_userInfo);

        IERC20 tokenContract = _tokenContract(_token);
        tokenContract.safeTransferFrom(_msgSender(), address(this), _amount);

        _userInfo.balance[uint256(_token)] += _amount;
        _userInfo.rewardDebt = _getUserTotalRewardDebt(_userInfo);

        // TODO: tokem!!!
        emit Staked(_getNextEventId(0), _msgSender(), _amount, LedgerToken.ORDER);
    }

    /// @notice Create or update a pending unstake request
    /// Unstaking has a 7 day unbinding period (to de-incentivize unstaking).
    /// Unlock timestamp update from current timestamp + 7 days
    /// @param _userInfo The user info to update
    /// @param _amount The amount of tokens to unstake
    /// @param _token The token to unstake
    function _unstake(
        UserInfo storage _userInfo,
        PendingUnstake storage _userPendingUnstake,
        uint256 _amount,
        LedgerToken _token
    ) private {
        if (_amount == 0) revert AmountIsZero();
        if (_userInfo.balance[uint256(_token)] == 0) revert UserHasZeroBalance();

        _updateRewardVars();
        _claimReward(_userInfo);

        _userInfo.balance[uint256(_token)] -= _amount;
        _userPendingUnstake.balanceOrder += _amount;

        _userPendingUnstake.unlockTimestamp = block.timestamp + unstakeLockPeriod;
        _userInfo.rewardDebt = _getUserTotalRewardDebt(_userInfo);

        emit UnstakeRequested(_getNextEventId(0), _msgSender(), _amount, _token);
    }

    /// @notice Cancel unstaking request
    function _cancelUnstake(
        UserInfo storage _userInfo,
        PendingUnstake storage _userPendingUnstake
    ) private {
        if (_userPendingUnstake.unlockTimestamp == 0) revert NoPendingUnstakeRequest();

        _updateRewardVars();
        _claimReward(_userInfo);

        uint256 pendingAmountOrder = _userPendingUnstake.balanceOrder;

        if (pendingAmountOrder > 0) {
            _userInfo.balance[uint256(LedgerToken.ORDER)] += pendingAmountOrder;
            _userPendingUnstake.balanceOrder = 0;
        }

        _userInfo.rewardDebt = _getUserTotalRewardDebt(_userInfo);
        _userPendingUnstake.unlockTimestamp = 0;

        emit UnstakeCancelled(_getNextEventId(0), _msgSender(), pendingAmountOrder);
    }

    /// @notice Withdraw unstaked tokens
    function _withdraw(PendingUnstake storage _userPendingUnstake) private {
        if (_userPendingUnstake.unlockTimestamp == 0) revert NoPendingUnstakeRequest();
        if (block.timestamp < _userPendingUnstake.unlockTimestamp) revert UnlockTimeNotPassedYet();

        if (_userPendingUnstake.balanceOrder > 0) {
            // orderToken.safeTransfer(_msgSender(), _userPendingUnstake.balanceOrder);
            emit Withdraw(_getNextEventId(0), _msgSender(), _userPendingUnstake.balanceOrder);
            _userPendingUnstake.balanceOrder = 0;
        }

        _userPendingUnstake.unlockTimestamp = 0;
    }


    function _tokenContract(LedgerToken _token) private view returns (IERC20) {
        if (_token == LedgerToken.ORDER) {
            return IERC20(orderToken);
        } else {
            revert Unsupportedtoken();
        }
    }

}
