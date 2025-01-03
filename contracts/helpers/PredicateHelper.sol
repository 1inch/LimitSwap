// SPDX-License-Identifier: MIT

pragma solidity ^0.8.23;

/// @title A helper contract for executing boolean functions on arbitrary target call results
contract PredicateHelper {
    error ArbitraryStaticCallFailed();

    /// @notice Calls every target with corresponding data
    /// @return Result True if call to any target returned True. Otherwise, false
    function or(uint256 offsets, bytes calldata data) public view returns(bool) {
        uint256 previous;
        for (uint256 current; (current = uint32(offsets)) != 0; offsets >>= 32) {
            (bool success, uint256 res) = _staticcallForUint(address(this), data[previous:current]);
            if (success && res == 1) {
                return true;
            }
            previous = current;
        }
        return false;
    }

    /// @notice Calls every target with corresponding data
    /// @return Result True if calls to all targets returned True. Otherwise, false
    function and(uint256 offsets, bytes calldata data) public view returns(bool) {
        uint256 previous;
        for (uint256 current; (current = uint32(offsets)) != 0; offsets >>= 32) {
            (bool success, uint256 res) = _staticcallForUint(address(this), data[previous:current]);
            if (!success || res != 1) {
                return false;
            }
            previous = current;
        }
        return true;
    }

    /// @notice Calls target with specified data and tests if it's equal to 0
    /// @return Result True if call to target returns 0. Otherwise, false
    function not(bytes calldata data) public view returns(bool) {
        (bool success, uint256 res) = _staticcallForUint(address(this), data);
        return success && res == 0;
    }

    /// @notice Calls target with specified data and tests if it's equal to the value
    /// @param value Value to test
    /// @return Result True if call to target returns the same value as `value`. Otherwise, false
    function eq(uint256 value, bytes calldata data) public view returns(bool) {
        (bool success, uint256 res) = _staticcallForUint(address(this), data);
        return success && res == value;
    }

    /// @notice Calls target with specified data and tests if it's lower than value
    /// @param value Value to test
    /// @return Result True if call to target returns value which is lower than `value`. Otherwise, false
    function lt(uint256 value, bytes calldata data) public view returns(bool) {
        (bool success, uint256 res) = _staticcallForUint(address(this), data);
        return success && res < value;
    }

    /// @notice Calls target with specified data and tests if it's bigger than value
    /// @param value Value to test
    /// @return Result True if call to target returns value which is bigger than `value`. Otherwise, false
    function gt(uint256 value, bytes calldata data) public view returns(bool) {
        (bool success, uint256 res) = _staticcallForUint(address(this), data);
        return success && res > value;
    }

    /// @notice Performs an arbitrary call to target with data
    /// @return Result Bytes transmuted to uint256
    function arbitraryStaticCall(address target, bytes calldata data) public view returns(uint256) {
        (bool success, uint256 res) = _staticcallForUint(target, data);
        if (!success) revert ArbitraryStaticCallFailed();
        return res;
    }

    function _staticcallForUint(address target, bytes calldata data) internal view returns(bool success, uint256 res) {
        assembly ("memory-safe") { // solhint-disable-line no-inline-assembly
            let ptr := mload(0x40)

            calldatacopy(ptr, data.offset, data.length)
            success := staticcall(gas(), target, ptr, data.length, 0x0, 0x20)
            success := and(success, eq(returndatasize(), 32))
            if success {
                res := mload(0)
            }
        }
    }
}
