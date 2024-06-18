// SPDX-License-Identifier: MIT
pragma solidity 0.8.22;

import {LedgerAccessControl} from "./LedgerAccessControl.sol";
import {LedgerSignedTypes} from "./LedgerTypes.sol";
import {Signature} from "./Signature.sol";

/**
 * @title Valor contract
 * @author Orderly Network
 * @notice Manage the valor (a kind of internal token)
 *         User obtains valor by staking $ORDER and es$ORDER tokens
 *         Valor is emmitted over time, based on the valorPerSecond rate
 *         Valor emission started from the valorEmissionStartTimestamp
 *         Owner can set valorEmissionStartTimestamp if it is not passed yet
 *         Valor emission is limited by maximumValorEmission
 *         Valor can be redeemed for USDC in the Redemption contract
 *         Valor's rate to USDC is updated daily when TREASURE_UPDATER_ROLE calls dailyUsdcNetFeeRevenue
 *         Contract is source of truth for totalValorAmount(getTotalValorAmount()), totalUsdcInTreasure, valorToUsdcRateScaled
 */
abstract contract Valor is LedgerAccessControl {
    uint256 public constant VALOR_TO_USDC_RATE_PRECISION = 1e27;

    /// @notice The role, that is allowed to update USDC net fee revenue
    bytes32 public constant TREASURE_UPDATER_ROLE = keccak256("TREASURE_UPDATER_ROLE");

    /// @notice The address, that signed the USDC revenue updates
    address public usdcUpdaterAddress;

    /// @notice The amount of valor token, that has been collected by the user
    mapping(address => uint256) public collectedValor;

    /// @notice The amount of valor token, that will be emitted per second
    uint256 public valorPerSecond;

    /// @notice The maximum amount of valor token, that can be emitted
    uint256 public maximumValorEmission;

    /// @notice The total amount of valor token, that has been emitted
    uint256 internal totalValorEmitted;

    /// @notice The total amount of valor token, that has been redeemed
    uint256 public totalValorRedeemed;

    /// @notice The total amount of USDC, that has been collected in the treasure
    uint256 public totalUsdcInTreasure;

    /// @notice The current rate of valor to USDC
    uint256 public valorToUsdcRateScaled;

    /// @notice Valor emission starts at this time
    uint256 public valorEmissionStartTimestamp;

    /// @notice The last time that the valor variables were updated
    uint256 public lastValorUpdateTimestamp;

    /// @notice The timestamp of the last update of the USDC net fee revenue
    uint256 public lastUsdcNetFeeRevenueUpdateTimestamp;

    /* ========== EVENTS ========== */

    /// @notice Emmited, when the daily USDC net fee revenue has been updated
    event DailyUsdcNetFeeRevenueUpdated(
        uint256 indexed timestamp,
        uint256 usdcNetFeeRevenue,
        uint256 totalUsdcInTreasure,
        uint256 totalValorAmount,
        uint256 valorToUsdcRateScaled
    );

    event TotalUsdcInTreasureUpdated(uint256 totalUsdcInTreasure, uint256 totalValorAmount, uint256 valorToUsdcRateScaled);

    /* ========== ERRORS ========== */
    error TooEarlyUsdcNetFeeRevenueUpdate();
    error ValorEmissionAlreadyStarted();
    error ValorEmissionCouldNotStartInThePast();

    /* ========== INITIALIZER ========== */

    function valorInit(address _owner, uint256 _valorPerSecond, uint256 _maximumValorEmission) internal onlyInitializing {
        _grantRole(TREASURE_UPDATER_ROLE, _owner);

        valorPerSecond = _valorPerSecond;
        maximumValorEmission = _maximumValorEmission;
        valorEmissionStartTimestamp = block.timestamp + 1 days;
    }

    /* ========== VIEWS ========== */

    /// @notice Get the total amount of Valor that should be emitted to the moment
    function getTotalValorEmitted() public view returns (uint256) {
        return totalValorEmitted + _getValorPendingEmission();
    }

    /// @notice Get the total amount of Valor that is currently in circulation
    function getTotalValorAmount() public view returns (uint256) {
        return getTotalValorEmitted() - totalValorRedeemed;
    }

    /* ========== ADMIN FUNCTIONS ========== */

    /// @notice Owner can set address, that signed the USDC revenue updates
    function setUsdcUpdaterAddress(address _usdcUpdaterAddress) external whenNotPaused onlyRole(DEFAULT_ADMIN_ROLE) {
        usdcUpdaterAddress = _usdcUpdaterAddress;
    }

    /// @notice Owner can set the valor emission start timestamp if it is not passed yet
    function setValorEmissionStartTimestamp(uint256 _valorEmissionStartTimestamp) external whenNotPaused onlyRole(DEFAULT_ADMIN_ROLE) {
        if (block.timestamp > valorEmissionStartTimestamp) revert ValorEmissionAlreadyStarted();
        if (block.timestamp > _valorEmissionStartTimestamp) revert ValorEmissionCouldNotStartInThePast();
        valorEmissionStartTimestamp = _valorEmissionStartTimestamp;
    }

    /**
     * @notice Set the totalUsdcInTreasure. Restricted to DEFAULT_ADMIN_ROLE
     *          Function updates the totalUsdcInTreasure, valorToUsdcRateScaled
     */
    function setTotalUsdcInTreasure(uint256 _totalUsdcInTreasure) external whenNotPaused onlyRole(DEFAULT_ADMIN_ROLE) {
        totalUsdcInTreasure = _totalUsdcInTreasure;
        _updateValorToUsdcRateScaled();
        emit TotalUsdcInTreasureUpdated(totalUsdcInTreasure, getTotalValorAmount(), valorToUsdcRateScaled);
    }

    /* ========== INTERNAL FUNCTIONS ========== */

    function _doValorEmission() public whenNotPaused returns (uint256 valorEmitted) {
        valorEmitted = _getValorPendingEmission();
        if (valorEmitted > 0) {
            totalValorEmitted += valorEmitted;
            lastValorUpdateTimestamp = block.timestamp;
        }
    }

    /// @notice Get the amount of valor, that should be emitted to the moment since the last update
    function _getValorPendingEmission() internal view returns (uint256 valorPendingEmission) {
        if (block.timestamp <= valorEmissionStartTimestamp || block.timestamp <= lastValorUpdateTimestamp) return 0;

        uint256 secondsElapsed = block.timestamp - lastValorUpdateTimestamp;
        valorPendingEmission = secondsElapsed * valorPerSecond;
        if (totalValorEmitted + valorPendingEmission > maximumValorEmission) {
            valorPendingEmission = maximumValorEmission - totalValorEmitted;
        }
    }

    /**
     * @notice CeFi updates the daily USDC net fee revenue
     *          Function reverts, if the function is called too early - less than 12 hours after the last update
     *          to prevent accidental double updates
     *          Function updates the totalUsdcInTreasure, valorToUsdcRateScaled
     *          Supposed to be called from the Ledger contract
     */
    function _dailyUsdcNetFeeRevenue(LedgerSignedTypes.UintValueData calldata data) internal whenNotPaused onlyRole(TREASURE_UPDATER_ROLE) {
        if (block.timestamp < lastUsdcNetFeeRevenueUpdateTimestamp + 12 hours) revert TooEarlyUsdcNetFeeRevenueUpdate();

        Signature.verifyUintValueSignature(data, usdcUpdaterAddress);

        lastUsdcNetFeeRevenueUpdateTimestamp = block.timestamp;
        totalUsdcInTreasure += data.value;
        _updateValorToUsdcRateScaled();
        emit DailyUsdcNetFeeRevenueUpdated(data.timestamp, data.value, totalUsdcInTreasure, getTotalValorAmount(), valorToUsdcRateScaled);
    }

    function _updateValorToUsdcRateScaled() internal {
        uint256 totalValorAmount = getTotalValorAmount();
        valorToUsdcRateScaled = totalValorAmount == 0 ? 0 : (totalUsdcInTreasure * VALOR_TO_USDC_RATE_PRECISION) / totalValorAmount;
    }

    // gap for upgradeable
    uint256[50] private __gap;
}
