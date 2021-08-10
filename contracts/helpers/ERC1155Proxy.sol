// SPDX-License-Identifier: MIT

pragma solidity ^0.7.6;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC1155/IERC1155.sol";

import "./ImmutableOwner.sol";


/* solhint-disable func-name-mixedcase */

abstract contract ERC1155Proxy is ImmutableOwner {
    constructor() {
        require(ERC1155Proxy.func_733NCGU.selector == bytes4(uint32(IERC20.transferFrom.selector) + 4), "ERC1155Proxy: bad selector");
    }

    // keccak256("func_733NCGU(address,address,uint256,address,uint256,bytes)") == 0x23b872e1
    function func_733NCGU(address from, address to, uint256 amount, IERC1155 token, uint256 tokenId, bytes calldata data) external onlyImmutableOwner {
        token.safeTransferFrom(from, to, tokenId, amount, data);
    }
}

/* solhint-enable func-name-mixedcase */
