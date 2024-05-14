// SPDX-License-Identifier: MIT
pragma solidity 0.8.22;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @title Main Orderly Token
/// @author Orderly Network
/// @notice ERC20 token:
contract OrderToken is ERC20 {
    constructor(uint256 totalSupply) ERC20("Order", "ORDER") {
        _mint(msg.sender, totalSupply);
    }
}
