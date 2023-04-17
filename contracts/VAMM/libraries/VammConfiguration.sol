//SPDX-License-Identifier: MIT
pragma solidity >=0.8.13;

import { UD60x18 } from "@prb/math/src/UD60x18.sol";
import "../../interfaces/IRateOracle.sol";
import "../interfaces/IVAMMBase.sol";
import "./Oracle.sol";

/**
 * @title Tracks configurations for dated irs markets
 */
library VammConfiguration {

    struct PriceConfig {
        /// @dev the phi value to use when adjusting a TWAP price for the likely price impact of liquidation
        UD60x18 priceImpactPhi;
        /// @dev the beta value to use when adjusting a TWAP price for the likely price impact of liquidation
        UD60x18 priceImpactBeta;
        /// @dev the spread taken by LPs on each trade. As decimal number where 1 = 100%. E.g. 0.003 means that the spread is 0.3% of notional
        UD60x18 spread;
    }

    struct VammConfig {
        /**
         * @dev Numeric identifier for the vamm. Must be unique.
         * @dev There cannot be a vamm with id zero (See `load()`). Id zero is used as a null vamm reference.
         */
        uint256 vammId;
        /**
         * Note: maybe we can find a better way of identifying a market than just a simple id
         */
        uint128 marketId;
        /// @dev UNIX timestamp in seconds marking swap maturity
        uint256 maturityTimestamp;
        /// @dev Maximun liquidity amount per tick
        uint128 _maxLiquidityPerTick;
        /// @dev Granularity of ticks
        int24 _tickSpacing;
        /// @dev rate oracle from which the vamm extracts the liquidity index
        IRateOracle rateOracle;
        /// @dev VAMM price config
        PriceConfig priceConfig;
    }

    /// @dev frequently-updated state of the VAMM
    struct VammState {
        /// @dev The current price of the pool as a sqrt(trackerBaseToken/trackerVariableToken) Q64.96 value
        uint160 sqrtPriceX96;
        /// @dev The current tick of the vamm, i.e. according to the last tick transition that was run.
        int24 tick;
        // the most-recently updated index of the observations array
        uint16 observationIndex;
        // the current maximum number of observations that are being stored
        uint16 observationCardinality;
        // the next maximum number of observations to store, triggered in observations.write
        uint16 observationCardinalityNext;
        /// Circular buffer of Oracle Observations. Resizable but no more than type(uint16).max slots in the buffer
        Oracle.Observation[65535] observations;
        // whether the pool is locked
        bool unlocked;
        /// @dev Maps from an account address to a list of the position IDs of positions associated with that account address. Use the `positions` mapping to see full details of any given `LPPosition`.
        mapping(uint128 => uint128[]) positionsInAccount;
        /// @dev total liquidity in VAMM
        uint128 accumulator;
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
