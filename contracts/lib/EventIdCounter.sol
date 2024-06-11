// SPDX-License-Identifier: MIT
pragma solidity 0.8.22;

abstract contract EventIdCounter {
    /// @notice Unique event id for event tracking
    uint256 public eventId;

    /// @notice Increment event id and return it
    function _getNextEventId() internal returns (uint256) {
        eventId++;
        return eventId;
    }

    // gap for upgradeable
    uint256[5] private __gap;
}
