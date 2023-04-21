// SPDX-License-Identifier: MIT
pragma solidity >=0.8.13;

import { UD60x18, ZERO } from "@prb/math/src/UD60x18.sol";
import "../interfaces/IPool.sol";
import "../storage/DatedIrsVamm.sol";
import "../storage/PoolPauser.sol";
import "@openzeppelin/contracts/utils/math/SignedMath.sol";
import "../../utils/feature-flag/FeatureFlag.sol";

/// @title Interface a Pool needs to adhere.
contract PoolModule is IPool {
    using DatedIrsVamm for DatedIrsVamm.Data;
    using PoolPauser for PoolPauser.Data;

    bytes32 private constant _PAUSER_FEATURE_FLAG = "registerProduct";

    /// @notice returns a human-readable name for a given pool
    function name(uint128 poolId) external view returns (string memory) {
        return "Dated Irs Pool";
    }

    function executeDatedTakerOrder(
        uint128 marketId,
        uint32 maturityTimestamp,
        int256 baseAmount,
        uint160 priceLimit
    )
        external
        returns (int256 executedBaseAmount, int256 executedQuoteAmount) {
        
        // TODO: authentication!
        PoolPauser.load().whenNotPaused();

        DatedIrsVamm.Data storage vamm = DatedIrsVamm.loadByMaturityAndMarket(marketId, maturityTimestamp);

        IVAMMBase.SwapParams memory swapParams;
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
        (int256 _unfilledBaseLong, int256 _unfilledBaseShort) = vamm.getAccountUnfilledBases(accountId);

        // TODO: we decided to have the unfilled balances unsigned, considering the name already points to a direction
        // to avoid abs(), adjustments are required to getAccountUnfilledBases
        unfilledBaseLong = SignedMath.abs(_unfilledBaseLong);
        unfilledBaseShort = SignedMath.abs(_unfilledBaseShort);
    }


    function closeUnfilledBase(
        uint128 marketId,
        uint32 maturityTimestamp,
        uint128 accountId
    )
        external
        returns (int256 closeUnfilledBasePool) {

        // TODO: authentication!
        PoolPauser.load().whenNotPaused();

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

    /// @inheritdoc IPool
    function getAdjustedDatedIRSGwap(uint128 marketId, uint32 maturityTimestamp, int256 orderSize, uint32 lookbackWindow) external view returns (UD60x18 datedIRSGwap) {
        DatedIrsVamm.Data storage vamm = DatedIrsVamm.loadByMaturityAndMarket(marketId, maturityTimestamp);
        datedIRSGwap = vamm.twap(lookbackWindow, orderSize, true, true);
    }

    /**
     * @notice Get dated irs gwap
     * @param marketId Id of the market for which we want to retrieve the dated irs gwap
     * @param maturityTimestamp Timestamp at which a given market matures
     * @param lookbackWindow Number of seconds in the past from which to calculate the time-weighted means
     * @param orderSize The order size to use when adjusting the price for price impact or spread. Must not be zero if either of the boolean params is true because it used to indicate the direction of the trade and therefore the direction of the adjustment. Function will revert if `abs(orderSize)` overflows when cast to a `U60x18`
     * @param adjustForPriceImpact Whether or not to adjust the returned price by the VAMM's configured spread.
     * @param adjustForSpread Whether or not to adjust the returned price by the VAMM's configured spread.
     * @return datedIRSGwap Geometric Time Weighted Average Fixed Rate
     */
    function getDatedIRSGwap(uint128 marketId, uint32 maturityTimestamp, uint32 lookbackWindow, int256 orderSize, bool adjustForPriceImpact,  bool adjustForSpread) external view returns (UD60x18 datedIRSGwap) {
        DatedIrsVamm.Data storage vamm = DatedIrsVamm.loadByMaturityAndMarket(marketId, maturityTimestamp);
        datedIRSGwap = vamm.twap(lookbackWindow, orderSize, adjustForPriceImpact, adjustForSpread);
    }

    function setPauseState(bool paused) external {
        FeatureFlag.ensureAccessToFeature(_PAUSER_FEATURE_FLAG);
        PoolPauser.load().setPauseState(paused);
    }

    function supportsInterface(bytes4 interfaceId) external pure returns (bool) {
        return interfaceId == type(IPool).interfaceId || interfaceId == this.supportsInterface.selector;
    }
}
