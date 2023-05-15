//SPDX-License-Identifier: MIT
pragma solidity >=0.8.19;

import "@voltz-protocol/products-dated-irs/src/storage/ProductConfiguration.sol";

/// @title Interface of a dated irs product
interface IProductIRSModule {

    /**
     * @notice Thrown when an attempt to access a function without authorization.
     */
    error NotAuthorized(address caller, bytes32 functionName);

    // process taker and maker orders & single pool

    /**
     * @notice Returns the address that owns a given account, as recorded by the protocol.
     * @param accountId Id of the account that wants to settle
     * @param marketId Id of the market in which the account wants to settle (e.g. 1 for aUSDC lend)
     * @param maturityTimestamp Maturity timestamp of the market in which the account wants to settle
     */
    function settle(uint128 accountId, uint128 marketId, uint32 maturityTimestamp) external;

    /**
     * @notice Initiates a taker order for a given account by consuming liquidity provided by the pool connected to this product
     * @dev Initially a single pool is connected to a single product, however, that doesn't need to be the case in the future
     * @param accountId Id of the account that wants to initiate a taker order
     * @param marketId Id of the market in which the account wants to initiate a taker order (e.g. 1 for aUSDC lend)
     * @param maturityTimestamp Maturity timestamp of the market in which the account wants to initiate a taker order
     * @param priceLimit The Q64.96 sqrt price limit. If !isFT, the price cannot be less than this
     * @param baseAmount Amount of notional that the account wants to trade in either long (+) or short (-) direction depending on
     * sign
     */
    function initiateTakerOrder(
        uint128 accountId,
        uint128 marketId,
        uint32 maturityTimestamp,
        int256 baseAmount,
        uint160 priceLimit
    )
        external
        returns (int256 executedBaseAmount, int256 executedQuoteAmount);

    /**
     * @notice Creates or updates the configuration for the given product.
     * @param config The ProductConfiguration object describing the new configuration.
     *
     * Requirements:
     *
     * - `msg.sender` must be the owner of the system.
     *
     * Emits a {ProductConfigured} event.
     *
     */
    function configureProduct(ProductConfiguration.Data memory config) external;

    /**
     * @notice Propagates maker order to core to check margin requirements
     * @param accountId Id of the account that wants to initiate a taker order
     * @param marketId Id of the market in which the account wants to initiate a taker order (e.g. 1 for aUSDC lend)
     * @param annualizedBaseAmount The annualized notional of the order
     * todo: pool propagates to product and product to core. allowing the
     * pool to interact directly with the core would save gas.
     * this means the Core should have knowledge about the pool for access
     */
    function propagateMakerOrder(uint128 accountId, uint128 marketId, int256 annualizedBaseAmount) external;
}
