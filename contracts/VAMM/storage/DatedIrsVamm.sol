// SPDX-License-Identifier: MIT
pragma solidity >=0.8.13;

import "../../utils/AccessError.sol";
import "../interfaces/IVAMMBase.sol";
import "../libraries/Tick.sol";
import "../libraries/Tick.sol";
import "../libraries/TickBitmap.sol";
import "../../utils/SafeCastUni.sol";
import "../../utils/SqrtPriceMath.sol";
import "../libraries/SwapMath.sol";
import { UD60x18, convert } from "@prb/math/src/UD60x18.sol";
import { SD59x18, convert } from "@prb/math/src/SD59x18.sol";
import "../libraries/FixedAndVariableMath.sol";
import "../../utils/FixedPoint128.sol";
import "../libraries/VAMMBase.sol";
import "../interfaces/IVAMMBase.sol";
import "../interfaces/IVAMM.sol";
import "../../utils/CustomErrors.sol";
import "../libraries/Oracle.sol";
import "../../interfaces/IRateOracle.sol";
import "forge-std/console2.sol";

/**
 * @title Connects external contracts that implement the `IVAMM` interface to the protocol.
 *
 */
library DatedIrsVamm {

    UD60x18 constant ONE = UD60x18.wrap(1e18);
    UD60x18 constant ZERO = UD60x18.wrap(0);
    using SafeCastUni for uint256;
    using SafeCastUni for int256;
    using VAMMBase for VAMMBase.FlipTicksParams;
    using VAMMBase for bool;
    using Tick for mapping(int24 => Tick.Info);
    using TickBitmap for mapping(int16 => uint256);
    using Oracle for Oracle.Observation[65535];

     /// @dev Returns the block timestamp truncated to 32 bits, i.e. mod 2**32
    function _blockTimestamp() internal view returns (uint32) {
        return uint32(block.timestamp); // truncation is desired
    }

    /// @notice Emitted by the pool for increases to the number of observations that can be stored
    /// @dev observationCardinalityNext is not the observation cardinality until an observation is written at the index
    /// just before a mint/swap/burn.
    /// @param observationCardinalityNextOld The previous value of the next observation cardinality
    /// @param observationCardinalityNextNew The updated value of the next observation cardinality
    event IncreaseObservationCardinalityNext(
        uint16 observationCardinalityNextOld,
        uint16 observationCardinalityNextNew
    );

    /**
     * @dev Thrown when a specified vamm is not found.
     */
    error IRSVammNotFound(uint128 vammId);

    struct LPPosition { // TODO: consider moving Position and the operations affecting Positions into a separate library for readbaility
        uint128 accountId;
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
        int256 trackerVariableTokenUpdatedGrowth;
        /** 
        * @dev variable token growth per unit of liquidity as of the last update to liquidity or fixed/variable token balance
        */
        int256 trackerBaseTokenUpdatedGrowth;
        /** 
        * @dev current Fixed Token balance of the position, 1 fixed token can be redeemed for 1% APY * (annualised amm term) at the maturity of the amm
        * assuming 1 token worth of notional "deposited" in the underlying pool at the inception of the amm
        * can be negative/positive/zero
        */
        int256 trackerVariableTokenAccumulated;
        /** 
        * @dev current Variable Token Balance of the position, 1 variable token can be redeemed for underlyingPoolAPY*(annualised amm term) at the maturity of the amm
        * assuming 1 token worth of notional "deposited" in the underlying pool at the inception of the amm
        * can be negative/positive/zero
        */
        int256 trackerBaseTokenAccumulated;
    }

    /// @dev Mutable (or maybe one day mutable, perahps through governance) Config for this VAMM
    struct Config {
        /// @dev the phi value to use when adjusting a TWAP price for the likely price impact of liquidation
        UD60x18 priceImpactPhi;
        /// @dev the beta value to use when adjusting a TWAP price for the likely price impact of liquidation
        UD60x18 priceImpactBeta;
        /// @dev the spread taken by LPs on each trade. As decimal number where 1 = 100%. E.g. 0.003 means that the spread is 0.3% of notional
        UD60x18 spread;
        /// @dev the spread taken by LPs on each trade. As decimal number where 1 = 100%. E.g. 0.003 means that the spread is 0.3% of notional
        IRateOracle rateOracle;
    }

    struct Data {
        /// @inheritdoc IVAMMBase
        IVAMMBase.VAMMVars _vammVars;
        /**
         * @dev Numeric identifier for the vamm. Must be unique.
         * @dev There cannot be a vamm with id zero (See `load()`). Id zero is used as a null vamm reference.
         */
        uint256 id;
        /**
         * Note: maybe we can find a better way of identifying a market than just a simple id
         */
        uint128 marketId;
        /**
         * @dev Maps from position ID (see `getPositionId` to the properties of that position
         */
        mapping(uint256 => LPPosition) positions;
        /**
         * @dev Maps from an account address to a list of the position IDs of positions associated with that account address. Use the `positions` mapping to see full details of any given `LPPosition`.
         */
        mapping(uint128 => uint256[]) positionsInAccount;
        uint256 termEndTimestamp;
        uint128 _maxLiquidityPerTick;
        int24 _tickSpacing;
        Config config;
        uint128 _accumulator;
        int256 _trackerVariableTokenGrowthGlobalX128;
        int256 _trackerBaseTokenGrowthGlobalX128;
        mapping(int24 => Tick.Info) _ticks;
        mapping(int16 => uint256) _tickBitmap;

        /// Circular buffer of Oracle Observations. Resizable but no more than type(uint16).max slots in the buffer
        Oracle.Observation[65535] observations;
    }

    /**
     * @dev Returns the vamm stored at the specified vamm id.
     */
    function load(uint256 id) internal pure returns (Data storage irsVamm) {
        require(id != 0); // TODO: custom error
        bytes32 s = keccak256(abi.encode("xyz.voltz.DatedIRSVamm", id));
        assembly {
            irsVamm.slot := s
        }
    }

    /**
     * @dev Finds the vamm id using market id and maturity and
     * returns the vamm stored at the specified vamm id. Reverts if no such VAMM is found.
     */
    function loadByMaturityAndMarket(uint128 marketId, uint256 maturityTimestamp) internal view returns (Data storage irsVamm) {
        uint256 id = uint256(keccak256(abi.encodePacked(marketId, maturityTimestamp)));
        irsVamm = load(id);
        if (irsVamm.termEndTimestamp == 0) {
            revert CustomErrors.MarketAndMaturityCombinaitonNotSupported(marketId, maturityTimestamp);
        }
    }

    /**
     * @dev Finds the vamm id using market id and maturity and
     * returns the vamm stored at the specified vamm id. Reverts if no such VAMM is found.
     */
    function create(uint128 _marketId, uint256 _maturityTimestamp,  uint160 _sqrtPriceX96, int24 _tickSpacing, Config memory _config) internal returns (Data storage irsVamm) {
        if (_maturityTimestamp == 0) {
            revert CustomErrors.MaturityMustBeInFuture(block.timestamp, _maturityTimestamp);
        }
        uint256 id = uint256(keccak256(abi.encodePacked(_marketId, _maturityTimestamp)));
        irsVamm = load(id);
        if (irsVamm.termEndTimestamp != 0) {
            revert CustomErrors.MarketAndMaturityCombinaitonAlreadyExists(_marketId, _maturityTimestamp);
        }

        // tick spacing is capped at 16384 to prevent the situation where tickSpacing is so large that
        // TickBitmap#nextInitializedTickWithinOneWord overflows int24 container from a valid tick
        // 16384 ticks represents a >5x price change with ticks of 1 bips
        require(_tickSpacing > 0 && _tickSpacing < Tick.MAXIMUM_TICK_SPACING, "TSOOB");

        initialize(irsVamm, _sqrtPriceX96, _maturityTimestamp, _marketId, _tickSpacing, _config);
    }

    /// @dev not locked because it initializes unlocked
    function initialize(Data storage self, uint160 sqrtPriceX96, uint256 _termEndTimestamp, uint128 _marketId, int24 _tickSpacing, Config memory _config) internal {
        if (sqrtPriceX96 == 0) {
            revert CustomErrors.ExpectedNonZeroSqrtPriceForInit(sqrtPriceX96);
        }
        if (self._vammVars.sqrtPriceX96 != 0) {
            revert CustomErrors.ExpectedSqrtPriceZeroBeforeInit(self._vammVars.sqrtPriceX96);
        }
        if (_termEndTimestamp <= block.timestamp) {
            revert CustomErrors.MaturityMustBeInFuture(block.timestamp, _termEndTimestamp);
        }

        int24 tick = TickMath.getTickAtSqrtRatio(sqrtPriceX96);

        self.marketId = _marketId;
        self.termEndTimestamp = _termEndTimestamp;
        self._tickSpacing = _tickSpacing;

        self._maxLiquidityPerTick = Tick.tickSpacingToMaxLiquidityPerTick(_tickSpacing);

        (uint16 cardinality, uint16 cardinalityNext) = self.observations.initialize(_blockTimestamp());

        self._vammVars = IVAMMBase.VAMMVars({
            sqrtPriceX96: sqrtPriceX96,
            tick: tick,
            observationIndex: 0,
            observationCardinality: cardinality,
            observationCardinalityNext: cardinalityNext,
            feeProtocol: 0,
            unlocked: true
        });

        configure(self, _config);
    }

    /// @notice Calculates time-weighted geometric mean price based on the past `secondsAgo` seconds
    /// @param secondsAgo Number of seconds in the past from which to calculate the time-weighted means
    /// @param orderSize The order size to use when adjusting the price for price impact or spread. Must not be zero if either of the boolean params is true because it used to indicate the direction of the trade and therefore the direction of the adjustment. Function will revert if `abs(orderSize)` overflows when cast to a `U60x18`
    /// @param adjustForPriceImpact Whether or not to adjust the returned price by the VAMM's configured spread.
    /// @param adjustForSpread Whether or not to adjust the returned price by the VAMM's configured spread.
    /// @return geometricMeanPrice The geometric mean price, which might be adjusted according to input parameters. May return zero if adjustments would take the price to or below zero - e.g. when anticipated price impact is large because the order size is large.
    function twap(Data storage self, uint32 secondsAgo, int256 orderSize, bool adjustForPriceImpact,  bool adjustForSpread)
        internal
        view
        returns (UD60x18 geometricMeanPrice)
    {
        int24 arithmeticMeanTick = observe(self, secondsAgo);

        // Not yet adjusted
        geometricMeanPrice = VAMMBase.getPriceFromTick(arithmeticMeanTick);
        UD60x18 spreadImpactDelta = ZERO;
        UD60x18 priceImpactAsFraction = ZERO;

        if (adjustForSpread) {
            require(orderSize != 0); // TODO: custom error
            spreadImpactDelta = self.config.spread;
        }

        if (adjustForPriceImpact) {
            require(orderSize != 0); // TODO: custom error
            priceImpactAsFraction = self.config.priceImpactPhi.mul(convert(uint256(orderSize > 0 ? orderSize : -orderSize)).pow(self.config.priceImpactBeta));
        }

        // The projected price impact and spread of a trade will move the price up for buys, down for sells
        if (orderSize > 0) {
            geometricMeanPrice = geometricMeanPrice.add(spreadImpactDelta).mul(ONE.add(priceImpactAsFraction));
        } else {
            if (spreadImpactDelta.gte(geometricMeanPrice)) {
                // The spread is higher than the price
                return ZERO;
            }
            if (priceImpactAsFraction.gte(ONE)) {
                // The model suggests that the price will drop below zero after price impact
                return ZERO;
            }
            geometricMeanPrice = geometricMeanPrice.sub(spreadImpactDelta).mul(ONE.sub(priceImpactAsFraction));
        }

        return geometricMeanPrice;
    }

    /// @notice Calculates time-weighted arithmetic mean tick
    /// @param secondsAgo Number of seconds in the past from which to calculate the time-weighted means
    function observe(Data storage self, uint32 secondsAgo)
        internal
        view
        returns (int24 arithmeticMeanTick)
    {
        if (secondsAgo == 0) {
            // return the current tick if secondsAgo == 0
            arithmeticMeanTick = self._vammVars.tick;
        } else {
            uint32[] memory secondsAgos = new uint32[](2);
            secondsAgos[0] = secondsAgo;
            secondsAgos[1] = 0;

            (int56[] memory tickCumulatives,) =
                observe(self, secondsAgos);

            int56 tickCumulativesDelta = tickCumulatives[1] - tickCumulatives[0];
            arithmeticMeanTick = int24(tickCumulativesDelta / int56(uint56(secondsAgo)));

            // Always round to negative infinity
            if (tickCumulativesDelta < 0 && (tickCumulativesDelta % int56(uint56(secondsAgo)) != 0)) arithmeticMeanTick--;
        }
    }

    /// @notice Returns the cumulative tick and liquidity as of each timestamp `secondsAgo` from the current block timestamp
    /// @dev To get a time weighted average tick or liquidity-in-range, you must call this with two values, one representing
    /// the beginning of the period and another for the end of the period. E.g., to get the last hour time-weighted average tick,
    /// you must call it with secondsAgos = [3600, 0].
    /// @dev The time weighted average tick represents the geometric time weighted average price of the pool, in
    /// log base sqrt(1.0001) of token1 / token0. The TickMath library can be used to go from a tick value to a ratio.
    /// @param secondsAgos From how long ago each cumulative tick and liquidity value should be returned
    /// @return tickCumulatives Cumulative tick values as of each `secondsAgos` from the current block timestamp
    /// @return secondsPerLiquidityCumulativeX128s Cumulative seconds per liquidity-in-range value as of each `secondsAgos` from the current block
    /// timestamp
    function observe(
        Data storage self,
        uint32[] memory secondsAgos)
        internal
        view
        returns (int56[] memory tickCumulatives, uint160[] memory secondsPerLiquidityCumulativeX128s)
    {
        return
            self.observations.observe(
                _blockTimestamp(),
                secondsAgos,
                self._vammVars.tick,
                self._vammVars.observationIndex,
                0, // liquidity is untracked
                self._vammVars.observationCardinality
            );
    }

    /// @notice Increase the maximum number of price and liquidity observations that this pool will store
    /// @dev This method is no-op if the pool already has an observationCardinalityNext greater than or equal to
    /// the input observationCardinalityNext.
    /// @param observationCardinalityNext The desired minimum number of observations for the pool to store
    function increaseObservationCardinalityNext(Data storage self, uint16 observationCardinalityNext)
        internal
    {
        self._vammVars.unlocked.lock();
        uint16 observationCardinalityNextOld =  self._vammVars.observationCardinalityNext; // for the event
        uint16 observationCardinalityNextNew =  self.observations.grow(
            observationCardinalityNextOld,
            observationCardinalityNext
        );
         self._vammVars.observationCardinalityNext = observationCardinalityNextNew;
        if (observationCardinalityNextOld != observationCardinalityNextNew)
            emit IncreaseObservationCardinalityNext(observationCardinalityNextOld, observationCardinalityNextNew);
                self._vammVars.unlocked.unlock();

    }

    /**
     * @notice Executes a dated maker order that provides liquidity this VAMM
     * @param accountId Id of the `Account` with which the lp wants to provide liqudiity
     * @param fixedRateLower Lower Fixed Rate of the range order
     * @param fixedRateUpper Upper Fixed Rate of the range order
     * @param requestedBaseAmount Requested amount of notional provided to a given vamm in terms of the virtual base tokens of the
     * market
     * @param executedBaseAmount Executed amount of notional provided to a given vamm in terms of the virtual base tokens of the
     * market
     */
    function executeDatedMakerOrder(
        Data storage self,
        uint128 accountId,
        uint160 fixedRateLower,
        uint160 fixedRateUpper,
        int128 requestedBaseAmount
    )
        internal
        returns (int256 executedBaseAmount){
        
        int24 tickLower = TickMath.getTickAtSqrtRatio(fixedRateUpper);
        int24 tickUpper = TickMath.getTickAtSqrtRatio(fixedRateLower);

        uint256 positionId = openPosition(self, accountId, tickLower, tickUpper);

        LPPosition memory position = getRawPosition(self, positionId);

        require(position.baseAmount + requestedBaseAmount >= 0, "Burning too much"); // TODO: CustomError

        _vammMint(self, accountId, tickLower, tickUpper, requestedBaseAmount);

        self.positions[positionId].baseAmount += requestedBaseAmount;
       
        return requestedBaseAmount;
    }

    /**
     * @notice It opens a position and returns positionId
     */
    function openPosition(
        Data storage self,
        uint128 accountId,
        int24 tickLower,
        int24 tickUpper
    ) 
        internal
        returns (uint256){

        uint256 positionId = getPositionId(accountId, tickLower, tickUpper);

        if(self.positions[positionId].accountId != 0) {
            return positionId;
        }

        self.positions[positionId].accountId = accountId;
        self.positions[positionId].tickLower = tickLower;
        self.positions[positionId].tickUpper = tickUpper;

        self.positionsInAccount[accountId].push(positionId);

        return positionId;
    }

    function getRawPosition(
        Data storage self,
        uint256 positionId
    )
        internal
        returns (LPPosition memory) {

        // Account zero is not a valid account. (See `Account.create()`)
        require(self.positions[positionId].accountId != 0, "Missing position"); // TODO: custom error
        
        _propagatePosition(self, positionId);
        return self.positions[positionId];
    }

    /// @dev Private but labelled internal for testability.
    function _propagatePosition(
        Data storage self,
        uint256 positionId
    )
        internal {

        LPPosition memory position = self.positions[positionId];

        (int256 trackerVariableTokenGlobalGrowth, int256 trackerBaseTokenGlobalGrowth) = 
            growthBetweenTicks(self, position.tickLower, position.tickUpper);

        int256 trackerVariableTokenDeltaGrowth =
                trackerVariableTokenGlobalGrowth - position.trackerVariableTokenUpdatedGrowth;
        int256 trackerBaseTokenDeltaGrowth =
                trackerBaseTokenGlobalGrowth - position.trackerBaseTokenUpdatedGrowth;

        int256 averageBase = VAMMBase.basePerTick(
            position.tickLower,
            position.tickUpper,
            position.baseAmount
        );

        self.positions[positionId].trackerVariableTokenUpdatedGrowth = trackerVariableTokenGlobalGrowth;
        self.positions[positionId].trackerBaseTokenUpdatedGrowth = trackerBaseTokenGlobalGrowth;
        self.positions[positionId].trackerVariableTokenAccumulated += trackerVariableTokenDeltaGrowth * averageBase;
        self.positions[positionId].trackerBaseTokenAccumulated += trackerBaseTokenDeltaGrowth * averageBase;
    }

    /**
     * @notice Returns the positionId that such a position would have, shoudl it exist. Does not check for existence.
     */
    function getPositionId(
        uint128 accountId,
        int24 tickLower,
        int24 tickUpper
    )
        public
        pure
        returns (uint256){

        return uint256(keccak256(abi.encodePacked(accountId, tickLower, tickUpper)));
    }

    function configure(
        Data storage self,
        Config memory _config) internal {

        // TODO: sanity check config - e.g. price impact calculated must never be >= 1

        self.config = _config;
    }

    /// @dev Private but labelled internal for testability.
    ///
    /// @dev Calculate `fixedTokens` for (some tick range that has uniform liquidity within) a trade. The calculation relies
    /// on the trade being uniformly distributed across the specified tick range in order to calculate the average price (the fixedAPY), so this
    /// assumption must hold or the math will break. As such, the function can only really be useed to calculate `fixedTokens` for a subset of a trade,
    ///
    /// Thinking about cashflows from first principles, the cashflow of an IRS at time `x` (`x < maturityTimestamp`) is:
    ///  (1)  `cashflow[x] = notional * (variableAPYBetween[tradeDate, x] - fixedAPY) * timeInYearsBetween[tradeDate, x]`   
    /// We use liquidity indices to track variable rates, such that
    ///  (2)  `variableAPYBetween[tradeDate, x] * timeInYearsBetween[tradeDate, x] = (liquidityIndex[x] / liquidityIndex[tradeDate]) - 1     
    /// We can therefore rearrange (1) as:
    ///       `cashflow[x] = notional * ((variableAPYBetween[tradeDate, x]*timeInYearsBetween[tradeDate, x]) - (fixedAPY*timeInYearsBetween[tradeDate, x]))`   
    ///       `cashflow[x] = notional * ((liquidityIndex[x] / liquidityIndex[tradeDate]) - 1 - (fixedAPY*timeInYearsBetween[tradeDate, x]))`   
    ///   (3) `cashflow[x] = notional*(liquidityIndex[x] / liquidityIndex[tradeDate]) - notional*(1 + fixedAPY*timeInYearsBetween[tradeDate, x])`
    /// Now if we define:
    ///   `baseTokens:= notional / liquidityIndex[tradeDate]`
    /// then we can further rearrange (3) as:
    ///       `cashflow[x] = baseTokens*liquidityIndex[x] - baseTokens*liquidityIndex[tradeDate]*(1 + fixedAPY*timeInYearsBetween[tradeDate, x])`
    /// And now if we define:
    ///   `fixedTokens:= -baseTokens*liquidityIndex[tradeDate]*(1 + fixedAPY*timeInYearsBetween[tradeDate, maturityTimestamp])
    /// Then we will have simply:
    ///   (4) `cashflow[maturity] = baseTokens*liquidityIndex[maturity] + fixedTokens`
    /// 
    /// In Voltz, `baseTokens` is calculated off-chain based on the desired notional, and is one of the inputs that the smart contracts see when a trade is made.
    ///
    /// The following function helps with the calculation of `fixedTokens`.
    ///
    /// Pluggin in a fixed Rate or 0 and we see that
    ///   `cashflow[x] = baseTokens*liquidityIndex[x] - baseTokens*liquidityIndex[tradeDate]*(1 + fixedAPY*timeInYearsBetween[tradeDate, x])`
    /// now simplifies to:
    ///   `cashflow[x] = baseTokens*liquidityIndex[x] - baseTokens*liquidityIndex[tradeDate]`
    /// which is what we want.
    function _trackFixedTokens(
      Data storage self,
      int256 baseAmount,
      int24 tickLower,
      int24 tickUpper,
      uint256 termEndTimestamp
    )
        internal
        view
        returns (
            int256 trackedValue
        )
    {
        // TODO: cache time factor and rateNow outside this function and pass as param to avoid recalculations
        UD60x18 averagePrice = VAMMBase.averagePriceBetweenTicks(tickLower, tickUpper);
        UD60x18 timeDeltaUntilMaturity = FixedAndVariableMath.accrualFact(termEndTimestamp - block.timestamp); 
        SD59x18 currentOracleValue = VAMMBase.sd59x18(self.config.rateOracle.getCurrentIndex());
        SD59x18 timeComponent = VAMMBase.sd59x18(ONE.add(averagePrice.mul(timeDeltaUntilMaturity))); // (1 + fixedRate * timeInYearsTillMaturity)
        SD59x18 trackedValueDecimal = convert(int256(-baseAmount)).mul(currentOracleValue.mul(timeComponent));
        trackedValue = convert(trackedValueDecimal);
    }

    // TODO: return data
    /// @dev Private but labelled internal for testability. Consumers of the library should use `executeDatedMakerOrder()`.
    /// Mints `baseAmount` of liquidity for the specified `accountId`, uniformly (same amount per-tick) between the specified ticks.
    function _vammMint(
        Data storage self,
        uint128 accountId,
        int24 tickLower,
        int24 tickUpper,
        int128 baseAmount
    ) internal {
        VAMMBase.checkCurrentTimestampTermEndTimestampDelta(self.termEndTimestamp);
        self._vammVars.unlocked.lock();

        Tick.checkTicks(tickLower, tickUpper);

        IVAMMBase.VAMMVars memory lvammVars = self._vammVars; // SLOAD for gas optimization

        bool flippedLower;
        bool flippedUpper;

        int128 averageBase = VAMMBase.basePerTick(tickLower, tickUpper, baseAmount);

        /// @dev update the ticks if necessary
        if (averageBase != 0) {

            VAMMBase.FlipTicksParams memory params;
            params.tickLower = tickLower;
            params.tickLower = tickLower;
            params.accumulatorDelta = averageBase;
            (flippedLower, flippedUpper) = params.flipTicks(
                self._ticks,
                self._tickBitmap,
                self._vammVars,
                self._trackerVariableTokenGrowthGlobalX128,
                self._trackerBaseTokenGrowthGlobalX128,
                self._maxLiquidityPerTick,
                self._tickSpacing
            );
        }

        // clear any tick data that is no longer needed
        if (averageBase < 0) {
            if (flippedLower) {
                self._ticks.clear(tickLower);
            }
            if (flippedUpper) {
                self._ticks.clear(tickUpper);
            }
        }

        if (averageBase != 0) {
            if (
                (lvammVars.tick >= tickLower) && (lvammVars.tick < tickUpper)
            ) {
                // current tick is inside the passed range
                uint128 accumulatorBefore = self._accumulator; // SLOAD for gas optimization

                self._accumulator = LiquidityMath.addDelta(
                    accumulatorBefore,
                    averageBase
                );
            }
        }

        self._vammVars.unlocked.unlock();

        emit VAMMBase.Mint(msg.sender, accountId, tickLower, tickUpper, baseAmount);
    }

    function vammSwap(
        Data storage self,
        IVAMMBase.SwapParams memory params
    )
        internal
        returns (int256 trackerFixedTokenDelta, int256 trackerBaseTokenDelta)
    {
        VAMMBase.checkCurrentTimestampTermEndTimestampDelta(self.termEndTimestamp);

        Tick.checkTicks(params.tickLower, params.tickUpper);

        IVAMMBase.VAMMVars memory vammVarsStart = self._vammVars;

        VAMMBase.checksBeforeSwap(params, vammVarsStart, params.baseAmountSpecified > 0);

        /// @dev lock the vamm while the swap is taking place
        self._vammVars.unlocked.lock();

        uint128 accumulatorStart = self._accumulator;

        VAMMBase.SwapState memory state = VAMMBase.SwapState({
            amountSpecifiedRemaining: params.baseAmountSpecified, // base ramaining
            sqrtPriceX96: vammVarsStart.sqrtPriceX96,
            tick: vammVarsStart.tick,
            accumulator: accumulatorStart,
            trackerFixedTokenGrowthGlobalX128: self._trackerVariableTokenGrowthGlobalX128,
            trackerBaseTokenGrowthGlobalX128: self._trackerBaseTokenGrowthGlobalX128,
            trackerFixedTokenDeltaCumulative: 0, // for Trader (user invoking the swap)
            trackerBaseTokenDeltaCumulative: 0 // for Trader (user invoking the swap)
        });

        // continue swapping as long as we haven't used the entire input/output and haven't reached the price (implied fixed rate) limit
        bool advanceRight = params.baseAmountSpecified > 0;
        while (
            state.amountSpecifiedRemaining != 0 &&
            state.sqrtPriceX96 != params.sqrtPriceLimitX96
        ) {
            VAMMBase.StepComputations memory step;

            ///// GET NEXT TICK /////

            step.sqrtPriceStartX96 = state.sqrtPriceX96;

            /// @dev if isFT (fixed taker) (moving right to left), the nextInitializedTick should be more than or equal to the current tick
            /// @dev if !isFT (variable taker) (moving left to right), the nextInitializedTick should be less than or equal to the current tick
            /// add a test for the statement that checks for the above two conditions
            (step.tickNext, step.initialized) = self._tickBitmap
                .nextInitializedTickWithinOneWord(state.tick, self._tickSpacing, !advanceRight);

            // ensure that we do not overshoot the min/max tick, as the tick bitmap is not aware of these bounds
            if (advanceRight && step.tickNext > TickMath.MAX_TICK) {
                step.tickNext = TickMath.MAX_TICK;
            }
            if (!advanceRight && step.tickNext < TickMath.MIN_TICK) {
                step.tickNext = TickMath.MIN_TICK;
            }
            // get the price for the next tick
            step.sqrtPriceNextX96 = TickMath.getSqrtRatioAtTick(step.tickNext);
            // FT
            uint160 sqrtRatioTargetX96 = step.sqrtPriceNextX96 > params.sqrtPriceLimitX96
                    ? params.sqrtPriceLimitX96
                    : step.sqrtPriceNextX96;
            // VT 
            if(!advanceRight) {
                sqrtRatioTargetX96 = step.sqrtPriceNextX96 < params.sqrtPriceLimitX96
                    ? params.sqrtPriceLimitX96
                    : step.sqrtPriceNextX96;
            }


            ///// GET SWAP RESULTS /////

            // compute values to swap to the target tick, price limit, or point where input/output amount is exhausted
            /// @dev for a Fixed Taker (isFT) if the sqrtPriceNextX96 is larger than the limit, then the target price passed into computeSwapStep is sqrtPriceLimitX96
            /// @dev for a Variable Taker (!isFT) if the sqrtPriceNextX96 is lower than the limit, then the target price passed into computeSwapStep is sqrtPriceLimitX96
            (
                state.sqrtPriceX96,
                step.amountIn,
                step.amountOut
            ) = SwapMath.computeSwapStep(
                SwapMath.SwapStepParams({
                    sqrtRatioCurrentX96: state.sqrtPriceX96,
                    sqrtRatioTargetX96: sqrtRatioTargetX96,
                    liquidity: state.accumulator,
                    amountRemaining: state.amountSpecifiedRemaining,
                    timeToMaturityInSeconds: self.termEndTimestamp - block.timestamp
                })
            );

            ///// UPDATE TRACKERS /////

            if(advanceRight) {
                step.baseInStep -= step.amountIn.toInt256();
                // LP is a Variable Taker
                step.trackerBaseTokenDelta = (step.amountIn).toInt256();
            } else {
                step.baseInStep += step.amountOut.toInt256();
                // LP is a Fixed Taker
                step.trackerBaseTokenDelta -= step.amountOut.toInt256();
            }
            state.amountSpecifiedRemaining += step.baseInStep;

            if (state.accumulator > 0) {
                (
                    state.trackerBaseTokenGrowthGlobalX128,
                    state.trackerFixedTokenGrowthGlobalX128,
                    step.trackerFixedTokenDelta // fixedTokens
                ) = calculateUpdatedGlobalTrackerValues( 
                    self,
                    state,
                    step,
                    self.termEndTimestamp
                );

                state.trackerFixedTokenDeltaCumulative -= step.trackerFixedTokenDelta; // fixedTokens; opposite sign from that of the LP's
                state.trackerBaseTokenDeltaCumulative -= step.trackerBaseTokenDelta; // opposite sign from that of the LP's
            }

            ///// UPDATE TICK AFTER SWAP STEP /////

            // shift tick if we reached the next price
            if (state.sqrtPriceX96 == step.sqrtPriceNextX96) {
                // if the tick is initialized, run the tick transition
                if (step.initialized) {
                    int128 accumulatorNet = self._ticks.cross(
                        step.tickNext,
                        state.trackerFixedTokenGrowthGlobalX128,
                        state.trackerBaseTokenGrowthGlobalX128
                    );

                    state.accumulator = LiquidityMath.addDelta(
                        state.accumulator,
                        advanceRight ? accumulatorNet : -accumulatorNet
                    );

                }

                state.tick = advanceRight ? step.tickNext : step.tickNext - 1;
            } else if (state.sqrtPriceX96 != step.sqrtPriceStartX96) {
                // recompute unless we're on a lower tick boundary (i.e. already transitioned ticks), and haven't moved
                state.tick = TickMath.getTickAtSqrtRatio(state.sqrtPriceX96);
            }
        }

        ///// UPDATE VAMM VARS AFTER SWAP /////
        if (state.tick != vammVarsStart.tick) {
            // update the tick in case it changed
            (uint16 observationIndex, uint16 observationCardinality) = self.observations.write(
                vammVarsStart.observationIndex,
                _blockTimestamp(),
                vammVarsStart.tick,
                0, // Liquidity not currently being tracked
                vammVarsStart.observationCardinality,
                vammVarsStart.observationCardinalityNext
            );
            (self._vammVars.sqrtPriceX96, self._vammVars.tick, self._vammVars.observationIndex, self._vammVars.observationCardinality) = (
                state.sqrtPriceX96,
                state.tick,
                observationIndex,
                observationCardinality
            );
        } else {
            // otherwise just update the price
            self._vammVars.sqrtPriceX96 = state.sqrtPriceX96;
        }

        // update liquidity if it changed
        if (accumulatorStart != state.accumulator) self._accumulator = state.accumulator;

        self._trackerBaseTokenGrowthGlobalX128 = state.trackerBaseTokenGrowthGlobalX128;
        self._trackerVariableTokenGrowthGlobalX128 = state.trackerFixedTokenGrowthGlobalX128;

        trackerFixedTokenDelta = state.trackerFixedTokenDeltaCumulative;
        trackerBaseTokenDelta = state.trackerBaseTokenDeltaCumulative;

        emit VAMMBase.VAMMPriceChange(self._vammVars.tick);

        emit VAMMBase.Swap(
            msg.sender,
            params.tickLower,
            params.tickUpper,
            params.baseAmountSpecified,
            params.sqrtPriceLimitX96,
            trackerFixedTokenDelta,
            trackerBaseTokenDelta
        );

        self._vammVars.unlocked.unlock();
    }


    function calculateUpdatedGlobalTrackerValues( // TODO: flag really-internal somehow, e.g. prefix with underscore
        Data storage self,
        VAMMBase.SwapState memory state,
        VAMMBase.StepComputations memory step,
        uint256 termEndTimestamp
    )
        internal
        view
        returns (
            int256 stateVariableTokenGrowthGlobalX128,
            int256 stateFixedTokenGrowthGlobalX128,
            int256 fixedTokenDelta
        )
    {
        // Get the numder of fixed tokens for the current section of our swap's tick range
        // This calculation assumes that the trade is uniformly distributed within the given tick range, which is only
        // true because there are no changes in liquidity between `state.tick` and `step.tickNext`.
        fixedTokenDelta = _trackFixedTokens(
            self,
            step.baseInStep,
            state.tick,
            step.tickNext,
            termEndTimestamp
        );

        // update global trackers
        stateVariableTokenGrowthGlobalX128 = state.trackerBaseTokenGrowthGlobalX128 + FullMath.mulDivSigned(step.trackerBaseTokenDelta, FixedPoint128.Q128, state.accumulator);
        stateFixedTokenGrowthGlobalX128 = state.trackerFixedTokenGrowthGlobalX128 + FullMath.mulDivSigned(fixedTokenDelta, FixedPoint128.Q128, state.accumulator);
    }

    /// @dev Private but labelled internal for testability.
    ///
    /// Gets the number of base tokens and fixed tokens between the specified ticks, assuming `basePerTick` base tokens per tick.
    function _trackValuesBetweenTicksOutside(
        Data storage self,
        int128 basePerTick, // base per tick (after spreading notional across all ticks)
        int24 tickLower,
        int24 tickUpper
    ) internal view returns(
        int256 trackerFixedTokenGrowthOutside,
        int256 trackerBaseTokenGrowthOutside
    ) {
        if (tickLower == tickUpper) {
            return (0, 0);
        }

        int256 base = VAMMBase.baseBetweenTicks(tickLower, tickUpper, basePerTick);
        trackerFixedTokenGrowthOutside = _trackFixedTokens(self, base, tickLower, tickUpper, self.termEndTimestamp);
        trackerBaseTokenGrowthOutside = base;
    }

    // @dev For a given LP posiiton, how much of it is available to trade imn each direction?
    function getAccountUnfilledBases(
        Data storage self,
        uint128 accountId
    )
        internal
        returns (int256 unfilledBaseLong, int256 unfilledBaseShort)
    {
        uint256 numPositions = self.positionsInAccount[accountId].length;
        if (numPositions != 0) {
            for (uint256 i = 0; i < numPositions; i++) {
                LPPosition memory position = getRawPosition(self, self.positionsInAccount[accountId][i]);

                // Get how liquidity is currently arranged. In particular, how much of the liquidity is avail to traders in each direction?
                (int256 unfilledLongBase,, int256 unfilledShortBase,) = trackValuesBetweenTicks( // TODO: this is actually getting fixed tokens!?
                    self,
                    position.tickLower,
                    position.tickUpper,
                    position.baseAmount
                );

                unfilledBaseLong += unfilledLongBase;
                unfilledBaseShort += unfilledShortBase;
            }
        }
    }

    // getAccountUnfilledBases
    // -> trackValuesBetweenTicks
    //    -> trackValuesBetweenTicksOutside
    //       -> trackFixedTokens 
    //       -> VAMMBase.baseBetweenTicks 

    // @dev For a given LP posiiton, how much of it is already traded and what are base and quote tokens representing those exiting trades?
    function getAccountFilledBalances(
        Data storage self,
        uint128 accountId
    )
        internal
        returns (int256 baseBalancePool, int256 quoteBalancePool) {
        
        uint256 numPositions = self.positionsInAccount[accountId].length;

        for (uint256 i = 0; i < numPositions; i++) {
            LPPosition memory position = getRawPosition(self, self.positionsInAccount[accountId][i]); 

            baseBalancePool += position.trackerVariableTokenAccumulated;
            quoteBalancePool += position.trackerBaseTokenAccumulated;
        }

    }

    /// @dev Private but labelled internal for testability.
    ///
    /// Gets the number of "unfilled" (still available as liquidity) base tokens and fixed tokens between the specified tick range,
    /// looking both left of the current tick.
    function trackValuesBetweenTicks(
        Data storage self,
        int24 tickLower,
        int24 tickUpper,
        int128 baseAmount
    ) internal view returns(
        int256 unfilledFixedTokensLeft,
        int256 unfilledBaseTokensLeft,
        int256 unfilledFixedTokensRight,
        int256 unfilledBaseTokensRight
    ) {
        if (tickLower == tickUpper) {
            return (0, 0, 0, 0);
        }

        int128 averageBase = VAMMBase.basePerTick(tickLower, tickUpper, baseAmount);

        // Compute unfilled tokens in our range and to the left of the current tick
        (int256 unfilledFixedTokensLeft_, int256 unfilledBaseTokensLeft_) = _trackValuesBetweenTicksOutside(
            self,
            averageBase,
            tickLower < self._vammVars.tick ? tickLower : self._vammVars.tick, // min(tickLower, currentTick)
            tickUpper < self._vammVars.tick ? tickUpper : self._vammVars.tick  // min(tickUpper, currentTick)
        );
        unfilledFixedTokensLeft = -unfilledFixedTokensLeft_;
        unfilledBaseTokensLeft = -unfilledBaseTokensLeft_;

        // Compute unfilled tokens in our range and to the right of the current tick
        (unfilledFixedTokensRight, unfilledBaseTokensRight) = _trackValuesBetweenTicksOutside(
            self,
            averageBase,
            tickLower > self._vammVars.tick ? tickLower : self._vammVars.tick, // max(tickLower, currentTick)
            tickUpper > self._vammVars.tick ? tickUpper : self._vammVars.tick  // max(tickUpper, currentTick)
        );
    }

    function growthBetweenTicks(
        Data storage self,
        int24 tickLower,
        int24 tickUpper
    ) internal view returns (
        int256 trackerVariableTokenGrowthBetween,
        int256 trackerBaseTokenGrowthBetween
    )
    {
        Tick.checkTicks(tickLower, tickUpper);

        int256 trackerVariableTokenBelowLowerTick;
        int256 trackerBaseTokenBelowLowerTick;

        if (tickLower <= self._vammVars.tick) {
            trackerVariableTokenBelowLowerTick = self._ticks[tickLower].trackerVariableTokenGrowthOutsideX128;
            trackerBaseTokenBelowLowerTick = self._ticks[tickLower].trackerBaseTokenGrowthOutsideX128;
        } else {
            trackerVariableTokenBelowLowerTick = self._trackerVariableTokenGrowthGlobalX128 -
                self._ticks[tickLower].trackerVariableTokenGrowthOutsideX128;
            trackerBaseTokenBelowLowerTick = self._trackerBaseTokenGrowthGlobalX128 -
                self._ticks[tickLower].trackerBaseTokenGrowthOutsideX128;
        }

        int256 trackerVariableTokenAboveUpperTick;
        int256 trackerBaseTokenAboveUpperTick;

        if (tickUpper > self._vammVars.tick) {
            trackerVariableTokenAboveUpperTick = self._ticks[tickUpper].trackerVariableTokenGrowthOutsideX128;
            trackerBaseTokenAboveUpperTick = self._ticks[tickUpper].trackerBaseTokenGrowthOutsideX128;
        } else {
            trackerVariableTokenAboveUpperTick = self._trackerVariableTokenGrowthGlobalX128 -
                self._ticks[tickUpper].trackerVariableTokenGrowthOutsideX128;
            trackerBaseTokenAboveUpperTick = self._trackerBaseTokenGrowthGlobalX128 -
                self._ticks[tickUpper].trackerBaseTokenGrowthOutsideX128;
        }

        trackerVariableTokenGrowthBetween = self._trackerVariableTokenGrowthGlobalX128 - trackerVariableTokenBelowLowerTick - trackerVariableTokenAboveUpperTick;
        trackerBaseTokenGrowthBetween = self._trackerBaseTokenGrowthGlobalX128 - trackerBaseTokenBelowLowerTick - trackerBaseTokenAboveUpperTick;

    }
}
