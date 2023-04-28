//SPDX-License-Identifier: MIT
pragma solidity >=0.8.13;

import "./Tick.sol";

import { UD60x18 } from "@prb/math/UD60x18.sol";

import "../Oracle.sol";
import "../interfaces/IRateOracle.sol";

/**
 * @title Tracks configurations for dated irs markets
 */
library VammConfiguration {

    struct Mutable {
        /// @dev the phi value to use when adjusting a TWAP price for the likely price impact of liquidation
        UD60x18 priceImpactPhi;
        /// @dev the beta value to use when adjusting a TWAP price for the likely price impact of liquidation
        UD60x18 priceImpactBeta;
        /// @dev the spread taken by LPs on each trade. As decimal number where 1 = 100%. E.g. 0.003 means that the spread is 0.3% of notional
        UD60x18 spread;
        /// @dev rate oracle from which the vamm extracts the liquidity index
        IRateOracle rateOracle;
    }

    struct Immutable {
        /// @dev UNIX timestamp in seconds marking swap maturity
        uint256 maturityTimestamp;
        /// @dev Maximun liquidity amount per tick
        uint128 _maxLiquidityPerTick;
        /// @dev Granularity of ticks
        int24 _tickSpacing;
    }

    /// @dev frequently-updated state of the VAMM
    struct State {
        /**
         * @dev do not rearrange storage from sqrtPriceX96 to unlocked including.
         * It is arranged on purpose to for one single storage slot.
         */

        // the current price of the pool as a sqrt(trackerBaseToken/trackerVariableToken) Q64.96 value
        uint160 sqrtPriceX96;
        // the current tick of the vamm, i.e. according to the last tick transition that was run.
        int24 tick;
        // the most-recently updated index of the observations array
        uint16 observationIndex;
        // the current maximum number of observations that are being stored
        uint16 observationCardinality;
        // the next maximum number of observations to store, triggered in observations.write
        uint16 observationCardinalityNext;
        // whether the pool is locked
        bool unlocked;

        /// Circular buffer of Oracle Observations. Resizable but no more than type(uint16).max slots in the buffer
        Oracle.Observation[65535] observations;
        /// @dev Maps from an account address to a list of the position IDs of positions associated with that account address. Use the `positions` mapping to see full details of any given `LPPosition`.
        mapping(uint128 => uint128[]) positionsInAccount;
        /// @notice The currently in range liquidity available to the pool
        /// @dev This value has no relationship to the total liquidity across all ticks
        uint128 liquidity;
        /// @dev total amount of variable tokens in vamm
        int256 trackerVariableTokenGrowthGlobalX128;
        /// @dev total amount of base tokens in vamm
        int256 trackerBaseTokenGrowthGlobalX128;
        /// @dev map from tick to tick info
        mapping(int24 => Tick.Info) _ticks;
        /// @dev map from tick to tick bitmap
        mapping(int16 => uint256) _tickBitmap;
    }
}
