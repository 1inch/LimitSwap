// SPDX-License-Identifier: MIT

pragma solidity ^0.7.6;

/// @title A helper contract with helper modifiers to allow access to original contract creator only
contract ImmutableOwner {
    address public immutable immutableOwner;

    modifier onlyImmutableOwner {
        require(msg.sender == immutableOwner, "IO: Access denied");
        _;
    }

    constructor(address _immutableOwner) {
        immutableOwner = _immutableOwner;
    }
}
