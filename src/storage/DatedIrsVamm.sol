// SPDX-License-Identifier: MIT
pragma solidity >=0.8.13;

import "./LPPosition.sol";
import "./PoolConfiguration.sol";

import "../../utils/vamm-math/VAMMBase.sol";
import "../../utils/vamm-math/SwapMath.sol";
import "../../utils/vamm-math/FixedAndVariableMath.sol";

import "../../utils/CustomErrors.sol";

import { UD60x18, convert } from "@prb/math/UD60x18.sol";
import { SD59x18 } from "@prb/math/SD59x18.sol";
import { mulUDxInt } from "@voltz-protocol/util-contracts/src/helpers/PrbMathHelper.sol";

import "@voltz-protocol/util-contracts/src/helpers/SafeCast.sol";

/**
 * @title Connects external contracts that implement the `IVAMM` interface to the protocol.
 *
 */
library DatedIrsVamm {
    UD60x18 constant ONE = VAMMBase.ONE;
    using SafeCastU256 for uint256;
    using SafeCastI256 for int256;
    using SafeCastU128 for uint128;
    using VAMMBase for bool;
    using Tick for mapping(int24 => Tick.Info);
    using TickBitmap for mapping(int16 => uint256);
    using Oracle for Oracle.Observation[65535];
    using LPPosition for LPPosition.Data;
    using DatedIrsVamm for Data;

    /// @notice Emitted by the pool for increases to the number of observations that can be stored
    /// @dev observationCardinalityNext is not the observation cardinality until an observation is written at the index
    /// just before a mint/swap/burn.
    /// @param observationCardinalityNextOld The previous value of the next observation cardinality
    /// @param observationCardinalityNextNew The updated value of the next observation cardinality
    event IncreaseObservationCardinalityNext(
        uint128 marketId,
        uint32 maturityTimestamp,
        uint16 observationCardinalityNextOld,
        uint16 observationCardinalityNextNew,
        uint256 blockTimestamp
    );

    /**
     * @dev Thrown when a specified vamm is not found.
     */
    error IRSVammNotFound(uint128 vammId);

    /**
     * @dev Thrown when Twap order size is 0 and it tries to adjust for spread or price impact
     */
    error TwapNotAdjustable();

    /**
     * @dev Thrown when price impact configuration is larger than 1 in wad
     */
    error PriceImpactOutOfBounds();

    /**
     * @dev Thrown when specified ticks excees limits set in TickMath
     * or the current tick is outside of the range
     */
    error ExceededTickLimits(int24 minTick, int24 maxTick);

    /**
     * @dev Thrown when specified ticks are not symmetric around 0
     */
    error AsymmetricTicks(int24 minTick, int24 maxTick);

    /**
     * @dev Thrown when the number of positions per account exceeded the limit.
     */
    error TooManyLpPositions(uint128 accountId);

    /// @dev Internal, frequently-updated state of the VAMM, which is compressed into one storage slot.
    struct Data {
        /// @dev vamm config set at initialization, can't be modified after creation
        VammConfiguration.Immutable immutableConfig;
        /// @dev configurable vamm config
        VammConfiguration.Mutable mutableConfig;
        /// @dev vamm state frequently-updated
        VammConfiguration.State vars;
        /// @dev Equivalent to getSqrtRatioAtTick(MAX_TICK)
        uint160 minSqrtRatio;
        /// @dev Equivalent to getSqrtRatioAtTick(MIN_TICK)
        uint160 maxSqrtRatio;
    }

    struct SwapParams {
        /// @dev The amount of the swap in base tokens, which implicitly configures the swap as exact input (positive), or exact output (negative)
        int256 amountSpecified;
        /// @dev The Q64.96 sqrt price limit. If !isFT, the price cannot be less than this
        uint160 sqrtPriceLimitX96;
    }

    /**
     * @dev Returns the vamm stored at the specified vamm id.
     */
    function load(uint256 id) internal pure returns (Data storage irsVamm) {
        if (id == 0) {
            revert IRSVammNotFound(0);
        }
        bytes32 s = keccak256(abi.encode("xyz.voltz.DatedIRSVamm", id));
        assembly {
            irsVamm.slot := s
        }
    }

    /**
     * @dev Finds the vamm id using market id and maturity and
     * returns the vamm stored at the specified vamm id. Reverts if no such VAMM is found.
     */
    function loadByMaturityAndMarket(uint128 marketId, uint32 maturityTimestamp) internal view returns (Data storage irsVamm) {
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
        uint32[] memory times,
        int24[] memory observedTicks,
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
        irsVamm.immutableConfig.marketId = _marketId;

        initialize(irsVamm, _sqrtPriceX96, times, observedTicks);
        
        configure(irsVamm, _mutableConfig);
    }

    /// @dev not locked because it initializes unlocked
    function initialize(
        Data storage self,
        uint160 sqrtPriceX96,
        uint32[] memory times,
        int24[] memory observedTicks
    ) internal {
        if (sqrtPriceX96 == 0) {
            revert CustomErrors.ExpectedNonZeroSqrtPriceForInit(sqrtPriceX96);
        }
        if (self.vars.sqrtPriceX96 != 0) {
            revert CustomErrors.ExpectedSqrtPriceZeroBeforeInit(self.vars.sqrtPriceX96);
        }

        int24 tick = TickMath.getTickAtSqrtRatio(sqrtPriceX96);

        (self.vars.observationCardinality, self.vars.observationCardinalityNext) = self.vars.observations.initialize(times, observedTicks);
        self.vars.observationIndex = self.vars.observationCardinality - 1;
        self.vars.unlocked = true;
        self.vars.tick = tick;
        self.vars.sqrtPriceX96 = sqrtPriceX96;
    }

    function configure(
        Data storage self,
        VammConfiguration.Mutable memory _config) internal {

        if (_config.priceImpactPhi.gt(ONE) || _config.priceImpactBeta.gt(ONE)) {
            revert PriceImpactOutOfBounds();
        }

        self.mutableConfig.priceImpactPhi = _config.priceImpactPhi;
        self.mutableConfig.priceImpactBeta = _config.priceImpactBeta;
        self.mutableConfig.rateOracle = _config.rateOracle;
        self.mutableConfig.spread = _config.spread;

        self.setMinAndMaxTicks(_config.minTick, _config.maxTick);
    }

    function setMinAndMaxTicks(
        Data storage self,
        int24 _minTick,
        int24 _maxTick
    ) internal {
        if(
            _minTick < TickMath.MIN_TICK_LIMIT || _maxTick > TickMath.MAX_TICK_LIMIT ||
            self.vars.tick < _minTick || self.vars.tick > _maxTick
        ) {
            revert ExceededTickLimits(_minTick, _maxTick);
        }

        if(_minTick + _maxTick != 0) {
            revert AsymmetricTicks(_minTick, _maxTick);
        }

        self.mutableConfig.minTick = _minTick;
        self.mutableConfig.maxTick = _maxTick;
        self.minSqrtRatio = TickMath.getSqrtRatioAtTick(_minTick);
        self.maxSqrtRatio = TickMath.getSqrtRatioAtTick(_maxTick);
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
        geometricMeanPrice = self.getPriceFromTick(arithmeticMeanTick);
        UD60x18 spreadImpactDelta = ZERO;
        UD60x18 priceImpactAsFraction = ZERO;

        if (adjustForSpread) {
            if (orderSize == 0) {
                revert TwapNotAdjustable();
            }
            spreadImpactDelta = self.mutableConfig.spread;
        }

        if (adjustForPriceImpact) {
            if (orderSize == 0) {
                revert TwapNotAdjustable();
            }
            // note the order size is already scaled by token decimals
            // convert() further scales it by WAD, resulting in a bigger price
            // impact than expected. 
            // proposed solution: descale by token decimals prior to this operation
            priceImpactAsFraction = self.mutableConfig.priceImpactPhi.mul(
                convert(uint256(orderSize > 0 ? orderSize : -orderSize)).pow(self.mutableConfig.priceImpactBeta)
            );
        }

        // The projected price impact and spread of a trade will move the price up for buys, down for sells
        if (orderSize > 0) {
            geometricMeanPrice = geometricMeanPrice.mul(ONE.add(priceImpactAsFraction)).add(spreadImpactDelta);
        } else {
            if (spreadImpactDelta.gte(geometricMeanPrice)) {
                // The spread is higher than the price
                return ZERO;
            }
            if (priceImpactAsFraction.gte(ONE)) {
                // The model suggests that the price will drop below zero after price impact
                return ZERO;
            }
            geometricMeanPrice = geometricMeanPrice.mul(ONE.sub(priceImpactAsFraction)).sub(spreadImpactDelta);
        }

        return geometricMeanPrice.div(convert(100));
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
            emit IncreaseObservationCardinalityNext(self.immutableConfig.marketId, self.immutableConfig.maturityTimestamp, observationCardinalityNextOld, observationCardinalityNextNew, block.timestamp);
    }

    /**
     * @notice Executes a dated maker order that provides liquidity to (or removes liquidty from) this VAMM
     * @param accountId Id of the `Account` with which the lp wants to provide liqudiity
     * @param tickLower Lower tick of the range order
     * @param tickUpper Upper tick of the range order
     * @param liquidityDelta Liquidity to add (positive values) or remove (negative values) witin the tick range
     */
    function executeDatedMakerOrder(
        Data storage self,
        uint128 accountId,
        int24 tickLower,
        int24 tickUpper,
        int128 liquidityDelta
    )
    internal
    { 
        VAMMBase.checkCurrentTimestampMaturityTimestampDelta(self.immutableConfig.maturityTimestamp);
        
        (LPPosition.Data storage position, bool newlyCreated) = LPPosition._ensurePositionOpened(accountId, tickLower, tickUpper);
        if (newlyCreated) {
            uint256 positionsPerAccountLimit = PoolConfiguration.load().makerPositionsPerAccountLimit;
            if (self.vars.positionsInAccount[accountId].length >= positionsPerAccountLimit) {
                revert TooManyLpPositions(accountId);
            }
            self.vars.positionsInAccount[accountId].push(LPPosition.getPositionId(accountId, tickLower, tickUpper));
        }

        // this also checks if the position has enough liquidity to burn
        self.updatePositionTokenBalances( 
            position,
            tickLower,
            tickUpper,
            true
        );

        position.updateLiquidity(liquidityDelta);

        _updateLiquidity(self, tickLower, tickUpper, liquidityDelta);

        emit VAMMBase.LiquidityChange(self.immutableConfig.marketId, self.immutableConfig.maturityTimestamp, msg.sender, accountId, tickLower, tickUpper, liquidityDelta, block.timestamp);
    }

    /// @notice update position token balances and account for fees
    /// @dev if the _liquidity of the position supplied to this function is >0 then we
    /// @dev 1. retrieve the fixed, variable and fee Growth variables from the vamm by invoking the computeGrowthInside function of the VAMM
    /// @dev 2. calculate the deltas that need to be applied to the position's fixed and variable token balances by taking into account trades that took place in the VAMM since the last mint/poke/burn that invoked this function
    /// @dev 3. update the fixed and variable token balances and the margin of the position to account for deltas (outlined above) and fees generated by the active liquidity supplied by the position
    /// @dev 4. additionally, we need to update the last growth inside variables in the Position.Info struct so that we take a note that we've accounted for the changes up until this point
    /// @dev if _liquidity of the position supplied to this function is zero, then we need to check if isMintBurn is set to true (if it is set to true) then we know this function was called post a mint/burn event,
    /// @dev meaning we still need to correctly update the last fixed, variable and fee growth variables in the Position.Info struct
    function updatePositionTokenBalances(
        Data storage self,
        LPPosition.Data storage position,
        int24 tickLower,
        int24 tickUpper,
        bool isMintBurn
    ) internal {
        if (position.liquidity > 0) {
            (
                int256 _quoteTokenGrowthInsideX128,
                int256 _baseTokenGrowthInsideX128
            ) = self.computeGrowthInside(tickLower, tickUpper);
            (int256 _quoteTokenDelta, int256 _baseTokenDelta) = position
                .calculateFixedAndVariableDelta(
                    _quoteTokenGrowthInsideX128,
                    _baseTokenGrowthInsideX128
                );
            
            position.updateTrackers(
                _quoteTokenGrowthInsideX128,
                _baseTokenGrowthInsideX128,
                _quoteTokenDelta,
                _baseTokenDelta // todo: why were these "- 1" in v1?
            );
        } else {
            if (isMintBurn) {
                (
                    int256 _quoteTokenGrowthInsideX128,
                    int256 _baseTokenGrowthInsideX128
                ) = self.computeGrowthInside(tickLower, tickUpper);
                position.updateTrackers(
                    _quoteTokenGrowthInsideX128,
                    _baseTokenGrowthInsideX128,
                    0,
                    0
                );
            }
        }
    }

    /// @dev Private but labelled internal for testability. Consumers of the library should use `executeDatedMakerOrder()`.
    /// Mints (`liquidityDelta > 0`) or burns (`liquidityDelta < 0`) `liquidityDelta` liquidity for the specified `accountId`, uniformly between the specified ticks.
    function _updateLiquidity(
        Data storage self,
        int24 tickLower,
        int24 tickUpper,
        int128 liquidityDelta
    ) internal
      lock(self)
    {
        VAMMBase.checkCurrentTimestampMaturityTimestampDelta(self.immutableConfig.maturityTimestamp);

        if (liquidityDelta > 0) {
            self.checkTicksInRange(tickLower, tickUpper);
        } else {
            checkTicksLimits(tickLower, tickUpper);
        }
        
        bool flippedLower;
        bool flippedUpper;

        /// @dev update the ticks if necessary
        if (liquidityDelta != 0) {
            (flippedLower, flippedUpper) = self.flipTicks(
                tickLower,
                tickUpper,
                liquidityDelta
            );
        }

        // clear any tick data that is no longer needed
        if (liquidityDelta < 0) {
            if (flippedLower) {
                self.vars._ticks.clear(tickLower);
            }
            if (flippedUpper) {
                self.vars._ticks.clear(tickUpper);
            }
        }

        if (liquidityDelta != 0) {
            if (
                (self.vars.tick >= tickLower) && (self.vars.tick < tickUpper)
            ) {
                // current tick is inside the passed range
                uint128 liquidityBefore = self.vars.liquidity; // SLOAD for gas optimization

                self.vars.liquidity = LiquidityMath.addDelta(
                    liquidityBefore,
                    liquidityDelta
                );
            }
        }
    }

    /// @dev amountSpecified The amount of the swap in base tokens, which implicitly configures the swap as exact input (positive), or exact output (negative)
    /// @dev sqrtPriceLimitX96 The Q64.96 sqrt price limit. If !isFT, the price cannot be less than this
    function vammSwap(
        Data storage self,
        SwapParams memory params
    )
        internal
        lock(self)
        returns (int256 quoteTokenDelta, int256 baseTokenDelta)
    {
        VAMMBase.checkCurrentTimestampMaturityTimestampDelta(self.immutableConfig.maturityTimestamp);

        self.checksBeforeSwap(params.amountSpecified, params.sqrtPriceLimitX96, params.amountSpecified > 0);

        uint128 liquidityStart = self.vars.liquidity;

        VAMMBase.SwapState memory state = VAMMBase.SwapState({
            amountSpecifiedRemaining: params.amountSpecified, // base ramaining
            sqrtPriceX96: self.vars.sqrtPriceX96,
            tick: self.vars.tick,
            liquidity: liquidityStart,
            trackerQuoteTokenGrowthGlobalX128: self.vars.trackerQuoteTokenGrowthGlobalX128,
            trackerBaseTokenGrowthGlobalX128: self.vars.trackerBaseTokenGrowthGlobalX128,
            quoteTokenDeltaCumulative: 0, // for Trader (user invoking the swap)
            baseTokenDeltaCumulative: 0 // for Trader (user invoking the swap)
        });

        // The following are used n times within the loop, but will not change so they are calculated here
        uint256 secondsTillMaturity = self.immutableConfig.maturityTimestamp - block.timestamp;
        int24[] memory vammMinMaxTicks = new int24[](2);
        vammMinMaxTicks[0] = self.mutableConfig.minTick;
        vammMinMaxTicks[1] = self.mutableConfig.maxTick;

        // continue swapping as long as we haven't used the entire input/output and haven't reached the price (implied fixed rate) limit
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
                .nextInitializedTickWithinOneWord(state.tick, self.immutableConfig._tickSpacing, !(params.amountSpecified > 0));

            // ensure that we do not overshoot the min/max tick, as the tick bitmap is not aware of these bounds
            if (params.amountSpecified > 0 && step.tickNext > vammMinMaxTicks[1]) {
                step.tickNext = vammMinMaxTicks[1];
            }
            if (!(params.amountSpecified > 0) && step.tickNext < vammMinMaxTicks[0]) {
                step.tickNext = vammMinMaxTicks[0];
            }
            // get the price for the next tick
            step.sqrtPriceNextX96 = self.getSqrtRatioAtTickSafe(step.tickNext);

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
                    sqrtRatioTargetX96: VAMMBase.getSqrtRatioTargetX96(params.amountSpecified, step.sqrtPriceNextX96, params.sqrtPriceLimitX96),
                    liquidity: state.liquidity,
                    amountRemaining: state.amountSpecifiedRemaining,
                    timeToMaturityInSeconds: secondsTillMaturity
                })
            );

            // mapping amount in and amount out to the corresponding deltas
            // along the 2 axes of the vamm
            if (params.amountSpecified > 0) {
                // LP is a Variable Taker
                step.baseTokenDelta = step.amountIn.toInt(); // this is positive
                step.unbalancedQuoteTokenDelta = -step.amountOut.toInt();
            } else {
                // LP is a Fixed Taker
                step.baseTokenDelta = -step.amountOut.toInt();
                step.unbalancedQuoteTokenDelta = step.amountIn.toInt(); // this is positive
            }

            ///// UPDATE TRACKERS /////
            state.amountSpecifiedRemaining -= step.baseTokenDelta;
            if (state.liquidity > 0) {
                step.quoteTokenDelta = VAMMBase.calculateQuoteTokenDelta(
                    step.unbalancedQuoteTokenDelta,
                    step.baseTokenDelta,
                    FixedAndVariableMath.accrualFact(secondsTillMaturity),
                    self.mutableConfig.rateOracle.getCurrentIndex(),
                    self.mutableConfig.spread
                );

                (
                    state.trackerQuoteTokenGrowthGlobalX128,
                    state.trackerBaseTokenGrowthGlobalX128
                ) = VAMMBase.calculateGlobalTrackerValues(
                    state,
                    step.quoteTokenDelta,
                    step.baseTokenDelta
                );

                state.quoteTokenDeltaCumulative -= step.quoteTokenDelta; // opposite sign from that of the LP's
                state.baseTokenDeltaCumulative -= step.baseTokenDelta; // opposite sign from that of the LP's
            }

            ///// UPDATE TICK AFTER SWAP STEP /////

            // shift tick if we reached the next price
            if (state.sqrtPriceX96 == step.sqrtPriceNextX96) {
                // if the tick is initialized, run the tick transition
                if (step.initialized) {
                    int128 liquidityNet = self.vars._ticks.cross(
                        step.tickNext,
                        state.trackerQuoteTokenGrowthGlobalX128,
                        state.trackerBaseTokenGrowthGlobalX128
                    );

                    state.liquidity = LiquidityMath.addDelta(
                        state.liquidity,
                        params.amountSpecified > 0 ? liquidityNet : -liquidityNet
                    );

                }

                state.tick = params.amountSpecified > 0 ? step.tickNext : (step.tickNext - 1);
            } else if (state.sqrtPriceX96 != step.sqrtPriceStartX96) {
                // recompute unless we're on a lower tick boundary (i.e. already transitioned ticks), and haven't moved
                state.tick = TickMath.getTickAtSqrtRatio(state.sqrtPriceX96);
            }
        }

        ///// UPDATE VAMM VARS AFTER SWAP /////
        if (state.tick != self.vars.tick) {
            // update the tick in case it changed
            (self.vars.observationIndex, self.vars.observationCardinality) = self.vars.observations.write(
                self.vars.observationIndex,
                Time.blockTimestampTruncated(),
                self.vars.tick,
                0, // Liquidity not currently being tracked
                self.vars.observationCardinality,
                self.vars.observationCardinalityNext
            );
            (self.vars.sqrtPriceX96, self.vars.tick ) = (
                state.sqrtPriceX96,
                state.tick
            );
        } else {
            // otherwise just update the price
            self.vars.sqrtPriceX96 = state.sqrtPriceX96;
        }

        // update liquidity if it changed
        if (liquidityStart != state.liquidity) self.vars.liquidity = state.liquidity;

        self.vars.trackerBaseTokenGrowthGlobalX128 = state.trackerBaseTokenGrowthGlobalX128;
        self.vars.trackerQuoteTokenGrowthGlobalX128 = state.trackerQuoteTokenGrowthGlobalX128;

        emit VAMMBase.VAMMPriceChange(self.immutableConfig.marketId, self.immutableConfig.maturityTimestamp, self.vars.tick, block.timestamp);

        emit VAMMBase.Swap(
            self.immutableConfig.marketId,
            self.immutableConfig.maturityTimestamp,
            msg.sender,
            params.amountSpecified,
            params.sqrtPriceLimitX96,
            quoteTokenDelta,
            baseTokenDelta,
            block.timestamp
        );

        return (state.quoteTokenDeltaCumulative, state.baseTokenDeltaCumulative);
    }

    /// @notice For a given LP account, how much liquidity is available to trade in each direction.
    /// @param accountId The LP account. All positions within the account will be considered.
    /// @return unfilledBaseLong The base tokens available for a trader to take a long position against this LP (which will then become a short position for the LP) 
    /// @return unfilledBaseShort The base tokens available for a trader to take a short position against this LP (which will then become a long position for the LP) 
    function getAccountUnfilledBalances(
        Data storage self,
        uint128 accountId
    )
        internal
        view
        returns (
            uint256 unfilledBaseLong,
            uint256 unfilledBaseShort,
            uint256 unfilledQuoteLong,
            uint256 unfilledQuoteShort
        )
    {
        uint256 numPositions = self.vars.positionsInAccount[accountId].length;
        if (numPositions != 0) {
            for (uint256 i = 0; i < numPositions; i++) {
                // Get how liquidity is currently arranged. In particular, 
                // how much of the liquidity is available to traders in each direction?
                (
                    uint256 unfilledLongBase,
                    uint256 unfilledShortBase,
                    uint256 unfilledLongQuote,
                    uint256 unfilledShortQuote
                ) = 
                    self._getUnfilledBalancesFromPosition(
                        self.vars.positionsInAccount[accountId][i]
                    );
                unfilledBaseLong += unfilledLongBase;
                unfilledBaseShort += unfilledShortBase;
                unfilledQuoteLong += unfilledLongQuote;
                unfilledQuoteShort += unfilledShortQuote;
            }
        }
    }

    function _getUnfilledBalancesFromPosition(
        Data storage self,
        uint128 positionId
    )
        internal
        view
        returns ( uint256, uint256, uint256, uint256 ) {
        LPPosition.Data storage position = LPPosition.load(positionId);
        (
            uint256 unfilledShortBase,
            uint256 unfilledLongBase,
            uint256 unfilledShortQuote,
            uint256 unfilledLongQuote
        ) = _getUnfilledBaseTokenValues(
            self,
            position.tickLower,
            position.tickUpper,
            position.liquidity
        );

        return ( unfilledLongBase, unfilledShortBase, unfilledLongQuote, unfilledShortQuote);
    }

    // @dev For a given LP posiiton, how much of it is already traded and what are base and quote tokens representing those exiting trades?
    function getAccountFilledBalances(
        Data storage self,
        uint128 accountId
    )
        internal
        view
        returns (int256 baseBalancePool, int256 quoteBalancePool) {
        
        uint256 numPositions = self.vars.positionsInAccount[accountId].length;

        for (uint256 i = 0; i < numPositions; i++) {
            LPPosition.Data storage position = LPPosition.load(self.vars.positionsInAccount[accountId][i]);
            (int256 trackerQuoteTokenGlobalGrowth, int256 trackerBaseTokenGlobalGrowth) = 
                growthBetweenTicks(self, position.tickLower, position.tickUpper);
            (int256 trackerQuoteTokenAccumulated, int256 trackerBaseTokenAccumulated) = position.getUpdatedPositionBalances(trackerQuoteTokenGlobalGrowth, trackerBaseTokenGlobalGrowth); 

            baseBalancePool += trackerBaseTokenAccumulated;
            quoteBalancePool += trackerQuoteTokenAccumulated;
        }

    }

    /// @dev Private but labelled internal for testability.
    ///
    /// Gets the number of "unfilled" (still available as liquidity) base tokens within the specified tick range,
    /// looking both left and right of the current tick.
    function _getUnfilledBaseTokenValues(
        Data storage self,
        int24 tickLower,
        int24 tickUpper,
        uint128 liquidityPerTick
    ) internal view returns(
        uint256 unfilledBaseTokensLeft,
        uint256 unfilledBaseTokensRight,
        uint256 unfilledQuoteTokensLeft,
        uint256 unfilledQuoteTokensRight
    ) {
        if (tickLower == tickUpper) {
            return (0, 0, 0, 0);
        }

        uint256 secondsTillMaturity = self.immutableConfig.maturityTimestamp - block.timestamp;
        // Compute unfilled tokens in our range and to the left of the current tick
        (unfilledBaseTokensLeft, unfilledQuoteTokensLeft) = self._getUnfilledBalancesLeft(
            tickLower < self.vars.tick ? tickLower : self.vars.tick, // min(tickLower, currentTick)
            tickUpper < self.vars.tick ? tickUpper : self.vars.tick,  // min(tickUpper, currentTick)
            liquidityPerTick.toInt(),
            secondsTillMaturity
        );

        // Compute unfilled tokens in our range and to the right of the current tick
        (unfilledBaseTokensRight, unfilledQuoteTokensRight) = self._getUnfilledBalancesRight(
            tickLower > self.vars.tick ? tickLower : self.vars.tick, // max(tickLower, currentTick)
            tickUpper > self.vars.tick ? tickUpper : self.vars.tick,  // max(tickUpper, currentTick)
            liquidityPerTick.toInt(),
            secondsTillMaturity
        );
    }

    function _getUnfilledBalancesLeft(
        Data storage self,
        int24 leftLowerTick,
        int24 leftUpperTick,
        int128 liquidityPerTick,
        uint256 secondsTillMaturity
    ) 
        internal view
        returns (uint256, uint256) {
        
        uint256 unfilledBaseTokensLeft = self.baseBetweenTicks(
            leftLowerTick,
            leftUpperTick,
            liquidityPerTick
        ).toUint();

        if ( unfilledBaseTokensLeft == 0 ) {
            return (0, 0);
        }

        // unfilledBaseTokensLeft is negative
        int256 unbalancedQuoteTokensLeft = self.unbalancedQuoteBetweenTicks(
            leftLowerTick,
            leftUpperTick,
            -(unfilledBaseTokensLeft).toInt()
        );
        // note calculateQuoteTokenDelta considers spread in advantage (for LPs)
        uint256 unfilledQuoteTokensLeft = VAMMBase.calculateQuoteTokenDelta(
            unbalancedQuoteTokensLeft,
            -(unfilledBaseTokensLeft).toInt(),
            FixedAndVariableMath.accrualFact(secondsTillMaturity),
            self.mutableConfig.rateOracle.getCurrentIndex(),
            self.mutableConfig.spread
        ).toUint();

        return (unfilledBaseTokensLeft, unfilledQuoteTokensLeft);
    }

    function _getUnfilledBalancesRight(
        Data storage self,
        int24 rightLowerTick,
        int24 rightUpperTick,
        int128 liquidityPerTick,
        uint256 secondsTillMaturity
    ) 
        internal view
        returns (uint256, uint256){
        
        uint256 unfilledBaseTokensRight = self.baseBetweenTicks(
            rightLowerTick,
            rightUpperTick,
            liquidityPerTick
        ).toUint();

        if ( unfilledBaseTokensRight == 0 ) {
            return (0, 0);
        }

        // unbalancedQuoteTokensRight is positive
        int256 unbalancedQuoteTokensRight = self.unbalancedQuoteBetweenTicks(
            rightLowerTick,
            rightUpperTick,
            unfilledBaseTokensRight.toInt()
        );

        // unfilledQuoteTokensRight is negative
        uint256 unfilledQuoteTokensRight = (-VAMMBase.calculateQuoteTokenDelta(
            unbalancedQuoteTokensRight,
            unfilledBaseTokensRight.toInt(),
            FixedAndVariableMath.accrualFact(secondsTillMaturity),
            self.mutableConfig.rateOracle.getCurrentIndex(),
            self.mutableConfig.spread
        )).toUint();

        return (unfilledBaseTokensRight, unfilledQuoteTokensRight);
    }

    function growthBetweenTicks(
        Data storage self,
        int24 tickLower,
        int24 tickUpper
    ) internal view returns (
        int256 trackerQuoteTokenGrowthBetween,
        int256 trackerBaseTokenGrowthBetween
    )
    {
        checkTicksLimits(tickLower, tickUpper);

        int256 trackerQuoteTokenBelowLowerTick;
        int256 trackerBaseTokenBelowLowerTick;

        if (tickLower <= self.vars.tick) {
            trackerQuoteTokenBelowLowerTick = self.vars._ticks[tickLower].trackerQuoteTokenGrowthOutsideX128;
            trackerBaseTokenBelowLowerTick = self.vars._ticks[tickLower].trackerBaseTokenGrowthOutsideX128;
        } else {
            trackerQuoteTokenBelowLowerTick = self.vars.trackerQuoteTokenGrowthGlobalX128 -
                self.vars._ticks[tickLower].trackerQuoteTokenGrowthOutsideX128;
            trackerBaseTokenBelowLowerTick = self.vars.trackerBaseTokenGrowthGlobalX128 -
                self.vars._ticks[tickLower].trackerBaseTokenGrowthOutsideX128;
        }

        int256 trackerQuoteTokenAboveUpperTick;
        int256 trackerBaseTokenAboveUpperTick;

        if (tickUpper > self.vars.tick) {
            trackerQuoteTokenAboveUpperTick = self.vars._ticks[tickUpper].trackerQuoteTokenGrowthOutsideX128;
            trackerBaseTokenAboveUpperTick = self.vars._ticks[tickUpper].trackerBaseTokenGrowthOutsideX128;
        } else {
            trackerQuoteTokenAboveUpperTick = self.vars.trackerQuoteTokenGrowthGlobalX128 -
                self.vars._ticks[tickUpper].trackerQuoteTokenGrowthOutsideX128;
            trackerBaseTokenAboveUpperTick = self.vars.trackerBaseTokenGrowthGlobalX128 -
                self.vars._ticks[tickUpper].trackerBaseTokenGrowthOutsideX128;
        }

        trackerQuoteTokenGrowthBetween = self.vars.trackerQuoteTokenGrowthGlobalX128 - trackerQuoteTokenBelowLowerTick - trackerQuoteTokenAboveUpperTick;
        trackerBaseTokenGrowthBetween = self.vars.trackerBaseTokenGrowthGlobalX128 - trackerBaseTokenBelowLowerTick - trackerBaseTokenAboveUpperTick;

    }

    function computeGrowthInside(
        Data storage self,
        int24 tickLower,
        int24 tickUpper
    )
        internal
        view
        returns (int256 quoteTokenGrowthInsideX128, int256 baseTokenGrowthInsideX128)
    {

        checkTicksLimits(tickLower, tickUpper);

        baseTokenGrowthInsideX128 = self.vars._ticks.getBaseTokenGrowthInside(
            Tick.BaseTokenGrowthInsideParams({
                tickLower: tickLower,
                tickUpper: tickUpper,
                tickCurrent: self.vars.tick,
                baseTokenGrowthGlobalX128: self.vars.trackerBaseTokenGrowthGlobalX128
            })
        );

        quoteTokenGrowthInsideX128 = self.vars._ticks.getQuoteTokenGrowthInside(
            Tick.QuoteTokenGrowthInsideParams({
                tickLower: tickLower,
                tickUpper: tickUpper,
                tickCurrent: self.vars.tick,
                quoteTokenGrowthGlobalX128: self.vars.trackerQuoteTokenGrowthGlobalX128
            })
        );

    }

    function getSqrtRatioAtTickSafe(Data storage self, int24 tick) internal view returns (uint160 sqrtPriceX96){
        uint256 absTick = tick < 0
            ? uint256(-int256(tick))
            : uint256(int256(tick));
        require(absTick <= uint256(int256(self.mutableConfig.maxTick)), "T");

        sqrtPriceX96 = TickMath.getSqrtRatioAtTick(tick);
    }

    function getTickAtSqrtRatioSafe(Data storage self, uint160 sqrtPriceX96) internal view returns (int24 tick){
        // second inequality must be < because the price can never reach the price at the max tick
        require(
            sqrtPriceX96 >= self.minSqrtRatio &&
                sqrtPriceX96 < self.maxSqrtRatio,
            "R"
        );

        tick = TickMath.getTickAtSqrtRatio(sqrtPriceX96);
    }

    function flipTicks(
        Data storage self,
        int24 tickLower,
        int24 tickUpper,
        int128 liquidityDelta
    )
        internal
        returns (
            bool flippedLower,
            bool flippedUpper
        )
    {
        /// @dev isUpper = false
        flippedLower = self.vars._ticks.update(
            tickLower,
            self.vars.tick,
            liquidityDelta,
            self.vars.trackerQuoteTokenGrowthGlobalX128,
            self.vars.trackerBaseTokenGrowthGlobalX128,
            false,
            self.immutableConfig._maxLiquidityPerTick
        );

        /// @dev isUpper = true
        flippedUpper = self.vars._ticks.update(
            tickUpper,
            self.vars.tick,
            liquidityDelta,
            self.vars.trackerQuoteTokenGrowthGlobalX128,
            self.vars.trackerBaseTokenGrowthGlobalX128,
            true,
            self.immutableConfig._maxLiquidityPerTick
        );

        if (flippedLower) {
            self.vars._tickBitmap.flipTick(tickLower, self.immutableConfig._tickSpacing);
        }

        if (flippedUpper) {
            self.vars._tickBitmap.flipTick(tickUpper, self.immutableConfig._tickSpacing);
        }
    }

    /// @dev Common checks for valid tick inputs inside the min & max ticks
    function checkTicksInRange(Data storage self, int24 tickLower, int24 tickUpper) internal view {
        require(tickLower < tickUpper, "TLUR");
        require(tickLower >= self.mutableConfig.minTick, "TLMR");
        require(tickUpper <= self.mutableConfig.maxTick, "TUMR");
    }

    /// @dev Common checks for valid tick inputs inside the tick limits
    function checkTicksLimits(int24 tickLower, int24 tickUpper) internal pure {
        require(tickLower < tickUpper, "TLUL");
        require(tickLower >= TickMath.MIN_TICK_LIMIT, "TLML");
        require(tickUpper <= TickMath.MAX_TICK_LIMIT, "TUML");
    }

    function checksBeforeSwap(
        Data storage self,
        int256 amountSpecified,
        uint160 sqrtPriceLimitX96,
        bool isFT
    ) internal view {

        if (amountSpecified == 0) {
            revert CustomErrors.IRSNotionalAmountSpecifiedMustBeNonZero();
        }

        /// @dev if a trader is an FT, they consume fixed in return for variable
        /// @dev Movement from right to left along the VAMM, hence the sqrtPriceLimitX96 needs to be higher than the current sqrtPriceX96, but lower than the MAX_SQRT_RATIO
        /// @dev if a trader is a VT, they consume variable in return for fixed
        /// @dev Movement from left to right along the VAMM, hence the sqrtPriceLimitX96 needs to be lower than the current sqrtPriceX96, but higher than the MIN_SQRT_RATIO

        require(
            isFT
                ? sqrtPriceLimitX96 > self.vars.sqrtPriceX96 &&
                    sqrtPriceLimitX96 < self.maxSqrtRatio
                : sqrtPriceLimitX96 < self.vars.sqrtPriceX96 &&
                    sqrtPriceLimitX96 > self.minSqrtRatio,
            "SPL"
        );
    }

    /// @dev Computes the agregate amount of base between two ticks, given a tick range and the amount of liquidity per tick.
    /// The answer must be a valid `int256`. Reverts on overflow.
    function baseBetweenTicks(
        Data storage self,
        int24 _tickLower,
        int24 _tickUpper,
        int128 _liquidityPerTick
    ) internal view returns(int256) {
        // get sqrt ratios
        uint160 sqrtRatioAX96 = self.getSqrtRatioAtTickSafe(_tickLower);

        uint160 sqrtRatioBX96 = self.getSqrtRatioAtTickSafe(_tickUpper);

        return VAMMBase.baseAmountFromLiquidity(_liquidityPerTick, sqrtRatioAX96, sqrtRatioBX96);
    }

    function unbalancedQuoteBetweenTicks(
        Data storage self,
        int24 _tickLower,
        int24 _tickUpper,
        int256 baseAmount
    ) internal view returns(int256) {
        // get sqrt ratios
        uint160 sqrtRatioAX96 = self.getSqrtRatioAtTickSafe(_tickLower);

        uint160 sqrtRatioBX96 = self.getSqrtRatioAtTickSafe(_tickUpper);

        return VAMMBase.unbalancedQuoteAmountFromBase(baseAmount, sqrtRatioAX96, sqrtRatioBX96);
    }

    function getPriceFromTick(Data storage self, int24 _tick) internal view returns (UD60x18 price) {
        uint160 sqrtPriceX96 = self.getSqrtRatioAtTickSafe(_tick);
        uint256 priceX96 = FullMath.mulDiv(sqrtPriceX96, sqrtPriceX96, FixedPoint96.Q96);
        return UD60x18.wrap(FullMath.mulDiv(1e18, FixedPoint96.Q96, priceX96));
    }
}
