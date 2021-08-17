// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

import "@openzeppelin/contracts/interfaces/IERC1271.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import "../LimitOrderProtocol.sol";
import "../libraries/ArgumentsDecoder.sol";
import "./EIP712Alien.sol";


contract ContractRFQ is IERC1271, EIP712Alien, ERC20 {
    using SafeERC20 for IERC20;
    using ArgumentsDecoder for bytes;

    bytes32 constant public LIMIT_ORDER_RFQ_TYPEHASH = keccak256(
        "OrderRFQ(uint256 info,address makerAsset,address takerAsset,bytes makerAssetData,bytes takerAssetData)"
    );

    uint256 constant private _FROM_INDEX = 0;
    uint256 constant private _TO_INDEX = 1;
    uint256 constant private _AMOUNT_INDEX = 2;

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
        EIP712Alien(_protocol, "1inch Limit Order Protocol", "1")
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
        require(token == token0 || token == token1, "ContractRFQ: not allowed token");

        _mint(to, amount * fee2 / 1e18);
        token.safeTransferFrom(msg.sender, address(this), amount);
    }

    function withdraw(IERC20 token, uint256 amount) public {
        withdrawFor(token, amount, msg.sender);
    }

    function withdrawFor(IERC20 token, uint256 amount, address to) public {
        require(token == token0 || token == token1, "ContractRFQ: not allowed token");

        _burn(msg.sender, amount);
        token.safeTransfer(to, amount * fee2 / 1e18);
    }

    function isValidSignature(bytes32 hash, bytes memory signature) public view override returns(bytes4) {
        //LimitOrderProtocol.OrderRFQ memory order = abi.decode(signature, (LimitOrderProtocol.OrderRFQ));
        uint256 info;
        address makerAsset;
        address takerAsset;
        bytes memory makerAssetData;
        bytes memory takerAssetData;
        assembly {  // solhint-disable-line no-inline-assembly
            info := mload(add(signature, 0x40))
            makerAsset := mload(add(signature, 0x60))
            takerAsset := mload(add(signature, 0x80))
            makerAssetData := add(add(signature, 0x40), mload(add(signature, 0xA0)))
            takerAssetData := add(add(signature, 0x40), mload(add(signature, 0xC0)))
        }

        require(
            (
                (makerAsset == address(token0) && takerAsset == address(token1)) ||
                (makerAsset == address(token1) && takerAsset == address(token0))
            ) &&
            makerAssetData.decodeUint256(_AMOUNT_INDEX) * fee <= takerAssetData.decodeUint256(_AMOUNT_INDEX) * 1e18 &&
            takerAssetData.decodeAddress(_TO_INDEX) == address(this) &&
            _hash(info, makerAsset, takerAsset, makerAssetData, takerAssetData) == hash,
            "ContractRFQ: bad price"
        );

        return this.isValidSignature.selector;
    }

    function _hash(
        uint256 info,
        address makerAsset,
        address takerAsset,
        bytes memory makerAssetData,
        bytes memory takerAssetData
    ) internal view returns(bytes32) {
        return _hashTypedDataV4(
            keccak256(
                abi.encode(
                    LIMIT_ORDER_RFQ_TYPEHASH,
                    info,
                    makerAsset,
                    takerAsset,
                    keccak256(makerAssetData),
                    keccak256(takerAssetData)
                )
            )
        );
    }
}
