// SPDX-License-Identifier: MIT

pragma solidity ^0.7.6;

import "@openzeppelin/contracts/math/SafeMath.sol";
import "../interfaces/AggregatorV3Interface.sol";

/// @title A helper contract for interactions with https://docs.chain.link
contract ChainlinkCalculator {
    using SafeMath for uint256;

    uint256 private constant _SPREAD_DENOMINATOR = 1e9;
    uint256 private constant _ORACLE_EXPIRATION_TIME = 30 minutes;
    uint256 private constant _INVERSE_MASK = 1 << 255;

    /// @notice Calculates price of token relative to ETH scaled by 1e18
    /// @param inverseAndSpread concatenated inverse flag and spread.
    /// Lowest 254 bits specify spread amount. Spread is scaled by 1e9, i.e. 101% = 1.01e9, 99% = 0.99e9.
    /// Highest bit is set when oracle price should be inverted,
    /// e.g. for DAI-ETH oracle, inverse=false means that we request DAI price in ETH
    /// and inverse=true means that we request ETH price in DAI
    /// @return Result Token price times amount
    function singlePrice(AggregatorV3Interface oracle, uint256 inverseAndSpread, uint256 amount) external view returns(uint256) {
        // solhint-disable-next-line not-rely-on-time
        require(oracle.latestTimestamp() + _ORACLE_EXPIRATION_TIME > block.timestamp, "CC: stale data");
        bool inverse = inverseAndSpread & _INVERSE_MASK > 0;
        uint256 spread = inverseAndSpread & (~_INVERSE_MASK);
        if (inverse) {
            return amount.mul(spread).mul(1e18).div(uint256(oracle.latestAnswer())).div(_SPREAD_DENOMINATOR);
        } else {
            return amount.mul(spread).mul(uint256(oracle.latestAnswer())).div(1e18).div(_SPREAD_DENOMINATOR);
        }
    }

    /// @notice Calculates price of token A relative to token B. Note that order is important
    /// @return Result Token A relative price times amount
    function doublePrice(AggregatorV3Interface oracle1, AggregatorV3Interface oracle2, uint256 spread, uint256 amount) external view returns(uint256) {
        // solhint-disable-next-line not-rely-on-time
        require(oracle1.latestTimestamp() + _ORACLE_EXPIRATION_TIME > block.timestamp, "CC: stale data O1");
        // solhint-disable-next-line not-rely-on-time
        require(oracle2.latestTimestamp() + _ORACLE_EXPIRATION_TIME > block.timestamp, "CC: stale data O2");

        return amount.mul(spread).mul(uint256(oracle1.latestAnswer())).div(uint256(oracle2.latestAnswer())).div(_SPREAD_DENOMINATOR);
    }
}
