// SPDX-License-Identifier: MIT
pragma solidity >=0.8.13;

import "../../utils/interfaces/IERC165.sol";
import { UD60x18 } from "@prb/math/UD60x18.sol";

/// @title Interface a Pool needs to adhere.
interface IPoolModule is IERC165 {
    /// @notice returns a human-readable name for a given pool
    function name(uint128 poolId) external view returns (string memory);

    /// @dev todo docs
    /// @dev note, a pool needs to have this interface to enable account closures initiated by products
    function executeDatedTakerOrder(
        uint128 marketId,
        uint32 maturityTimestamp,
        int256 baseAmount,
        uint160 sqrtPriceLimitX96
    )
        external
        returns (int256 executedBaseAmount, int256 executedQuoteAmount);

    /**
     * @notice Provides liquidity to (or removes liquidty from) a given marketId & maturityTimestamp pair
     * @param accountId Id of the `Account` with which the lp wants to provide liqudiity
     * @param marketId Id of the market in which the lp wants to provide liqudiity
     * @param maturityTimestamp Timestamp at which a given market matures
     * @param fixedRateLower Lower Fixed Rate of the range order
     * @param fixedRateUpper Upper Fixed Rate of the range order
     * @param liquidityDelta Liquidity to add (positive values) or remove (negative values) witin the tick range
     */
    function initiateDatedMakerOrder(
        uint128 accountId,
        uint128 marketId,
        uint256 maturityTimestamp,
        uint160 fixedRateLower,
        uint160 fixedRateUpper,
        int128 liquidityDelta
    )
        external;

    /// @dev todo docs
    function closeUnfilledBase(
        uint128 marketId,
        uint32 maturityTimestamp,
        uint128 accountId
    )
        external
        returns (int256 closeUnfilledBase);
}
