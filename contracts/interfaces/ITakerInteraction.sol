// SPDX-License-Identifier: MIT

pragma solidity 0.8.17;

/**
 * @title Interface for interactor which acts after `taker -> maker` transfers.
 * @notice The order filling steps are `preInteraction` =>` Transfer "maker -> taker"` => **`Interaction`** => `Transfer "taker -> maker"` => `postInteraction`
 */
interface ITakerInteraction {
    /**
     * @notice Callback method that gets called after all funds transfers
     * @param taker Taker address (tx sender)
     * @param makingAmount Actual making amount
     * @param takingAmount Actual taking amount
     * @param interactionData Interaction calldata
     * @return offeredTakingAmount Suggested amount. Order is filled with this amount if maker or taker getter functions are not defined.
     */
    function fillOrderInteraction(
        address taker,
        uint256 makingAmount,
        uint256 takingAmount,
        bytes calldata interactionData
    ) external returns(uint256 offeredTakingAmount);
}