// SPDX-License-Identifier: MIT
pragma solidity >=0.8.13;

import "../../utils/interfaces/IERC165.sol";
import { UD60x18 } from "@prb/math/src/UD60x18.sol";

/// @title Interface a Pool needs to adhere.
interface IPool is IERC165 {
    /// @notice returns a human-readable name for a given pool
    function name(uint128 poolId) external view returns (string memory);

    function executeDatedTakerOrder(
        uint128 marketId,
        uint32 maturityTimestamp,
        int256 baseAmount,
        uint160 priceLimit
    )
        external
        returns (int256 executedBaseAmount, int256 executedQuoteAmount);

    // function getAccountFilledBalances(
    //     uint128 marketId,
    //     uint32 maturityTimestamp,
    //     uint128 accountId
    // )
    //     external
    //     view
    //     returns (int256 baseBalancePool, int256 quoteBalancePool);

    // function getAccountUnfilledBases(
    //     uint128 marketId,
    //     uint32 maturityTimestamp,
    //     uint128 accountId
    // )
    //     external
    //     view
    //     returns (uint256 unfilledBaseLong, uint256 unfilledBaseShort);

    function closeUnfilledBase(
        uint128 marketId,
        uint32 maturityTimestamp,
        uint128 accountId
    )
        external
        returns (int256 closeUnfilledBase);

    /**
     * @notice Get dated irs gwap for the purposes of unrealized pnl calculation in the portfolio (see Portfolio.sol)
     * @param marketId Id of the market for which we want to retrieve the dated irs gwap
     * @param maturityTimestamp Timestamp at which a given market matures
     * @param orderSize The order size to use when adjusting the price for price impact or spread. Must not be zero if either of the boolean params is true because it used to indicate the direction of the trade and therefore the direction of the adjustment. Function will revert if `abs(orderSize)` overflows when cast to a `U60x18`
     * @param lookbackWindow Whether or not to adjust the returned price by the VAMM's configured spread.
     * @return datedIRSGwap Geometric Time Weighted Average Fixed Rate
     */
    // function getAdjustedDatedIRSGwap(uint128 marketId, uint32 maturityTimestamp, int256 orderSize, uint32 lookbackWindow) external view returns (UD60x18 datedIRSGwap);
}
