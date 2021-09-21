// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/extensions/draft-IERC20Permit.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "./RevertReasonParser.sol";
import "../interfaces/IDaiLikePermit.sol";

contract Permitable {
    event Error(
        string reason
    );

    function _permit(IERC20 token, bytes memory permit) internal {
        if (permit.length > 0) {
            bool success;
            bytes memory result;
            if (permit.length == 32 * 7) {
                // solhint-disable-next-line avoid-low-level-calls
                (success, result) = address(token).call(abi.encodePacked(IERC20Permit.permit.selector, permit));
            } else if (permit.length == 32 * 8) {
                // solhint-disable-next-line avoid-low-level-calls
                (success, result) = address(token).call(abi.encodePacked(IDaiLikePermit.permit.selector, permit));
            } else {
                result = abi.encodeWithSignature("Error(string)", "Wrong permit length");
            }
            if (!success) {
                string memory reason = RevertReasonParser.parse(result, "Permit call failed: ");
                revert(reason);
            }
        }
    }
}
