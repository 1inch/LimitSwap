// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import "./ImmutableOwner.sol";


/* solhint-disable func-name-mixedcase */

contract ERC20Proxy is ImmutableOwner {
    using SafeERC20 for IERC20;

    constructor(address _immutableOwner) ImmutableOwner(_immutableOwner) {
        require(ERC20Proxy.func_602HzuS.selector == IERC20.transferFrom.selector, "ERC20Proxy: bad selector");
    }

    // keccak256("func_602HzuS(address,address,uint256,address)") = 0x23b872dd
    function func_602HzuS(address from, address to, uint256 amount, IERC20 token) external onlyImmutableOwner {
        token.safeTransferFrom(from, to, amount);
    }
}

/* solhint-enable func-name-mixedcase */
