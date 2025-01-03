// SPDX-License-Identifier: MIT

pragma solidity ^0.8.23;

import { EIP712 } from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "./OrderMixin.sol";

/**
 * @title ##1inch Limit Order Protocol v4
 * @notice Limit order protocol provides two different order types
 * - Regular Limit Order
 * - RFQ Order
 *
 * Both types provide similar order-fulfilling functionality. The difference is that regular order offers more customization options and features, while RFQ order is extremely gas efficient but without ability to customize.
 *
 * Regular limit order additionally supports
 * - Execution predicates. Conditions for order execution are set with predicates. For example, expiration timestamp or block number, price for stop loss or take profit strategies.
 * - Callbacks to notify maker on order execution
 *
 * See [OrderMixin](OrderMixin.md) for more details.
 *
 * RFQ orders supports
 * - Expiration time
 * - Cancelation by order id
 * - Partial Fill (only once)
 *
 * See [OrderMixin](OrderMixin.md) for more details.
 */
contract LimitOrderProtocol is
    EIP712("1inch Limit Order Protocol", "4"),
    Ownable,
    Pausable,
    OrderMixin
{
    // solhint-disable-next-line no-empty-blocks
    constructor(IWETH _weth) OrderMixin(_weth) Ownable(msg.sender) {}

    /// @dev Returns the domain separator for the current chain (EIP-712)
    // solhint-disable-next-line func-name-mixedcase
    function DOMAIN_SEPARATOR() external view returns(bytes32) {
        return _domainSeparatorV4();
    }

    /**
     * @notice Pauses all the trading functionality in the contract.
     */
    function pause() external onlyOwner {
        _pause();
    }

    /**
     * @notice Unpauses all the trading functionality in the contract.
     */
    function unpause() external onlyOwner {
        _unpause();
    }
}
