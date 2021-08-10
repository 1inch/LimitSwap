// SPDX-License-Identifier: MIT

pragma solidity ^0.7.6;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721.sol";

import "./ImmutableOwner.sol";


/* solhint-disable func-name-mixedcase */

abstract contract ERC721Proxy is ImmutableOwner {
    constructor() {
        require(ERC721Proxy.func_40aVqeY.selector == bytes4(uint32(IERC20.transferFrom.selector) + 2), "ERC20Proxy: bad selector");
        require(ERC721Proxy.func_20xtkDI.selector == bytes4(uint32(IERC20.transferFrom.selector) + 3), "ERC20Proxy: bad selector");
    }

    // keccak256("func_40aVqeY(address,address,uint256,address)") == 0x23b872df
    function func_40aVqeY(address from, address to, uint256 tokenId, IERC721 token) external onlyImmutableOwner {
        token.transferFrom(from, to, tokenId);
    }

    // keccak256("func_20xtkDI(address,address,uint256,address)" == 0x23b872e0
    function func_20xtkDI(address from, address to, uint256 tokenId, IERC721 token) external onlyImmutableOwner {
        token.safeTransferFrom(from, to, tokenId);
    }
}

/* solhint-enable func-name-mixedcase */
