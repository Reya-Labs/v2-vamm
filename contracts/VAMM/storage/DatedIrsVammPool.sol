// SPDX-License-Identifier: MIT
pragma solidity >=0.8.13;

import "./DatedIrsVamm.sol";
import "../libraries/VAMMBase.sol";

/// @title Interface a Pool needs to adhere.
library DatedIrsVammPool {
    using DatedIrsVamm for DatedIrsVamm.Data;

    struct Position {
        address accountId;
        uint256 id;
        /** 
        * @dev position notional amount
        */
        int128 baseAmount;
        /** 
        * @dev lower tick boundary of the position
        */
        int24 tickLower;
        /** 
        * @dev upper tick boundary of the position
        */
        int24 tickUpper;
        /** 
        * @dev fixed token growth per unit of liquidity as of the last update to liquidity or fixed/variable token balance
        */
        int256 tracker0UpdatedGrowth;
        /** 
        * @dev variable token growth per unit of liquidity as of the last update to liquidity or fixed/variable token balance
        */
        int256 tracker1UpdatedGrowth;
        /** 
        * @dev current Fixed Token balance of the position, 1 fixed token can be redeemed for 1% APY * (annualised amm term) at the maturity of the amm
        * assuming 1 token worth of notional "deposited" in the underlying pool at the inception of the amm
        * can be negative/positive/zero
        */
        int256 tracker0Accumulated;
        /** 
        * @dev current Variable Token Balance of the position, 1 variable token can be redeemed for underlyingPoolAPY*(annualised amm term) at the maturity of the amm
        * assuming 1 token worth of notional "deposited" in the underlying pool at the inception of the amm
        * can be negative/positive/zero
        */
        int256 tracker1Accumulated;
    }

    struct Data {
        /**
         * @dev Numeric identifier for the vamm. Must be unique.
         * @dev There cannot be a vamm with id zero (See VAMMCreator.create()). Id zero is used as a null vamm reference.
         */
        uint128 id;
        /**
         * @dev Text identifier for the vamm.
         *
         * Not required to be unique.
         */
        string name;
        /**
         * @dev Creator of the vamm, which has configuration access rights for the vamm.
         *
         * See onlyVAMMOwner.
         */
        address owner;

        address gtwapOracle;

        mapping(uint256 => Position) positions;

        mapping(address => Position[]) positionsInAccount;

        mapping(uint256 => bool) supportedMaturities;
    }

    function load(uint128 id) internal pure returns (Data storage self) {
        bytes32 s = keccak256(abi.encode("xyz.voltz.VAMMPool", id));
        assembly {
            self.slot := s
        }
    }

    /// @dev note, a pool needs to have this interface to enable account closures initiated by products
    /// @dev in the future -> executePerpetualTakerOrder(uint128 marketId, int256 baseAmount)
    /// for products that don't have maturities
    function executeDatedTakerOrder(
        Data storage self,
        uint128 marketId,
        uint256 maturityTimestamp,
        int256 baseAmount,
        uint160 priceLimit
    )
        internal
        returns (int256 executedBaseAmount, int256 executedQuoteAmount){

        require(self.supportedMaturities[maturityTimestamp], "Maturity not supported");

        // what happens if vamm for maturity & market does not exist?
        DatedIrsVamm.Data storage vamm = DatedIrsVamm.loadByMaturityAndMarket(marketId, maturityTimestamp);

        VAMMBase.SwapParams memory swapParams;
        swapParams.recipient = msg.sender;
        swapParams.amountSpecified = baseAmount;
        swapParams.sqrtPriceLimitX96 = priceLimit == 0
                ? (
                    baseAmount < 0 // VT
                        ? TickMath.MIN_SQRT_RATIO + 1
                        : TickMath.MAX_SQRT_RATIO - 1
                )
                : priceLimit;
        swapParams.tickLower = TickMath.MIN_TICK;
        swapParams.tickUpper = TickMath.MAX_TICK - 1;

        (executedBaseAmount, executedQuoteAmount) = vamm.vammSwap(swapParams);
    }

    /**
     * @notice Executes a dated maker order against a vamm that provided liquidity to a given marketId & maturityTimestamp pair
     * @param marketId Id of the market in which the lp wants to provide liqudiity
     * @param maturityTimestamp Timestamp at which a given market matures
     * @param fixedRateLower Lower Fixed Rate of the range order
     * @param fixedRateUpper Upper Fixed Rate of the range order
     * @param requestedBaseAmount Requested amount of notional provided to a given vamm in terms of the virtual base tokens of the
     * market
     * @param executedBaseAmount Executed amount of notional provided to a given vamm in terms of the virtual base tokens of the
     * market
     */
    function executeDatedMakerOrder(
        Data storage self,
        uint128 marketId,
        uint256 maturityTimestamp,
        uint160 fixedRateLower,
        uint160 fixedRateUpper,
        int128 requestedBaseAmount
    )
        internal
        returns (int256 executedBaseAmount){
        
       require(self.supportedMaturities[maturityTimestamp], "Maturity not supported");

        int24 tickLower = TickMath.getTickAtSqrtRatio(fixedRateUpper);
        int24 tickUpper = TickMath.getTickAtSqrtRatio(fixedRateLower);

       uint256 positionId = openPosition(self, msg.sender, tickLower, tickUpper);

        // what happens if vamm for maturity & market does not exist?
       DatedIrsVamm.Data storage vamm = DatedIrsVamm.loadByMaturityAndMarket(marketId, maturityTimestamp);
       Position memory position = getRawPosition(self, positionId, vamm);

       require(position.baseAmount + requestedBaseAmount >= 0, "Burning too much");

       vamm.vammMint(msg.sender, tickLower, tickUpper, requestedBaseAmount);

       self.positions[positionId].baseAmount += requestedBaseAmount;
       
        return requestedBaseAmount;
    }

    function getAccountFilledBalances(
        Data storage self,
        uint128 marketId,
        uint256 maturityTimestamp,
        address accountId
    )
        internal
        returns (int256 baseBalancePool, int256 quoteBalancePool) {
        
        require(self.supportedMaturities[maturityTimestamp], "Maturity not supported");

        uint256 numPositions = self.positionsInAccount[accountId].length;

        DatedIrsVamm.Data storage vamm = DatedIrsVamm.loadByMaturityAndMarket(marketId, maturityTimestamp);
        for (uint256 i = 0; i <= numPositions; i++) {
            Position memory position = getRawPosition(self, self.positionsInAccount[accountId][i].id, vamm);

            baseBalancePool += position.tracker0Accumulated;
            quoteBalancePool += position.tracker1Accumulated;
        }

    }

    function getAccountUnfilledBases(
        Data storage self,
        uint128 marketId,
        uint256 maturityTimestamp,
        address accountId
    )
        internal
        returns (int256 unfilledBaseLong, int256 unfilledBaseShort)
    {
        
        require(self.supportedMaturities[maturityTimestamp], "Maturity not supported");

        uint256 numPositions = self.positionsInAccount[accountId].length;
        if (numPositions != 0) {
            DatedIrsVamm.Data storage vamm = DatedIrsVamm.loadByMaturityAndMarket(marketId, maturityTimestamp);

            for (uint256 i = 0; i <= numPositions; i++) {
                Position memory position = getRawPosition(self, self.positionsInAccount[accountId][i].id, vamm);

                (int256 unfilledLong,, int256 unfilledShort,) = vamm.trackValuesBetweenTicks(
                    position.tickLower,
                    position.tickUpper,
                    position.baseAmount
                );

                unfilledBaseLong += unfilledLong;
                unfilledBaseShort += unfilledShort;
            }
        }
    }

    /**
     * @notice It opens a position and returns positionId
     */
    function openPosition(
        Data storage self,
        address accountId,
        int24 tickLower,
        int24 tickUpper
    )
        internal
        returns (uint256){

        uint256 positionId = uint256(keccak256(abi.encodePacked(accountId, tickLower, tickUpper)));

        if(self.positions[positionId].id == 0) {
            return positionId;
        }

        self.positions[positionId].accountId = accountId;
        self.positions[positionId].tickLower = tickLower;
        self.positions[positionId].tickUpper = tickUpper;

        self.positionsInAccount[accountId].push(self.positions[positionId]);

        return positionId;
    }

    function getRawPosition(
        Data storage self,
        uint256 positionId,
        DatedIrsVamm.Data storage vamm
    )
        internal
        returns (Position memory) {

        require(self.positions[positionId].id != 0, "Missing position");
        
        propagatePosition(self, positionId, vamm);
        return self.positions[positionId];
    }

    function propagatePosition(
        Data storage self,
        uint256 positionId,
        DatedIrsVamm.Data storage vamm
    )
        internal {

        Position memory position = self.positions[positionId];

        (int256 tracker0GlobalGrowth, int256 tracker1GlobalGrowth) = 
            vamm.growthBetweenTicks(position.tickLower, position.tickUpper);

        int256 tracket0DeltaGrowth =
                tracker0GlobalGrowth - position.tracker0UpdatedGrowth;
        int256 tracket1DeltaGrowth =
                tracker1GlobalGrowth - position.tracker1UpdatedGrowth;

        int256 averageBase = DatedIrsVamm.getAverageBase(
            position.tickLower,
            position.tickUpper,
            position.baseAmount
        );

        self.positions[positionId].tracker0UpdatedGrowth = tracker0GlobalGrowth;
        self.positions[positionId].tracker1UpdatedGrowth = tracker1GlobalGrowth;
        self.positions[positionId].tracker0Accumulated += tracket0DeltaGrowth * averageBase;
        self.positions[positionId].tracker1Accumulated += tracker1GlobalGrowth * averageBase;
    }

            
}
