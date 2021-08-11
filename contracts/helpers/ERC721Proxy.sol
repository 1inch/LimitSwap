// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721.sol";

import "./ImmutableOwner.sol";


/* solhint-disable func-name-mixedcase */

contract ERC721Proxy is ImmutableOwner {
    constructor(address _immutableOwner) ImmutableOwner(_immutableOwner) {
        require(ERC721Proxy.func_602HzuS.selector == IERC20.transferFrom.selector, "ERC20Proxy: bad selector");
    }

    // keccak256("func_602HzuS(address,address,uint256,address)") == 0x23b872dd
    function func_602HzuS(address from, address to, uint256 tokenId, IERC721 token) external onlyImmutableOwner {
        token.transferFrom(from, to, tokenId);
    }
}

contract ERC721ProxySafe is ImmutableOwner {
    constructor(address _immutableOwner) ImmutableOwner(_immutableOwner) {
        require(ERC721ProxySafe.func_602HzuS.selector == IERC20.transferFrom.selector, "ERC20Proxy: bad selector");
    }

    // keccak256("func_602HzuS(address,address,uint256,address)" == 0x23b872e0
    function func_602HzuS(address from, address to, uint256 tokenId, IERC721 token) external onlyImmutableOwner {
        token.safeTransferFrom(from, to, tokenId);
    }
}

/* solhint-enable func-name-mixedcase */
