// SPDX-License-Identifier: MIT
pragma solidity 0.8.22;

abstract contract ChainedEventIdCounter {
    /// @notice Mapping of srcChainId => event id
    mapping(uint256 => uint256) public srcChainIdToEventId;

    /// @notice Increment event id for source chain and return it
    function _getNextChainedEventId(uint256 srcChainId) internal returns (uint256) {
        srcChainIdToEventId[srcChainId]++;
        return srcChainIdToEventId[srcChainId];
    }

    // gap for upgradeable
    uint256[5] private __gap;
}
