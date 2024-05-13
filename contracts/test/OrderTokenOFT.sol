// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import { OFT } from "@layerzerolabs/lz-evm-oapp-v2/contracts/oft/OFT.sol";

/// @title Main Orderly Token
/// @author Orderly Network
/// @notice OFT token with:
/// - support ERC20 standard
/// - transferrable between chains with OFT bridge by LayerZero
contract OrderTokenOFT is OFT {
    constructor(address _owner, uint256 maxSupply, address _layerZeroEndpoint) OFT("OrderToken", "ORDER", _layerZeroEndpoint, _owner) {
        _transferOwnership(_owner);
        _mint(_owner, maxSupply);
    }
}
