// SPDX-License-Identifier: BUSL-1.1

pragma solidity >=0.8.13;

import "./LiquidityMath.sol";
import "./TickMath.sol";

import "@voltz-protocol/util-contracts/src/helpers/SafeCast.sol";

/// @title Tick
/// @notice Contains functions for managing tick processes and relevant calculations
library Tick {
    using SafeCastI256 for int256;
    using SafeCastU256 for uint256;

    int24 internal constant MAXIMUM_TICK_SPACING = 16384;

    // info stored for each initialized individual tick
    struct Info {
        /// @dev the total per-tick liquidity that references this tick (either as tick lower or tick upper)
        uint128 liquidityGross;
        /// @dev amount of per-tick liquidity added (subtracted) when tick is crossed from left to right (right to left),
        int128 liquidityNet;
        /// @dev growth per unit of liquidity on the _other_ side of this tick (relative to the current tick)
        /// @dev only has relative meaning, not absolute — the value depends on when the tick is initialized
        int256 trackerQuoteTokenGrowthOutsideX128;
        int256 trackerBaseTokenGrowthOutsideX128;
        /// @dev true iff the tick is initialized, i.e. the value is exactly equivalent to the expression liquidityGross != 0
        /// @dev these 8 bits are set to prevent fresh sstores when crossing newly initialized ticks
        bool initialized;
    }

    function _getGrowthInside(
        int24 _tickLower,
        int24 _tickUpper,
        int24 _tickCurrent,
        int256 _growthGlobalX128,
        int256 _lowerGrowthOutsideX128,
        int256 _upperGrowthOutsideX128
    ) private pure returns (int256) {
        // calculate the growth below
        int256 _growthBelowX128;

        if (_tickCurrent >= _tickLower) {
            _growthBelowX128 = _lowerGrowthOutsideX128;
        } else {
            _growthBelowX128 = _growthGlobalX128 - _lowerGrowthOutsideX128;
        }

        // calculate the growth above
        int256 _growthAboveX128;

        if (_tickCurrent < _tickUpper) {
            _growthAboveX128 = _upperGrowthOutsideX128;
        } else {
            _growthAboveX128 = _growthGlobalX128 - _upperGrowthOutsideX128;
        }

        int256 _growthInsideX128;

        _growthInsideX128 =
            _growthGlobalX128 -
            (_growthBelowX128 + _growthAboveX128);

        return _growthInsideX128;
    }

    struct BaseTokenGrowthInsideParams {
        int24 tickLower;
        int24 tickUpper;
        int24 tickCurrent;
        int256 baseTokenGrowthGlobalX128;
    }

    function getBaseTokenGrowthInside(
        mapping(int24 => Tick.Info) storage self,
        BaseTokenGrowthInsideParams memory params
    ) internal view returns (int256 baseTokenGrowthInsideX128) {
        Info storage lower = self[params.tickLower];
        Info storage upper = self[params.tickUpper];

        baseTokenGrowthInsideX128 = _getGrowthInside(
            params.tickLower,
            params.tickUpper,
            params.tickCurrent,
            params.baseTokenGrowthGlobalX128,
            lower.trackerBaseTokenGrowthOutsideX128,
            upper.trackerBaseTokenGrowthOutsideX128
        );
    }

    struct QuoteTokenGrowthInsideParams {
        int24 tickLower;
        int24 tickUpper;
        int24 tickCurrent;
        int256 quoteTokenGrowthGlobalX128;
    }

    function getQuoteTokenGrowthInside(
        mapping(int24 => Tick.Info) storage self,
        QuoteTokenGrowthInsideParams memory params
    ) internal view returns (int256 quoteTokenGrowthInsideX128) {
        Info storage lower = self[params.tickLower];
        Info storage upper = self[params.tickUpper];

        // do we need an unchecked block in here (given we are dealing with an int256)?
        quoteTokenGrowthInsideX128 = _getGrowthInside(
            params.tickLower,
            params.tickUpper,
            params.tickCurrent,
            params.quoteTokenGrowthGlobalX128,
            lower.trackerQuoteTokenGrowthOutsideX128,
            upper.trackerQuoteTokenGrowthOutsideX128
        );
    }

    /// @notice Updates a tick and returns true if the tick was flipped from initialized to uninitialized, or vice versa
    /// @param self The mapping containing all tick information for initialized ticks
    /// @param tick The tick that will be updated
    /// @param tickCurrent The current tick
    /// @param liquidityDelta A new amount of liquidity to be added (subtracted) when tick is crossed from left to right (right to left)
    /// @param quoteTokenGrowthGlobalX128 The quote token growth accumulated per unit of liquidity for the entire life of the vamm
    /// @param baseTokenGrowthGlobalX128 The variable token growth accumulated per unit of liquidity for the entire life of the vamm
    /// @param upper true for updating a position's upper tick, or false for updating a position's lower tick
    /// @param maxLiquidity The maximum liquidity allocation for a single tick
    /// @return flipped Whether the tick was flipped from initialized to uninitialized, or vice versa
    function update(
        mapping(int24 => Tick.Info) storage self,
        int24 tick,
        int24 tickCurrent,
        int128 liquidityDelta,
        int256 quoteTokenGrowthGlobalX128,
        int256 baseTokenGrowthGlobalX128,
        bool upper,
        uint128 maxLiquidity
    ) internal returns (bool flipped) {
        Tick.Info storage info = self[tick];

        uint128 liquidityGrossBefore = info.liquidityGross;
        require(
            int128(info.liquidityGross) + liquidityDelta >= 0,
            "not enough liquidity to burn"
        );
        uint128 liquidityGrossAfter = LiquidityMath.addDelta(
            liquidityGrossBefore,
            liquidityDelta
        );

        require(liquidityGrossAfter <= maxLiquidity, "LO");

        flipped = (liquidityGrossAfter == 0) != (liquidityGrossBefore == 0);

        if (liquidityGrossBefore == 0) {
            // by convention, we assume that all growth before a tick was initialized happened _below_ the tick
            if (tick <= tickCurrent) {

                info.trackerQuoteTokenGrowthOutsideX128 = quoteTokenGrowthGlobalX128;

                info
                    .trackerBaseTokenGrowthOutsideX128 = baseTokenGrowthGlobalX128;
            }

            info.initialized = true;
        }

        /// check shouldn't we unintialize the tick if liquidityGrossAfter = 0?

        info.liquidityGross = liquidityGrossAfter;

        /// add comments
        // when the lower (upper) tick is crossed left to right (right to left), liquidity must be added (removed)
        info.liquidityNet = upper
            ? info.liquidityNet - liquidityDelta
            : info.liquidityNet + liquidityDelta;
    }

    /// @notice Clears tick data
    /// @param self The mapping containing all initialized tick information for initialized ticks
    /// @param tick The tick that will be cleared
    function clear(mapping(int24 => Tick.Info) storage self, int24 tick)
        internal
    {
        delete self[tick];
    }

    /// @notice Transitions to next tick as needed by price movement
    /// @param self The mapping containing all tick information for initialized ticks
    /// @param tick The destination tick of the transition
    /// @param quoteTokenGrowthGlobalX128 The quote token growth accumulated per unit of liquidity for the entire life of the vamm
    /// @param baseTokenGrowthGlobalX128 The variable token growth accumulated per unit of liquidity for the entire life of the vamm
    /// @return liquidityNet The amount of liquidity added (subtracted) when tick is crossed from left to right (right to left)
    function cross(
        mapping(int24 => Tick.Info) storage self,
        int24 tick,
        int256 quoteTokenGrowthGlobalX128,
        int256 baseTokenGrowthGlobalX128
    ) internal returns (int128 liquidityNet) {
        Tick.Info storage info = self[tick];

        info.trackerQuoteTokenGrowthOutsideX128 =
            quoteTokenGrowthGlobalX128 -
            info.trackerQuoteTokenGrowthOutsideX128;

        info.trackerBaseTokenGrowthOutsideX128 =
            baseTokenGrowthGlobalX128 -
            info.trackerBaseTokenGrowthOutsideX128;

        liquidityNet = info.liquidityNet;
    }
}
