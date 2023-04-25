// SPDX-License-Identifier: Apache-2.0

pragma solidity >=0.8.13;

import { UD60x18, convert } from "@prb/math/src/UD60x18.sol";

/// @title A utility library for mathematics of fixed and variable token amounts.
library FixedAndVariableMath {
    /// @notice Number of seconds in a year
    /// @dev Ignoring leap years since we're only using it to calculate the eventual APY rate
    UD60x18 public constant SECONDS_IN_YEAR = UD60x18.wrap(31536000e18);

    /// @notice Divide a given time in seconds by the number of seconds in a year
    /// @param timeInSeconds A time in seconds
    /// @return timeInYears An annualised factor of `timeInSeconds`, as a `UD60x18`
    function accrualFact(uint256 timeInSeconds)
        internal
        pure
        returns (UD60x18 timeInYears)
    {
        timeInYears = convert(timeInSeconds).div(SECONDS_IN_YEAR);
    }
}
