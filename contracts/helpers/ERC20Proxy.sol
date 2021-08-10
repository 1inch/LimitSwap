// SPDX-License-Identifier: MIT

pragma solidity ^0.7.6;

import "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";

import "./ImmutableOwner.sol";


/* solhint-disable func-name-mixedcase */

abstract contract ERC20Proxy is ImmutableOwner {
    using SafeERC20 for IERC20;

    constructor() {
        require(ERC20Proxy.func_50BkM4K.selector == bytes4(uint32(IERC20.transferFrom.selector) + 1), "ERC20Proxy: bad selector");
    }

    // keccak256("func_50BkM4K(address,address,uint256,address)") = 0x23b872de
    function func_50BkM4K(address from, address to, uint256 amount, IERC20 token) external onlyImmutableOwner {
        token.safeTransferFrom(from, to, amount);
    }
}

/* solhint-enable func-name-mixedcase */
