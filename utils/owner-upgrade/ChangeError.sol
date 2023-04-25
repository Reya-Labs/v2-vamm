// SPDX-License-Identifier: MIT
pragma solidity >=0.8.13;
/**
 * @title Library for change related errors.
 */

library ChangeError {
    /**
     * @dev Thrown when a change is expected but none is detected.
     */
    error NoChange();
}
