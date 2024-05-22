// SPDX-License-Identifier: MIT
pragma solidity 0.8.22;

// oz imports
import { Initializable } from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import { OwnableUpgradeable } from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import { UUPSUpgradeable } from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

import { VaultOCCManager } from "./lib/OCCManager.sol";
import { OCCVaultMessage, LedgerToken } from "./lib/OCCTypes.sol";
import { LedgerPayloadTypes, PayloadDataType } from "./lib/LedgerTypes.sol";

/**
 * @title ProxyLedger for proxy requests to ledger
 * @dev proxy staking, claiming and other ledger operations from vault chains, like Ethereum, Arbitrum, etc.
 */
contract ProxyLedger is Initializable, VaultOCCManager, UUPSUpgradeable {

    /// @notice constructor to set the OCCAdapter address
    constructor() {
        _disableInitializers();
    }

    /* ====== initializer ====== */

    /// @notice initialize the contract
    function initialize(address _oft, address _owner) external initializer {
        orderTokenOft = _oft;
        ledgerAccessControlInit(_owner);
    }

    /* ====== upgradeable ====== */

    /// @notice upgrade the contract
    function _authorizeUpgrade(address) internal override onlyRole(DEFAULT_ADMIN_ROLE) {}

    /* ====== staking ====== */

    /**
     * @notice construct OCCVaultMessage for stake operation
     * @param amount the amount to stake
     * @param sender the sender of the stake
     * @param isEsOrder whether the stake is for esOrder
     */
    function buildStakeMessage(uint256 amount, address sender, bool isEsOrder) internal pure returns (OCCVaultMessage memory) {

        return OCCVaultMessage({
            srcChainId: 0,
            token: isEsOrder ? LedgerToken.ESORDER : LedgerToken.ORDER,
            tokenAmount: amount,
            sender: sender,
            payloadType: uint8(PayloadDataType.Stake),
            payload: bytes("")
        });
    }

    /**
     * @notice stake the amount to the ledger
     * @param amount the amount to stake
     * @param sender the sender of the stake
     * @param isEsOrder whether the stake is for esOrder
     */
    function stake(uint256 amount, address sender, bool isEsOrder) external payable {
        OCCVaultMessage memory message = buildStakeMessage(amount, sender, isEsOrder);
        vaultSendToLedger(message);
    }


    /**
     * @notice estimate the Layerzero fee for sending a message from vault to ledger chain in native token
     * @param amount the amount to stake
     * @param sender the sender of the stake
     * @param isEsOrder whether the stake is for esOrder
     */
    function qouteStake(uint256 amount, address sender, bool isEsOrder) external view returns (uint256) {
        OCCVaultMessage memory message = buildStakeMessage(amount, sender, isEsOrder);
        return estimateCCFeeFromVaultToLedger(message);
    }

    /* ====== claiming ====== */
    function buildClaimRewardMessage(uint32 distributionId, address user, uint256 cumulativeAmount, bytes32[] memory merkleProof, bool isEsOrder) internal pure returns (OCCVaultMessage memory) {
        return OCCVaultMessage({
            srcChainId: 0,
            token: isEsOrder ? LedgerToken.ESORDER : LedgerToken.ORDER,
            tokenAmount: 0,
            sender: user,
            payloadType: uint8(PayloadDataType.ClaimReward),
            payload: abi.encode(LedgerPayloadTypes.ClaimReward({
                distributionId: distributionId,
                cumulativeAmount: cumulativeAmount,
                merkleProof: merkleProof
            }))
        });
    }

    function claimReward(uint32 distributionId, address user, uint256 cumulativeAmount, bytes32[] memory merkleProof, bool isEsOrder) external {
        OCCVaultMessage memory message = buildClaimRewardMessage(distributionId, user, cumulativeAmount, merkleProof, isEsOrder);
        vaultSendToLedger(message);
    }

    function qouteClaimReward(uint32 distributionId, address user, uint256 cumulativeAmount, bytes32[] memory merkleProof, bool isEsOrder) external view returns (uint256) {
        OCCVaultMessage memory message = buildClaimRewardMessage(distributionId, user, cumulativeAmount, merkleProof, isEsOrder);
        return estimateCCFeeFromVaultToLedger(message);
    }

    /* ====== Create Order Unstake Request ====== */
    function buildEsOrderUnstakeAndVestMessage(uint256 amount, address user) internal pure returns (OCCVaultMessage memory) {
        return OCCVaultMessage({
            srcChainId: 0,
            token: LedgerToken.ESORDER,
            tokenAmount: amount,
            sender: user,
            payloadType: uint8(PayloadDataType.EsOrderUnstakeAndVest),
            payload: bytes("")
        });
    }


    /// @notice fallback to receive
    receive() external payable {}
}