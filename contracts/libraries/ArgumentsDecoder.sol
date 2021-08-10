// SPDX-License-Identifier: MIT

pragma solidity ^0.7.6;


library ArgumentsDecoder {
    function decodeSelector(bytes memory data) internal pure returns(bytes4 selector) {
        assembly { // solhint-disable-line no-inline-assembly
            selector := mload(add(data, 0x20))
        }
    }

    function decodeAddress(bytes memory data, uint256 argumentIndex) internal pure returns(address account) {
        assembly { // solhint-disable-line no-inline-assembly
            account := mload(add(add(data, 0x24), mul(argumentIndex, 0x20)))
        }
    }

    function decodeUint256(bytes memory data, uint256 argumentIndex) internal pure returns(uint256 value) {
        assembly { // solhint-disable-line no-inline-assembly
            value := mload(add(add(data, 0x24), mul(argumentIndex, 0x20)))
        }
    }

    function patchAddress(bytes memory data, uint256 argumentIndex, address account) internal pure {
        assembly { // solhint-disable-line no-inline-assembly
            mstore(add(add(data, 0x24), mul(argumentIndex, 0x20)), account)
        }
    }

    function patchUint256(bytes memory data, uint256 argumentIndex, uint256 value) internal pure {
        assembly { // solhint-disable-line no-inline-assembly
            mstore(add(add(data, 0x24), mul(argumentIndex, 0x20)), value)
        }
    }
}
