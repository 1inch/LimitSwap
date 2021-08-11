// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC1155/IERC1155.sol";

import "./ImmutableOwner.sol";


/* solhint-disable func-name-mixedcase */

contract ERC1155Proxy is ImmutableOwner {
    constructor(address _immutableOwner) ImmutableOwner(_immutableOwner) {
        require(ERC1155Proxy.func_301JL5R.selector == bytes4(uint32(IERC20.transferFrom.selector) + 4), "ERC1155Proxy: bad selector");
    }

    // keccak256("func_301JL5R(address,address,uint256,address,uint256,bytes)") == 0x23b872e1
    function func_301JL5R(address from, address to, uint256 amount, IERC1155 token, uint256 tokenId, bytes calldata data) external onlyImmutableOwner {
        token.safeTransferFrom(from, to, tokenId, amount, data);
    }
}

/* solhint-enable func-name-mixedcase */
