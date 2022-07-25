// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

import "@openzeppelin/contracts/interfaces/IERC1271.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import "../LimitOrderProtocol.sol";
import "../libraries/ArgumentsDecoder.sol";
import "../OrderRFQLib.sol";
import { EIP712Alien } from "./EIP712Alien.sol";

contract ContractRFQ is IERC1271, EIP712Alien, ERC20 {
    using SafeERC20 for IERC20;
    using ArgumentsDecoder for bytes;
    using OrderRFQLib for OrderRFQLib.OrderRFQ;

    error NotAllowedToken();
    error BadPrice();
    error MalformedSignature();

    address immutable public protocol;
    IERC20 immutable public token0;
    IERC20 immutable public token1;
    uint256 immutable public fee;
    uint256 immutable public fee2;

    constructor(
        address _protocol,
        IERC20 _token0,
        IERC20 _token1,
        uint256 _fee,
        string memory name,
        string memory symbol
    )
        EIP712Alien(_protocol, "1inch Limit Order Protocol", "3")
        ERC20(name, symbol)
    {
        protocol = _protocol;
        token0 = _token0;
        token1 = _token1;
        fee = _fee;
        fee2 = 2e18 * _fee / (1e18 + _fee);
        _token0.approve(_protocol, type(uint256).max);
        _token1.approve(_protocol, type(uint256).max);
    }

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function deposit(IERC20 token, uint256 amount) public {
        depositFor(token, amount, msg.sender);
    }

    function depositFor(IERC20 token, uint256 amount, address to) public {
        if (token != token0 && token != token1) revert NotAllowedToken();

        _mint(to, amount * fee2 / 1e18);
        token.safeTransferFrom(msg.sender, address(this), amount);
    }

    function withdraw(IERC20 token, uint256 amount) public {
        withdrawFor(token, amount, msg.sender);
    }

    function withdrawFor(IERC20 token, uint256 amount, address to) public {
        if (token != token0 && token != token1) revert NotAllowedToken();

        _burn(msg.sender, amount);
        token.safeTransfer(to, amount * fee2 / 1e18);
    }

    function isValidSignature(bytes32 hash, bytes calldata signature) external view override returns(bytes4) {
        OrderRFQLib.OrderRFQ calldata order;
        if (signature.length != 32 * 7) revert MalformedSignature();
        /// @solidity memory-safe-assembly
        assembly { // solhint-disable-line no-inline-assembly
            order := signature.offset
        }

        if (
            (
                (order.makerAsset != address(token0) || order.takerAsset != address(token1)) &&
                (order.makerAsset != address(token1) || order.takerAsset != address(token0))
            ) ||
            order.makingAmount * fee > order.takingAmount * 1e18 ||
            order.maker != address(this) || // TODO: remove redundant check
            order.hash(_domainSeparatorV4()) != hash
        ) revert BadPrice();

        return this.isValidSignature.selector;
    }
}
