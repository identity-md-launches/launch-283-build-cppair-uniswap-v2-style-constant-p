// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {MockERC20} from "./MockERC20.sol";

/// @notice ERC-20 that, when armed, calls back into a target during transfer/transferFrom.
///         It records whether the callback succeeded and the revert data if it did not,
///         then lets the transfer complete. Used to prove the pair's reentrancy guard fires.
contract ReentrantERC20 is MockERC20 {
    address public target;
    bytes public payload;
    bool public armed;

    bool public callbackFired;
    bool public callbackSucceeded;
    bytes public callbackRevertData;

    constructor() MockERC20("Reentrant Token", "REENT") {}

    function arm(address target_, bytes calldata payload_) external {
        target = target_;
        payload = payload_;
        armed = true;
    }

    function _transfer(address from, address to, uint256 value) internal override {
        super._transfer(from, to, value);
        if (armed) {
            armed = false;
            (bool ok, bytes memory ret) = target.call(payload);
            callbackFired = true;
            callbackSucceeded = ok;
            callbackRevertData = ret;
        }
    }
}
