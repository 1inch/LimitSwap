// SPDX-License-Identifier: MIT

pragma solidity ^0.7.6;


interface InteractiveMaker {
    function notifyFillOrder(
        address makerAsset,
        address takerAsset,
        uint256 makingAmount,
        uint256 takingAmount,
        bytes memory interactiveData
    ) external;
}
