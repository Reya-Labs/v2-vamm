// SPDX-License-Identifier: MIT
pragma solidity >=0.8.13;

import { UD60x18, ZERO } from "@prb/math/UD60x18.sol";

import "../interfaces/IPoolModule.sol";
import "../storage/DatedIrsVamm.sol";
import "../storage/PoolPauser.sol";

/// @title Interface a Pool needs to adhere.
contract PoolModule is IPoolModule {
    using DatedIrsVamm for DatedIrsVamm.Data;

    /// @notice returns a human-readable name for a given pool
    function name(uint128 poolId) external view override returns (string memory) {
        return "Dated Irs Pool";
    }

    /**
     * @inheritdoc IPoolModule
     */
    function executeDatedTakerOrder(
        uint128 marketId,
        uint32 maturityTimestamp,
        int256 baseAmount,
        uint160 priceLimit
    )
        external override
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
     * @inheritdoc IPoolModule
     */
    function initiateDatedMakerOrder(
        uint128 accountId,
        uint128 marketId,
        uint256 maturityTimestamp,
        uint160 fixedRateLower,
        uint160 fixedRateUpper,
        int128 requestedBaseAmount
    )
        external override
        returns (int256 executedBaseAmount){ // TODO: returning 256 for 128 request seems wrong?
       
        PoolPauser.whenNotPaused();
        // TODO: authentication!
        
       DatedIrsVamm.Data storage vamm = DatedIrsVamm.loadByMaturityAndMarket(marketId, maturityTimestamp);
       return vamm.executeDatedMakerOrder(accountId, fixedRateLower, fixedRateUpper, requestedBaseAmount);
    }

    /**
     * @inheritdoc IPoolModule
     */
    function closeUnfilledBase(
        uint128 marketId,
        uint32 maturityTimestamp,
        uint128 accountId
    )
        external override
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

    function supportsInterface(bytes4 interfaceId) external pure override returns (bool) {
        return interfaceId == type(IPoolModule).interfaceId || interfaceId == this.supportsInterface.selector;
    }
}
