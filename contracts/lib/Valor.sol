// SPDX-License-Identifier: MIT
pragma solidity 0.8.22;

import {LedgerAccessControl} from "./LedgerAccessControl.sol";

/**
 * @title Valor contract
 * @author Orderly Network
 * @notice Manage the valor (a kind of internal token)
 *         User obtains valor by staking $ORDER and es$ORDER tokens
 *         Valor is emmitted over time, based on the valorPerSecond rate
 *         Valor can be redeemed for USDC in the Redemption contract
 *         Valor's rate to USDC is updated daily when TREASURE_UPDATER_ROLE calls dailyUsdcNetFeeRevenue
 *         Contract is source of truth for total totalValorAmount, totalUsdcInTreasure, valorToUsdcRateScaled
 */
abstract contract Valor is LedgerAccessControl {
    uint256 public constant VALOR_TO_USDC_RATE_PRECISION = 1e18;

    /// @notice The role, that is allowed to update USDC net fee revenue
    bytes32 public constant TREASURE_UPDATER_ROLE = keccak256("TREASURE_UPDATER_ROLE");

    /// @notice The amount of valor token, that will be emitted per second
    uint256 public valorPerSecond;

    /// @notice The maximum amount of valor token, that can be emitted
    uint256 public maximumValorEmission;

    /// @notice The total amount of valor token, that has been emitted
    uint256 public totalValorEmitted;

    /// @notice The total amount of valor token, that is currently in circulation
    uint256 public totalValorAmount;

    /// @notice The timestamp of the last update of the USDC net fee revenue
    uint256 public lastUsdcNetFeeRevenueUpdateTimestamp;

    /// @notice The total amount of USDC, that has been collected in the treasure
    uint256 public totalUsdcInTreasure;

    /// @notice The current rate of valor to USDC
    uint256 public valorToUsdcRateScaled;

    /// @notice The amount of valor token, that has been collected by the user
    mapping(address => uint256) public collectedValor;

    /* ========== EVENTS ========== */

    /// @notice Emmited, when the daily USDC net fee revenue has been updated
    event DailyUsdcNetFeeRevenueUpdated(
        uint256 indexed timestamp,
        uint256 usdcNetFeeRevenue,
        uint256 totalUsdcInTreasure,
        uint256 totalValorAmount,
        uint256 valorToUsdcRateScaled
    );

    /* ========== ERRORS ========== */
    error ValorPerSecondExceedsMaxValue();
    error TooEarlyUsdcNetFeeRevenueUpdate();

    /* ========== INITIALIZER ========== */

    function valorInit(address _owner, uint256 _valorPerSecond, uint256 _maximumValorEmission) internal onlyInitializing {
        _grantRole(TREASURE_UPDATER_ROLE, _owner);

        valorPerSecond = _valorPerSecond;
        maximumValorEmission = _maximumValorEmission;
    }

    /// @notice Allow the owner to update the valorPerSecond
    function setValorPerSecond(uint256 _valorPerSecond) external onlyRole(DEFAULT_ADMIN_ROLE) {
        valorPerSecond = _valorPerSecond;
    }

    /**
     * @notice CeFi updates the daily USDC net fee revenue
     *          Function reverts, if the function is called too early - less than 12 hours after the last update
     *          to prevent accidental double updates
     *          Function updates the totalUsdcInTreasure, valorToUsdcRateScaled
     */
    function dailyUsdcNetFeeRevenue(uint256 _usdcNetFeeRevenue) external onlyRole(TREASURE_UPDATER_ROLE) {
        if (block.timestamp < lastUsdcNetFeeRevenueUpdateTimestamp + 12 hours) revert TooEarlyUsdcNetFeeRevenueUpdate();

        lastUsdcNetFeeRevenueUpdateTimestamp = block.timestamp;
        totalUsdcInTreasure += _usdcNetFeeRevenue;
        valorToUsdcRateScaled = totalValorAmount == 0 ? 0 : (totalUsdcInTreasure * VALOR_TO_USDC_RATE_PRECISION) / totalValorAmount;
        emit DailyUsdcNetFeeRevenueUpdated(block.timestamp, _usdcNetFeeRevenue, totalUsdcInTreasure, totalValorAmount, valorToUsdcRateScaled);
    }
}
