// SPDX-License-Identifier: MIT
pragma solidity >=0.8.13;

import "@voltz-protocol/util-contracts/src/interfaces/IERC165.sol";
import { UD60x18 } from "@prb/math/UD60x18.sol";

/// @title Interface a Pool needs to adhere.
interface IPoolModule is IERC165 {

    /**
     * @notice Thrown when an attempt to access a function without authorization.
     */
    error NotAuthorized(address caller, bytes32 functionName);

    /// @notice returns a human-readable name for a given pool
    function name() external view returns (string memory);

    /**
     * @notice Initiates a taker order for a given account by consuming liquidity provided by the pool
     * @dev It also enables account closures initiated by products
     * @param marketId Id of the market in which the account wants to initiate a taker order (e.g. 1 for aUSDC lend)
     * @param maturityTimestamp Maturity timestamp of the market in which the account wants to initiate a taker order
     * @param priceLimit The Q64.96 sqrt price limit. If !isFT, the price cannot be less than this
     * @param baseAmount Amount of notional that the account wants to trade in either long (+) or short (-) direction depending on
     * @param sqrtPriceLimitX96 The Q64.96 sqrt price limit. If !isFT, the price cannot be less than this
     */
    /// @dev note, 
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
     * @param accountId Id of the `Account` with which the lp wants to provide liqudity
     * @param marketId Id of the market in which the lp wants to provide liqudiity
     * @param maturityTimestamp Timestamp at which a given market matures
     * @param tickLower Lower tick of the range order
     * @param tickUpper Upper tick of the range order
     * @param liquidityDelta Liquidity to add (positive values) or remove (negative values) witin the tick range
     */
    function initiateDatedMakerOrder(
        uint128 accountId,
        uint128 marketId,
        uint32 maturityTimestamp,
        int24 tickLower,
        int24 tickUpper,
        int128 liquidityDelta
    )
        external;

    /**
     * @notice Attempts to close all the unfilled and filled positions of a given account in the specified market
     * @param marketId Id of the market in which the positions should be closed
     * @param maturityTimestamp Timestamp at which a given market matures
     * @param accountId Id of the `Account` with which the lp wants to provide liqudity
     * @return closedUnfilledBase Total amount of unfilled based that was burned
     */
    function closeUnfilledBase(
        uint128 marketId,
        uint32 maturityTimestamp,
        uint128 accountId
    )
        external
        returns (int256 closedUnfilledBase);
}
