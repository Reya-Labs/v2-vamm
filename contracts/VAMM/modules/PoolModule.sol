// SPDX-License-Identifier: MIT
pragma solidity >=0.8.13;

import { UD60x18, ZERO } from "@prb/math/src/UD60x18.sol";

import "../interfaces/IPool.sol";
import "../storage/DatedIrsVamm.sol";
import "../storage/PoolPauser.sol";

/// @title Interface a Pool needs to adhere.
contract PoolModule is IPool {
    using DatedIrsVamm for DatedIrsVamm.Data;

    /// @notice returns a human-readable name for a given pool
    function name(uint128 poolId) external view returns (string memory) {
        return "Dated Irs Pool";
    }

    /// @dev note, a pool needs to have this interface to enable account closures initiated by products
    function executeDatedTakerOrder(
        uint128 marketId,
        uint32 maturityTimestamp,
        int256 baseAmount,
        uint160 priceLimit
    )
        external
        returns (int256 executedBaseAmount, int256 executedQuoteAmount) {
        
        // TODO: authentication!
        PoolPauser.whenNotPaused();

        DatedIrsVamm.Data storage vamm = DatedIrsVamm.loadByMaturityAndMarket(marketId, maturityTimestamp);

        VAMMBase.SwapParams memory swapParams;
        swapParams.baseAmountSpecified = baseAmount;
        swapParams.sqrtPriceLimitX96 = priceLimit == 0
                ? (
                    baseAmount < 0 // VT
                        ? TickMath.MIN_SQRT_RATIO + 1
                        : TickMath.MAX_SQRT_RATIO - 1
                )
                : priceLimit;
        //todo: populate recipient field

        (executedBaseAmount, executedQuoteAmount) = vamm.vammSwap(swapParams);
    }

    /**
     * @notice Executes a dated maker order against a vamm that provided liquidity to a given marketId & maturityTimestamp pair
     * @param accountId Id of the `Account` with which the lp wants to provide liqudiity
     * @param marketId Id of the market in which the lp wants to provide liqudiity
     * @param maturityTimestamp Timestamp at which a given market matures
     * @param fixedRateLower Lower Fixed Rate of the range order
     * @param fixedRateUpper Upper Fixed Rate of the range order
     * @param requestedBaseAmount Requested amount of notional provided to a given vamm in terms of the virtual base tokens of the
     * market
     * @param executedBaseAmount Executed amount of notional provided to a given vamm in terms of the virtual base tokens of the
     * market
     */
    function initiateDatedMakerOrder(
        uint128 accountId,
        uint128 marketId,
        uint256 maturityTimestamp,
        uint160 fixedRateLower,
        uint160 fixedRateUpper,
        int128 requestedBaseAmount
    )
        external
        returns (int256 executedBaseAmount){ // TODO: returning 256 for 128 request seems wrong?
       
        PoolPauser.whenNotPaused();
        // TODO: authentication!
        
       DatedIrsVamm.Data storage vamm = DatedIrsVamm.loadByMaturityAndMarket(marketId, maturityTimestamp);
       return vamm.executeDatedMakerOrder(accountId, fixedRateLower, fixedRateUpper, requestedBaseAmount);
    }

    function closeUnfilledBase(
        uint128 marketId,
        uint32 maturityTimestamp,
        uint128 accountId
    )
        external
        returns (int256 closeUnfilledBasePool) {

        // TODO: authentication!
        PoolPauser.whenNotPaused();

        DatedIrsVamm.Data storage vamm = DatedIrsVamm.loadByMaturityAndMarket(marketId, maturityTimestamp);

        uint128[] memory positions = vamm.vars.positionsInAccount[accountId];

        for (uint256 i = 0; i < positions.length; i++) {
            LPPosition.Data memory position = LPPosition.load(positions[i]);
            closeUnfilledBasePool += vamm.executeDatedMakerOrder(
                accountId, 
                TickMath.getSqrtRatioAtTick(position.tickLower),
                TickMath.getSqrtRatioAtTick(position.tickUpper),
                -position.baseAmount
            );
        }
        
    }

    function supportsInterface(bytes4 interfaceId) external pure returns (bool) {
        return interfaceId == type(IPool).interfaceId || interfaceId == this.supportsInterface.selector;
    }
}
