// SPDX-License-Identifier: MIT

pragma solidity ^0.7.6;


library UncheckedAddress {
    function uncheckedFunctionCall(address target, bytes memory data, string memory errorMessage) internal returns (bytes memory) {
        return uncheckedFunctionCallWithValue(target, data, 0, errorMessage);
    }

    function uncheckedFunctionCallWithValue(address target, bytes memory data, uint256 value, string memory errorMessage) internal returns (bytes memory) {
        require(address(this).balance >= value, "UA: insufficient balance");
        // Check turned off:
        // require(isContract(target), "Address: call to non-contract");

        // solhint-disable-next-line avoid-low-level-calls
        (bool success, bytes memory returndata) = target.call{ value: value }(data);
        return _verifyCallResult(success, returndata, errorMessage);
    }

    function uncheckedFunctionStaticCall(address target, bytes memory data, string memory errorMessage) internal view returns (bytes memory) {
        // Check turned off:
        // require(isContract(target), "Address: static call to non-contract");

        // solhint-disable-next-line avoid-low-level-calls
        (bool success, bytes memory returndata) = target.staticcall(data);
        return _verifyCallResult(success, returndata, errorMessage);
    }

    //noinspection NoReturn
    function _verifyCallResult(bool success, bytes memory returndata, string memory errorMessage) private pure returns(bytes memory) {
        if (success) {
            return returndata;
        } else {
            // Look for revert reason and bubble it up if present
            if (returndata.length > 0) {
                // The easiest way to bubble the revert reason is using memory via assembly

                // solhint-disable-next-line no-inline-assembly
                assembly {
                    revert(add(32, returndata), mload(returndata))
                }
            } else {
                revert(errorMessage);
            }
        }
    }
}
