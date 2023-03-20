// SPDX-License-Identifier: Apache-2.0
// TODO: import from v2-core instead of copying.

pragma solidity =0.8.17;

import { UD60x18 } from "@prb/math/src/UD60x18.sol";

/// @dev The RateOracle is used for two purposes on the Voltz Protocol
/// @dev Settlement: in order to be able to settle IRS positions after the termEndTimestamp of a given AMM
/// @dev Margin Engine Computations: getApyFromTo is used by the MarginEngine
/// @dev It is necessary to produce margin requirements for Trader and Liquidity Providers
interface IRateOracle {
    /// @notice Get the last updated liquidity index with the timestamp at which it was written
    /// This data point must be a known data point from the source of the data, and not extrapolated or interpolated by us.
    /// The source and expected values of "lquidity index" may differ by rate oracle type. All that
    /// matters is that we can divide one "liquidity index" by another to get the factor of growth between the two timestamps.
    /// For example if we have indices of { (t=0, index=5), (t=100, index=5.5) }, we can divide 5.5 by 5 to get a growth factor
    /// of 1.1, suggesting that 10% growth in capital was experienced between timesamp 0 and timestamp 100.
    /// @dev The liquidity index is normalised to a UD60x18 for storage, so that we can perform consistent math across all rates.
    /// @dev This function should revert if a valid rate cannot be discerned
    /// @return timestamp the timestamp corresponding to the known rate (could be the current time, or a time in the past)
    /// @return liquidityIndex the liquidity index value, as a decimal scaled up by 10^18 for storage in a uint256
    function getLastUpdatedIndex() external view returns (uint40 timestamp, UD60x18 liquidityIndex);

    /// @notice Get the current liquidity index for the rate oracle
    /// This data point may be extrapolated from data known data points available in the underlying platform.
    /// The source and expected values of "lquidity index" may differ by rate oracle type. All that
    /// matters is that we can divide one "liquidity index" by another to get the factor of growth between the two timestamps.
    /// For example if we have indices of { (t=0, index=5), (t=100, index=5.5) }, we can divide 5.5 by 5 to get a growth factor
    /// of 1.1, suggesting that 10% growth in capital was experienced between timesamp 0 and timestamp 100.
    /// @dev The liquidity index is normalised to a UD60x18 for storage, so that we can perform consistent math across all rates.
    /// @dev This function should revert if a valid rate cannot be discerned
    /// @return liquidityIndex the liquidity index value, as a decimal scaled up by 10^18 for storage in a uint256
    function getCurrentIndex() external view returns (UD60x18 liquidityIndex);

    /// @notice Estimate an index for `queryTimestamp`, using known data points either side
    /// Some implementations may assume that index growth is compounded, others that growth is simple (not compounded)
    function interpolateIndexValue(
        UD60x18 beforeIndex,
        uint256 beforeTimestamp,
        UD60x18 atOrAfterIndex,
        uint256 atOrAfterTimestamp,
        uint256 queryTimestamp
    )
        external
        pure
        returns (UD60x18 interpolatedIndex);
}
