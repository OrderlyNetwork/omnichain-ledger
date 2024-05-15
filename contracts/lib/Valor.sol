// SPDX-License-Identifier: MIT
pragma solidity 0.8.22;

abstract contract Valor {
    /// @notice The amount of valor token, that will be emitted per second
    uint256 public valorPerSecond;

    uint256 public maximumValorEmission;

    uint256 public totalValorEmitted;

    uint256 public totalValorAmount;
}
