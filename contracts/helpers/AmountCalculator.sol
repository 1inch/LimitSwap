// SPDX-License-Identifier: MIT

pragma solidity ^0.7.6;

import "@openzeppelin/contracts/math/SafeMath.sol";
import "../libraries/UncheckedAddress.sol";

/// @title A helper contract for calculations related to order amounts
contract AmountCalculator {
    using SafeMath for uint256;
    using UncheckedAddress for address;

    /// @notice Calculates maker amount
    /// @return Result Floored maker amount
    function getMakerAmount(uint256 orderMakerAmount, uint256 orderTakerAmount, uint256 swapTakerAmount) external pure returns(uint256) {
        return swapTakerAmount.mul(orderMakerAmount).div(orderTakerAmount);
    }

    /// @notice Calculates taker amount
    /// @return Result Ceiled taker amount
    function getTakerAmount(uint256 orderMakerAmount, uint256 orderTakerAmount, uint256 swapMakerAmount) external pure returns(uint256) {
        return (swapMakerAmount.mul(orderTakerAmount).add(orderMakerAmount).sub(1)).div(orderMakerAmount);
    }

    /// @notice Performs an arbitrary call to target with data
    /// @return Result bytes transmuted to uint256
    function arbitraryStaticCall(address target, bytes memory data) external view returns(uint256) {
        (bytes memory result) = target.uncheckedFunctionStaticCall(data, "AC: arbitraryStaticCall");
        return abi.decode(result, (uint256));
    }
}
