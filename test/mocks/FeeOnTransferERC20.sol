// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {MockERC20} from "./MockERC20.sol";

/// @notice ERC-20 that burns 1% of every transfer, so the recipient receives less than requested.
contract FeeOnTransferERC20 is MockERC20 {
    constructor() MockERC20("Fee Token", "FEE") {}

    function _transfer(address from, address to, uint256 value) internal override {
        require(balanceOf[from] >= value, "BALANCE");
        uint256 fee = value / 100;
        balanceOf[from] -= value;
        balanceOf[to] += value - fee;
        totalSupply -= fee;
        emit Transfer(from, to, value - fee);
    }
}
