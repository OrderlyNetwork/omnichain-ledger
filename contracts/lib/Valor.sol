// SPDX-License-Identifier: MIT
pragma solidity 0.8.22;

/// @title Valor contract
/// @notice This contract is used to manage the valor
abstract contract Valor {
    uint256 internal constant MAX_VALOR_PER_SECOND = 1 ether;

    /// @notice The amount of valor token, that will be emitted per second
    uint256 public valorPerSecond;

    /// @notice The maximum amount of valor token, that can be emitted
    uint256 public maximumValorEmission;

    /// @notice The total amount of valor token, that has been emitted
    uint256 public totalValorEmitted;

    /// @notice The total amount of valor token, that is currently in circulation
    uint256 public totalValorAmount;

    /// @notice The total amount of USDC, that has been collected in the treasure
    uint256 public totalUsdcInTreasure;

    /// @notice The current rate of valor to USDC
    uint256 public valorToUsdcRate;

    /// @notice The amount of valor token, that has been collected by the user
    mapping(address => uint256) public collectedValor;

    /* ========== ERRORS ========== */
    error ValorPerSecondExceedsMaxValue();

    /* ========== INITIALIZER ========== */

    function valorInit(uint256 _valorPerSecond, uint256 _maximumValorEmission) internal {
        if (_valorPerSecond > MAX_VALOR_PER_SECOND) revert ValorPerSecondExceedsMaxValue();

        valorPerSecond = _valorPerSecond;
        maximumValorEmission = _maximumValorEmission;
    }

    function setTotalUsdcInTreasure(uint256 _totalUsdcInTreasure) internal {
        totalUsdcInTreasure = _totalUsdcInTreasure;
        valorToUsdcRate = totalValorAmount == 0 ? 0 : totalUsdcInTreasure / totalValorAmount;
    }
}
