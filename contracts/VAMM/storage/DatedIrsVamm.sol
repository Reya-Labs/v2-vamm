// SPDX-License-Identifier: MIT
pragma solidity >=0.8.13;

import "../../utils/AccessError.sol";
import "../interfaces/IVAMMBase.sol";
import "../libraries/Tick.sol";
import "../libraries/Time.sol";
import "../libraries/TickBitmap.sol";
import "../../utils/SafeCastUni.sol";
import "../../utils/SqrtPriceMath.sol";
import "../libraries/SwapMath.sol";
import { UD60x18, convert } from "@prb/math/src/UD60x18.sol";
import { SD59x18 } from "@prb/math/src/SD59x18.sol";
import { mulUDxInt } from "../../utils/PrbMathHelper.sol";
import "../libraries/FixedAndVariableMath.sol";
import "../../utils/FixedPoint128.sol";
import "../libraries/VAMMBase.sol";
import "../interfaces/IVAMM.sol";
import "../libraries/VammConfiguration.sol";
import "../../utils/CustomErrors.sol";
import "../libraries/Oracle.sol";
import "./LPPosition.sol";
import "../../interfaces/IRateOracle.sol";
import "forge-std/console2.sol"; // TODO: remove

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
    using LPPosition for LPPosition.Data;

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

    /// @dev Internal, frequently-updated state of the VAMM, which is compressed into one storage slot.
    struct Data {
        /// @dev vamm config set at initialization, can't be modified after creation
        VammConfiguration.Immutable immutableConfig;
        /// @dev configurable vamm config
        VammConfiguration.Mutable mutableConfig;
        /// @dev vamm state frequently-updated
        VammConfiguration.State vars;
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
        if (irsVamm.immutableConfig.maturityTimestamp == 0) {
            revert CustomErrors.MarketAndMaturityCombinaitonNotSupported(marketId, maturityTimestamp);
        }
    }

    /**
     * @dev Finds the vamm id using market id and maturity and
     * returns the vamm stored at the specified vamm id. Reverts if no such VAMM is found.
     */
    function create(
        uint128 _marketId,
        uint160 _sqrtPriceX96,
        VammConfiguration.Immutable memory _config,
        VammConfiguration.Mutable memory _mutableConfig
    ) internal returns (Data storage irsVamm) {
        uint256 id = uint256(keccak256(abi.encodePacked(_marketId, _config.maturityTimestamp)));
        irsVamm = load(id);

        if (irsVamm.immutableConfig.maturityTimestamp != 0) {
            revert CustomErrors.MarketAndMaturityCombinaitonAlreadyExists(_marketId, _config.maturityTimestamp);
        }

        if (_config.maturityTimestamp <= block.timestamp) {
            revert CustomErrors.MaturityMustBeInFuture(block.timestamp, _config.maturityTimestamp);
        }

        // tick spacing is capped at 16384 to prevent the situation where tickSpacing is so large that
        // TickBitmap#nextInitializedTickWithinOneWord overflows int24 container from a valid tick
        // 16384 ticks represents a >5x price change with ticks of 1 bips
        require(_config._tickSpacing > 0 && _config._tickSpacing < Tick.MAXIMUM_TICK_SPACING, "TSOOB");

        irsVamm.immutableConfig.maturityTimestamp = _config.maturityTimestamp;
        irsVamm.immutableConfig._maxLiquidityPerTick = _config._maxLiquidityPerTick;
        irsVamm.immutableConfig._tickSpacing = _config._tickSpacing;
        
        configure(irsVamm, _mutableConfig);

        initialize(irsVamm, _sqrtPriceX96);
    }

    /// @dev not locked because it initializes unlocked
    function initialize(
        Data storage self,
        uint160 sqrtPriceX96
    ) internal {
        if (sqrtPriceX96 == 0) {
            revert CustomErrors.ExpectedNonZeroSqrtPriceForInit(sqrtPriceX96);
        }
        if (self.vars.sqrtPriceX96 != 0) {
            revert CustomErrors.ExpectedSqrtPriceZeroBeforeInit(self.vars.sqrtPriceX96);
        }

        int24 tick = TickMath.getTickAtSqrtRatio(sqrtPriceX96);

        (self.vars.observationCardinality, self.vars.observationCardinalityNext) = self.vars.observations.initialize(Time.blockTimestampTruncated());
        self.vars.observationIndex = 0;
        self.vars.unlocked = true;
        self.vars.tick = tick;
        self.vars.sqrtPriceX96 = sqrtPriceX96;
    }

    /// @dev Mutually exclusive reentrancy protection into the pool to/from a method. This method also prevents entrance
    /// to a function before the pool is initialized. The reentrancy guard is required throughout the contract because
    /// we use balance checks to determine the payment status of interactions such as mint, swap and flash.
    modifier lock(Data storage self) {
        if (!self.vars.unlocked) {
            revert CustomErrors.CanOnlyTradeIfUnlocked();
        }
        self.vars.unlocked = false;
        _;
        if (self.vars.unlocked) {
            revert CustomErrors.CanOnlyUnlockIfLocked();
        }
        self.vars.unlocked = true;
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
            console2.log("GM",UD60x18.unwrap(self.mutableConfig.spread));
            spreadImpactDelta = self.mutableConfig.spread;
        }

        if (adjustForPriceImpact) {
            require(orderSize != 0); // TODO: custom error
            priceImpactAsFraction = self.mutableConfig.priceImpactPhi.mul(
                convert(uint256(orderSize > 0 ? orderSize : -orderSize)).pow(self.mutableConfig.priceImpactBeta)
            );
        }

        // The projected price impact and spread of a trade will move the price up for buys, down for sells
        if (orderSize > 0) {
            console2.log("GM",UD60x18.unwrap(geometricMeanPrice));
            console2.log("SID",UD60x18.unwrap(spreadImpactDelta));
            console2.log("PIF",UD60x18.unwrap(priceImpactAsFraction));
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
            console2.log("GM",UD60x18.unwrap(geometricMeanPrice));
            console2.log("SID",UD60x18.unwrap(spreadImpactDelta));
            console2.log("PIF",UD60x18.unwrap(priceImpactAsFraction));
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
            arithmeticMeanTick = self.vars.tick;
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
            self.vars.observations.observe(
                Time.blockTimestampTruncated(),
                secondsAgos,
                self.vars.tick,
                self.vars.observationIndex,
                0, // liquidity is untracked
                self.vars.observationCardinality
            );
    }

    /// @notice Increase the maximum number of price and liquidity observations that this pool will store
    /// @dev This method is no-op if the pool already has an observationCardinalityNext greater than or equal to
    /// the input observationCardinalityNext.
    /// @param observationCardinalityNext The desired minimum number of observations for the pool to store
    function increaseObservationCardinalityNext(Data storage self, uint16 observationCardinalityNext)
        internal
        lock(self)
    {
        uint16 observationCardinalityNextOld =  self.vars.observationCardinalityNext; // for the event
        uint16 observationCardinalityNextNew =  self.vars.observations.grow(
            observationCardinalityNextOld,
            observationCardinalityNext
        );
         self.vars.observationCardinalityNext = observationCardinalityNextNew;
        if (observationCardinalityNextOld != observationCardinalityNextNew)
            emit IncreaseObservationCardinalityNext(observationCardinalityNextOld, observationCardinalityNextNew);
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
        int24 tickLower = TickMath.getTickAtSqrtRatio(fixedRateLower);
        int24 tickUpper = TickMath.getTickAtSqrtRatio(fixedRateUpper);

        LPPosition.Data storage position = LPPosition._ensurePositionOpened(accountId, tickLower, tickUpper);
        self.vars.positionsInAccount[accountId].push(LPPosition.getPositionId(accountId, tickLower, tickUpper));

        require(position.baseAmount + requestedBaseAmount >= 0, "Burning too much"); // TODO: CustomError

        executedBaseAmount = _vammMint(self, accountId, tickLower, tickUpper, requestedBaseAmount);
        position.updateBaseAmount(requestedBaseAmount);
       
        return executedBaseAmount;
    }

    function configure(
        Data storage self,
        VammConfiguration.Mutable memory _config) internal {

        // TODO: sanity check config - e.g. price impact calculated must never be >= 1

        self.mutableConfig.priceImpactPhi = _config.priceImpactPhi;
        self.mutableConfig.priceImpactBeta = _config.priceImpactBeta;
        self.mutableConfig.rateOracle = _config.rateOracle;
        self.mutableConfig.spread = _config.spread;
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
    function _trackFixedTokens( // TODO: rename fixedTokensInHomogeneousTickWindow or similar? 
      Data storage self,
      int256 baseAmount,
      int24 tickLower,
      int24 tickUpper,
      uint256 maturityTimestamp
    )
        internal
        view
        returns (
            int256 trackedValue
        )
    {
        // TODO: calculate timeDeltaUntilMaturity and currentOracleValue outside _trackFixedTokens and pass as param to _trackFixedTokens, to avoid repeating the same work
        UD60x18 averagePrice = VAMMBase.averagePriceBetweenTicks(tickLower, tickUpper);
        UD60x18 timeDeltaUntilMaturity = FixedAndVariableMath.accrualFact(maturityTimestamp - block.timestamp); 
        UD60x18 currentOracleValue = self.mutableConfig.rateOracle.getCurrentIndex();
        UD60x18 timeComponent = ONE.add(averagePrice.mul(timeDeltaUntilMaturity)); // (1 + fixedRate * timeInYearsTillMaturity)
        trackedValue = mulUDxInt(
            currentOracleValue.mul(timeComponent),
            -baseAmount
        );
    }

    /// @dev Private but labelled internal for testability. Consumers of the library should use `executeDatedMakerOrder()`.
    /// Mints `baseAmount` of liquidity for the specified `accountId`, uniformly (same amount per-tick) between the specified ticks.
    function _vammMint(
        Data storage self,
        uint128 accountId,
        int24 tickLower,
        int24 tickUpper,
        int128 requesetedBaseAmount
    ) internal
      lock(self)
      returns (int128 executedBaseAmount)
    {
        VAMMBase.checkCurrentTimestampMaturityTimestampDelta(self.immutableConfig.maturityTimestamp);

        // console2.log("_vammMint: ticks = (%s, %s)", uint256(int256(tickLower)), uint256(int256(tickUpper))); // TODO_delete_log
        Tick.checkTicks(tickLower, tickUpper);

        bool flippedLower;
        bool flippedUpper;

        // TODO: this results in rounding per tick. How did that work in v1 / UniV3? Is there a simpler or more efficient solution?
        int128 basePerTick = VAMMBase.basePerTick(tickLower, tickUpper, requesetedBaseAmount);

        /// @dev update the ticks if necessary
        if (basePerTick != 0) {

            VAMMBase.FlipTicksParams memory params;
            params.tickLower = tickLower;
            params.tickUpper = tickUpper;
            params.accumulatorDelta = basePerTick;
            (flippedLower, flippedUpper) = params.flipTicks(
                self.vars._ticks,
                self.vars._tickBitmap,
                self.vars,
                self.vars.trackerVariableTokenGrowthGlobalX128,
                self.vars.trackerVariableTokenGrowthGlobalX128,
                self.immutableConfig._maxLiquidityPerTick,
                self.immutableConfig._tickSpacing
            );
        }

        // clear any tick data that is no longer needed
        if (basePerTick < 0) {
            if (flippedLower) {
                self.vars._ticks.clear(tickLower);
            }
            if (flippedUpper) {
                self.vars._ticks.clear(tickUpper);
            }
        }

        if (basePerTick != 0) {
            if (
                (self.vars.tick >= tickLower) && (self.vars.tick < tickUpper)
            ) {
                // current tick is inside the passed range
                uint128 accumulatorBefore = self.vars.accumulator; // SLOAD for gas optimization

                self.vars.accumulator = LiquidityMath.addDelta(
                    accumulatorBefore,
                    basePerTick
                );
            }
        }

        executedBaseAmount = VAMMBase.baseBetweenTicks(tickLower, tickUpper, basePerTick);

        emit VAMMBase.Mint(msg.sender, accountId, tickLower, tickUpper, requesetedBaseAmount, executedBaseAmount);
    }

    function vammSwap(
        Data storage self,
        IVAMMBase.SwapParams memory params
    )
        internal
        lock(self)
        returns (int256 trackerFixedTokenDelta, int256 trackerBaseTokenDelta)
    {
        VAMMBase.checkCurrentTimestampMaturityTimestampDelta(self.immutableConfig.maturityTimestamp);

        // console2.log("Checking ticks in vammSwap"); // TODO_delete_log
        Tick.checkTicks(params.tickLower, params.tickUpper);

        VAMMBase.checksBeforeSwap(params, self.vars, params.baseAmountSpecified > 0);

        uint128 accumulatorStart = self.vars.accumulator;

        VAMMBase.SwapState memory state = VAMMBase.SwapState({
            amountSpecifiedRemaining: params.baseAmountSpecified, // base ramaining
            sqrtPriceX96: self.vars.sqrtPriceX96,
            tick: self.vars.tick,
            accumulator: accumulatorStart,
            trackerFixedTokenGrowthGlobalX128: self.vars.trackerVariableTokenGrowthGlobalX128,
            trackerBaseTokenGrowthGlobalX128: self.vars.trackerVariableTokenGrowthGlobalX128,
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
            (step.tickNext, step.initialized) = self.vars._tickBitmap
                .nextInitializedTickWithinOneWord(state.tick, self.immutableConfig._tickSpacing, !advanceRight);

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
                    timeToMaturityInSeconds: self.immutableConfig.maturityTimestamp - block.timestamp
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
                    step.trackerFixedTokenDelta
                ) = _calculateUpdatedGlobalTrackerValues( 
                    self,
                    state,
                    step,
                    self.immutableConfig.maturityTimestamp
                );

                state.trackerFixedTokenDeltaCumulative -= step.trackerFixedTokenDelta; // fixedTokens; opposite sign from that of the LP's
                state.trackerBaseTokenDeltaCumulative -= step.trackerBaseTokenDelta; // opposite sign from that of the LP's
            }

            ///// UPDATE TICK AFTER SWAP STEP /////

            // shift tick if we reached the next price
            if (state.sqrtPriceX96 == step.sqrtPriceNextX96) {
                // if the tick is initialized, run the tick transition
                if (step.initialized) {
                    int128 accumulatorNet = self.vars._ticks.cross(
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
        if (state.tick != self.vars.tick) {
            // update the tick in case it changed
            (uint16 observationIndex, uint16 observationCardinality) = self.vars.observations.write(
                self.vars.observationIndex,
                Time.blockTimestampTruncated(),
                self.vars.tick,
                0, // Liquidity not currently being tracked
                self.vars.observationCardinality,
                self.vars.observationCardinalityNext
            );
            (self.vars.sqrtPriceX96, self.vars.tick, self.vars.observationIndex, self.vars.observationCardinality) = (
                state.sqrtPriceX96,
                state.tick,
                observationIndex,
                observationCardinality
            );
        } else {
            // otherwise just update the price
            self.vars.sqrtPriceX96 = state.sqrtPriceX96;
        }

        // update liquidity if it changed
        if (accumulatorStart != state.accumulator) self.vars.accumulator = state.accumulator;

        self.vars.trackerVariableTokenGrowthGlobalX128 = state.trackerBaseTokenGrowthGlobalX128;
        self.vars.trackerVariableTokenGrowthGlobalX128 = state.trackerFixedTokenGrowthGlobalX128;

        trackerFixedTokenDelta = state.trackerFixedTokenDeltaCumulative;
        trackerBaseTokenDelta = state.trackerBaseTokenDeltaCumulative;

        emit VAMMBase.VAMMPriceChange(self.vars.tick);

        emit VAMMBase.Swap(
            msg.sender,
            params.tickLower,
            params.tickUpper,
            params.baseAmountSpecified,
            params.sqrtPriceLimitX96,
            trackerFixedTokenDelta,
            trackerBaseTokenDelta
        );
    }


    /// @dev Private but labelled internal for testability.
    function _calculateUpdatedGlobalTrackerValues(
        Data storage self,
        VAMMBase.SwapState memory state,
        VAMMBase.StepComputations memory step,
        uint256 maturityTimestamp
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
            maturityTimestamp
        );

        // update global trackers
        stateVariableTokenGrowthGlobalX128 = state.trackerBaseTokenGrowthGlobalX128 + FullMath.mulDivSigned(step.trackerBaseTokenDelta, FixedPoint128.Q128, state.accumulator);
        stateFixedTokenGrowthGlobalX128 = state.trackerFixedTokenGrowthGlobalX128 + FullMath.mulDivSigned(fixedTokenDelta, FixedPoint128.Q128, state.accumulator);
    }

    /// @dev Private but labelled internal for testability.
    ///
    /// Gets the number of base tokens and fixed tokens between the specified ticks, assuming `basePerTick` base tokens per tick.
    function _trackValuesBetweenTicksOutside( // TODO: rename _tokenValuesBetweenTicks
        Data storage self,
        int128 basePerTick,
        int24 tickLower,
        int24 tickUpper
    ) internal view returns(
        int256 trackerFixedTokenGrowthOutside,
        int256 trackerBaseTokenGrowthOutside
    ) {
        if (tickLower == tickUpper) {
            return (0, 0);
        }

        int128 base = VAMMBase.baseBetweenTicks(tickLower, tickUpper, basePerTick);
        trackerFixedTokenGrowthOutside = _trackFixedTokens(self, base, tickLower, tickUpper, self.immutableConfig.maturityTimestamp);
        trackerBaseTokenGrowthOutside = base;
    }

    /// @notice For a given LP account, how much liquidity is available to trade in each direction.
    /// 
    /// @param accountId The LP account. All positions within the account will be considered.
    /// @return unfilledBaseLong The base tokens available for a trader to take a long position against this LP (which will then become a short position for the LP) 
    /// @return unfilledBaseShort The base tokens available for a trader to take a short position against this LP (which will then become a long position for the LP) 
    function getAccountUnfilledBases(
        Data storage self,
        uint128 accountId
    )
        internal
        returns (int256 unfilledBaseLong, int256 unfilledBaseShort)
    {
        uint256 numPositions = self.vars.positionsInAccount[accountId].length;
        if (numPositions != 0) {
            for (uint256 i = 0; i < numPositions; i++) {
                LPPosition.Data storage position = LPPosition.load(self.vars.positionsInAccount[accountId][i]);
                // Get how liquidity is currently arranged. In particular, how much of the liquidity is avail to traders in each direction?
                (,int256 unfilledShortBase,, int256 unfilledLongBase) = _trackValuesBetweenTicks(
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

    // @dev For a given LP posiiton, how much of it is already traded and what are base and quote tokens representing those exiting trades?
    function getAccountFilledBalances(
        Data storage self,
        uint128 accountId
    )
        internal
        returns (int256 baseBalancePool, int256 quoteBalancePool) {
        
        uint256 numPositions = self.vars.positionsInAccount[accountId].length;

        for (uint256 i = 0; i < numPositions; i++) {
            LPPosition.Data storage position = LPPosition.load(self.vars.positionsInAccount[accountId][i]);
            (int256 trackerVariableTokenGlobalGrowth, int256 trackerBaseTokenGlobalGrowth) = 
                growthBetweenTicks(self, position.tickLower, position.tickUpper);
            (int256 trackerVariableTokenAccumulated, int256 trackerBaseTokenAccumulated) = position.getUpdatedPositionBalances(trackerVariableTokenGlobalGrowth, trackerBaseTokenGlobalGrowth); 

            baseBalancePool += trackerVariableTokenAccumulated;
            quoteBalancePool += trackerBaseTokenAccumulated;
        }

    }

    /// @dev Private but labelled internal for testability.
    ///
    /// Gets the number of "unfilled" (still available as liquidity) base tokens and fixed tokens between the specified tick range,
    /// looking both left of the current tick.
    function _trackValuesBetweenTicks( // TODO: rename as getUnfilledTokenValues?
    // TODO: remove calculations of fixed token values (from here and from _trackValuesBetweenTicksOutside) if these remain unused by any consumer of this function.
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
        // console2.log("_trackValuesBetweenTicks: averageBase = %s", uint256(int256(averageBase))); // TODO_delete_log // TODO: how does rounding work here? If we round down to zero has all liquidity vanished? What checks should be in place?
        // Compute unfilled tokens in our range and to the left of the current tick
        (int256 unfilledFixedTokensLeft_, int256 unfilledBaseTokensLeft_) = _trackValuesBetweenTicksOutside(
            self,
            averageBase,
            tickLower < self.vars.tick ? tickLower : self.vars.tick, // min(tickLower, currentTick)
            tickUpper < self.vars.tick ? tickUpper : self.vars.tick  // min(tickUpper, currentTick)
        );
        unfilledFixedTokensLeft = -unfilledFixedTokensLeft_;
        unfilledBaseTokensLeft = -unfilledBaseTokensLeft_;

        // console2.log("unfilledTokensLeft: (%s, %s)", uint256(unfilledFixedTokensLeft), uint256(unfilledBaseTokensLeft)); // TODO_delete_log


        // Compute unfilled tokens in our range and to the right of the current tick
        (unfilledFixedTokensRight, unfilledBaseTokensRight) = _trackValuesBetweenTicksOutside(
            self,
            averageBase,
            tickLower > self.vars.tick ? tickLower : self.vars.tick, // max(tickLower, currentTick)
            tickUpper > self.vars.tick ? tickUpper : self.vars.tick  // max(tickUpper, currentTick)
        );
        // console2.log("unfilledTokensRight: (%s, %s)", uint256(unfilledFixedTokensRight), uint256(unfilledBaseTokensRight)); // TODO_delete_log
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
        // console2.log("Checking ticks in growthBetweenTicks"); // TODO_delete_log
        Tick.checkTicks(tickLower, tickUpper);

        int256 trackerVariableTokenBelowLowerTick;
        int256 trackerBaseTokenBelowLowerTick;

        if (tickLower <= self.vars.tick) {
            trackerVariableTokenBelowLowerTick = self.vars._ticks[tickLower].trackerVariableTokenGrowthOutsideX128;
            trackerBaseTokenBelowLowerTick = self.vars._ticks[tickLower].trackerBaseTokenGrowthOutsideX128;
        } else {
            trackerVariableTokenBelowLowerTick = self.vars.trackerVariableTokenGrowthGlobalX128 -
                self.vars._ticks[tickLower].trackerVariableTokenGrowthOutsideX128;
            trackerBaseTokenBelowLowerTick = self.vars.trackerVariableTokenGrowthGlobalX128 -
                self.vars._ticks[tickLower].trackerBaseTokenGrowthOutsideX128;
        }

        int256 trackerVariableTokenAboveUpperTick;
        int256 trackerBaseTokenAboveUpperTick;

        if (tickUpper > self.vars.tick) {
            trackerVariableTokenAboveUpperTick = self.vars._ticks[tickUpper].trackerVariableTokenGrowthOutsideX128;
            trackerBaseTokenAboveUpperTick = self.vars._ticks[tickUpper].trackerBaseTokenGrowthOutsideX128;
        } else {
            trackerVariableTokenAboveUpperTick = self.vars.trackerVariableTokenGrowthGlobalX128 -
                self.vars._ticks[tickUpper].trackerVariableTokenGrowthOutsideX128;
            trackerBaseTokenAboveUpperTick = self.vars.trackerVariableTokenGrowthGlobalX128 -
                self.vars._ticks[tickUpper].trackerBaseTokenGrowthOutsideX128;
        }

        trackerVariableTokenGrowthBetween = self.vars.trackerVariableTokenGrowthGlobalX128 - trackerVariableTokenBelowLowerTick - trackerVariableTokenAboveUpperTick;
        trackerBaseTokenGrowthBetween = self.vars.trackerVariableTokenGrowthGlobalX128 - trackerBaseTokenBelowLowerTick - trackerBaseTokenAboveUpperTick;

    }
}
