// SPDX-License-Identifier: MIT

pragma solidity ^0.8.23;

/// @title The helper library to calculate linearly taker amount from maker amount and vice versa.
library AmountCalculatorLib {
    /// @notice Calculates maker amount
    /// @return Result Floored maker amount
    function getMakingAmount(uint256 orderMakerAmount, uint256 orderTakerAmount, uint256 swapTakerAmount) internal pure returns(uint256) {
        if ((swapTakerAmount | orderMakerAmount) >> 128 == 0) {
            unchecked {
                return (swapTakerAmount * orderMakerAmount) / orderTakerAmount;
            }
        }
        return swapTakerAmount * orderMakerAmount / orderTakerAmount;
    }

    /// @notice Calculates taker amount
    /// @return Result Ceiled taker amount
    function getTakingAmount(uint256 orderMakerAmount, uint256 orderTakerAmount, uint256 swapMakerAmount) internal pure returns(uint256) {
        if ((swapMakerAmount | orderTakerAmount) >> 128 == 0) {
            unchecked {
                return (swapMakerAmount * orderTakerAmount + orderMakerAmount - 1) / orderMakerAmount;
            }
        }
        return (swapMakerAmount * orderTakerAmount + orderMakerAmount - 1) / orderMakerAmount;
    }
}
