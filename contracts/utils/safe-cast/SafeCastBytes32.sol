// SPDX-License-Identifier: MIT
pragma solidity >=0.8.13;

/**
 * @title See SafeCast.sol.
 */
library SafeCastBytes32 {
    function toAddress(bytes32 x) internal pure returns (address) {
        return address(uint160(uint256(x)));
    }

    function toUint(bytes32 x) internal pure returns (uint256) {
        return uint256(x);
    }
}
