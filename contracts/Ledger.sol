// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/security/PausableUpgradeable.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";

import {EventIdCounter} from "./lib/EventIdCounter.sol";
import {LedgerMerkleDistributor} from "./LedgerMerkleDistributor.sol";

contract Ledger is
    Initializable,
    AccessControlUpgradeable,
    ReentrancyGuardUpgradeable, 
    PausableUpgradeable,
    EventIdCounter
{
    // Contract for Merkle distribution
    LedgerMerkleDistributor internal distributor;

    /* ========== INITIALIZER ========== */

    function initialize(address owner) external initializer {
        __AccessControl_init();
        __ReentrancyGuard_init();
        __Pausable_init();

        _setupRole(DEFAULT_ADMIN_ROLE, owner);

        distributor = new LedgerMerkleDistributor();
        distributor.initialize(address(this));
        distributor.grantRole(distributor.ROOT_UPDATER_ROLE(), address(this));
    }

    /* ========== PUBLIC FUNCTIONS ========== */

    /* ========== DISTRIBUTOR VIEW FUNCTIONS ========== */

    function getDistribution(uint32 _distributionId) external view returns (address token, bytes32 merkleRoot, uint256 startTimestamp, bytes memory ipfsCid) {
        return distributor.getDistribution(_distributionId);
    }

    function getProposedRoot(uint32 _distributionId) external view returns (bytes32 merkleRoot, uint256 startTimestamp, bytes memory ipfsCid) {
        return distributor.getProposedRoot(_distributionId);
    }

    function getClaimed(uint32 _distributionId, address _user) external view returns (uint256) {
        return distributor.getClaimed(_distributionId, _user);
    }

    function hasPendingRoot(uint32 _distributionId) external view returns (bool) {
        return distributor.hasPendingRoot(_distributionId);
    }

    function canUpdateRoot(uint32 _distributionId) external view returns (bool) {
        return distributor.canUpdateRoot(_distributionId);
    }

    /* ========== DISTRIBUTOR ROOT UPDATER FUNCTIONS ========== */

    function createDistribution(uint32 _distributionId, address _token, bytes32 _merkleRoot, uint256 _startTimestamp, bytes calldata _ipfsCid) external {
        distributor.createDistribution(_distributionId, _token, _merkleRoot, _startTimestamp, _ipfsCid);
    }

    function proposeRoot(uint32 _distributionId, bytes32 _merkleRoot, uint256 _startTimestamp, bytes calldata _ipfsCid) external {
        distributor.proposeRoot(_distributionId, _merkleRoot, _startTimestamp, _ipfsCid);
    }

    function updateRoot(uint32 _distributionId) external {
        distributor.updateRoot(_distributionId);
    }

    /* ========== DISTRIBUTOR CLAIM FUNCTIONS ========== */

    function claimRewards(uint32 _distributionId, address _user, uint32 _dstEid, uint256 _cumulativeAmount, bytes32[] calldata _merkleProof) external returns (uint256 claimableAmount) {

        claimableAmount = distributor.claimRewards(_distributionId, _user, _dstEid, _cumulativeAmount, _merkleProof);
        if (distributor.isDistributionRecordBased(_distributionId)) {
            // If the distribution is record-based, we need to stake the claimable amount
        }
        return claimableAmount;
    }

    /* ========== ADMIN FUNCTIONS ========== */

    function grantRootUpdaterRole(address account) external onlyRole(DEFAULT_ADMIN_ROLE) {
        distributor.grantRole(distributor.ROOT_UPDATER_ROLE(), account);
    }

    function revokeRootUpdaterRole(address account) external onlyRole(DEFAULT_ADMIN_ROLE) {
        distributor.revokeRole(distributor.ROOT_UPDATER_ROLE(), account);
    }
}
    