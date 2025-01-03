// SPDX-License-Identifier: MIT

pragma solidity ^0.8.23;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";
import "@1inch/solidity-utils/contracts/interfaces/IWETH.sol";

/// @title Generic token for testing purposes with deposit/withdraw capabilities
contract WrappedTokenMock is ERC20Permit, Ownable, IWETH {
    error NotEnoughBalance();

    // solhint-disable-next-line no-empty-blocks
    constructor(string memory name, string memory symbol) ERC20(name, symbol) ERC20Permit(name) Ownable(msg.sender) {}

    // solhint-disable-next-line no-empty-blocks
    receive() external payable {
        deposit();
    }

    function getChainId() external view returns (uint256) {
        return block.chainid;
    }

    function deposit() public payable {
        _mint(msg.sender, msg.value);
        // balanceOf[msg.sender] += msg.value;
        emit Deposit(msg.sender, msg.value);
    }

    function withdraw(uint256 wad) public {
        if (balanceOf(msg.sender) < wad) revert NotEnoughBalance();
        _burn(msg.sender, wad);
        payable(msg.sender).transfer(wad);
        emit Withdrawal(msg.sender, wad);
    }
}
