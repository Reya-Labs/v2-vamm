// SPDX-License-Identifier: MIT
pragma solidity >=0.8.13;

import { UD60x18, ZERO } from "@prb/math/src/UD60x18.sol";
import "../interfaces/IPool.sol";
import "../storage/DatedIrsVamm.sol";

/// @title Interface a Pool needs to adhere.
contract PoolModule is IPool {
    using DatedIrsVamm for DatedIrsVamm.Data;

    /// @notice returns a human-readable name for a given pool
    function name(uint128 poolId) external view returns (string memory) {
        return "Dated Irs Pool";
    }

    function executeDatedTakerOrder(
        uint128 marketId,
        uint32 maturityTimestamp,
        int256 baseAmount
    )
        external
        returns (int256 executedBaseAmount, int256 executedQuoteAmount) {
        
        // TODO: authentication!
        // Data storage self = DatedIrsVammPool.load();
        // self.paused.whenNotPaused();

        DatedIrsVamm.Data storage vamm = DatedIrsVamm.loadByMaturityAndMarket(marketId, maturityTimestamp);

        IVAMMBase.SwapParams memory swapParams;
        swapParams.baseAmountSpecified = baseAmount;
        swapParams.sqrtPriceLimitX96 = 
                    baseAmount < 0 // VT
                        ? TickMath.MIN_SQRT_RATIO + 1
                        : TickMath.MAX_SQRT_RATIO - 1;
        // swapParams.sqrtPriceLimitX96 = priceLimit == 0
        //         ? (
        //             baseAmount < 0 // VT
        //                 ? TickMath.MIN_SQRT_RATIO + 1
        //                 : TickMath.MAX_SQRT_RATIO - 1
        //         )
        //         : priceLimit;
        swapParams.tickLower = TickMath.MIN_TICK;
        swapParams.tickUpper = TickMath.MAX_TICK - 1;

        (executedBaseAmount, executedQuoteAmount) = vamm.vammSwap(swapParams);
    }

    function getAccountFilledBalances(
        uint128 marketId,
        uint32 maturityTimestamp,
        uint128 accountId
    )
        external
        view
        returns (int256 baseBalancePool, int256 quoteBalancePool){     
        DatedIrsVamm.Data storage vamm = DatedIrsVamm.loadByMaturityAndMarket(marketId, maturityTimestamp);
        return vamm.getAccountFilledBalances(accountId);
    
    }

    function getAccountUnfilledBases(
        uint128 marketId,
        uint32 maturityTimestamp,
        uint128 accountId
    )
        external
        view
        returns (uint256 unfilledBaseLong, uint256 unfilledBaseShort) {      
        DatedIrsVamm.Data storage vamm = DatedIrsVamm.loadByMaturityAndMarket(marketId, maturityTimestamp);
        (int256 long, int256 short) = vamm.getAccountUnfilledBases(accountId);

        // TODo: safecast
        unfilledBaseLong = uint256(long);
        unfilledBaseLong = uint256(short);
    }

    function closePosition(
        uint128 marketId,
        uint32 maturityTimestamp,
        uint128 accountId
    )
        external
        returns (int256 closedBasePool, int256 closedQuotePool) {
        
        closedBasePool = 0;
        closedQuotePool = 0;
    }

    function getDatedIRSGwap(uint128 marketId, uint32 maturityTimestamp) external view returns (UD60x18 datedIRSGwap) {
        datedIRSGwap = ZERO;
    }

    function supportsInterface(bytes4 interfaceID) external pure returns (bool) {
        return true;
    }

    // function closeUnfilledBase(
    //     uint128 marketId,
    //     uint32 maturityTimestamp,
    //     uint128 accountId
    // )
    //     external
    //     returns (int256 closedBasePool) {

    //     DatedIrsVamm.Data storage vamm = DatedIrsVamm.loadByMaturityAndMarket(marketId, maturityTimestamp);

    //     uint128[] positions = vamm.state.positionsInAccount[accountId];

    //     for (uint256 i = 0; i < positions.length; i++) {
    //         uint128 baseAmount = LPPosition.load(positions[i]).baseAmount;
            
    //         closedBasePool = vamm.executeDatedMakerOrder(
    //             accountId, 
    //             TickMath.getSqrtRatioAtTick(position.tickLower),
    //             TickMath.getSqrtRatioAtTick(position.tickUpper),
    //             -baseAmount
    //         );
    //     }
        
    //     // todo: closedQuotePool
    // }

    // /**
    //  * @notice Get dated irs gwap for the purposes of unrealized pnl calculation in the portfolio (see Portfolio.sol)
    //  * @param marketId Id of the market for which we want to retrieve the dated irs gwap
    //  * @param maturityTimestamp Timestamp at which a given market matures
    //  * @return datedIRSGwap Geometric Time Weighted Average Fixed Rate
    //  */
    // function getDatedIRSGwap(uint128 marketId, uint32 maturityTimestamp, int256 orderSize, uint32 lookbackWindow) external view returns (UD60x18 datedIRSGwap) {
    //     DatedIrsVamm.Data storage vamm = DatedIrsVamm.loadByMaturityAndMarket(marketId, maturityTimestamp);
    //     datedIRSGwap = vamm.twap(lookbackWindow, orderSize, true, true);
    // }

    // function getAdjustedDatedIRSGwap(uint128 marketId, uint32 maturityTimestamp, uint32 secondsAgo, int256 orderSize, bool adjustForPriceImpact,  bool adjustForSpread) external view returns (UD60x18 datedIRSGwap) {
    //     DatedIrsVamm.Data storage vamm = DatedIrsVamm.loadByMaturityAndMarket(marketId, maturityTimestamp);
    //     datedIRSGwap = vamm.twap(lookbackWindow, orderSize, adjustForPriceImpact, adjustForSpread);
    // }
}
