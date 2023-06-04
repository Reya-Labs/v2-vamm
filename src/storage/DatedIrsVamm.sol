// SPDX-License-Identifier: MIT
pragma solidity >=0.8.13;

import "./LPPosition.sol";

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
    UD60x18 constant ZERO = UD60x18.wrap(0);
    using SafeCastU256 for uint256;
    using SafeCastI256 for int256;
    using SafeCastU128 for uint128;
    using VAMMBase for VAMMBase.FlipTicksParams;
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
        uint16 observationCardinalityNextNew
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
            if (orderSize == 0) {
                revert TwapNotAdjustable();
            }
            spreadImpactDelta = self.mutableConfig.spread;
        }

        if (adjustForPriceImpact) {
            if (orderSize == 0) {
                revert TwapNotAdjustable();
            }
            priceImpactAsFraction = self.mutableConfig.priceImpactPhi.mul(
                convert(uint256(orderSize > 0 ? orderSize : -orderSize)).pow(self.mutableConfig.priceImpactBeta)
            );
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
            emit IncreaseObservationCardinalityNext(self.immutableConfig.marketId, self.immutableConfig.maturityTimestamp, observationCardinalityNextOld, observationCardinalityNextNew);
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
        (LPPosition.Data storage position, bool newlyCreated) = LPPosition._ensurePositionOpened(accountId, tickLower, tickUpper);
        if (newlyCreated) {
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

        _updateLiquidity(self, accountId, tickLower, tickUpper, liquidityDelta);
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
                int256 _fixedTokenGrowthInsideX128,
                int256 _baseTokenGrowthInsideX128
            ) = self.computeGrowthInside(tickLower, tickUpper);
            (int256 _fixedTokenDelta, int256 _baseTokenDelta) = position
                .calculateFixedAndVariableDelta(
                    _fixedTokenGrowthInsideX128,
                    _baseTokenGrowthInsideX128
                );
            
            position.updateTrackers(
                _fixedTokenGrowthInsideX128,
                _baseTokenGrowthInsideX128,
                _fixedTokenDelta,
                _baseTokenDelta // todo: why were these "- 1" in v1?
            );
        } else {
            if (isMintBurn) {
                (
                    int256 _fixedTokenGrowthInsideX128,
                    int256 _baseTokenGrowthInsideX128
                ) = self.computeGrowthInside(tickLower, tickUpper);
                position.updateTrackers(
                    _fixedTokenGrowthInsideX128,
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
        uint128 accountId,
        int24 tickLower,
        int24 tickUpper,
        int128 liquidityDelta
    ) internal
      lock(self)
    {
        VAMMBase.checkCurrentTimestampMaturityTimestampDelta(self.immutableConfig.maturityTimestamp);

        Tick.checkTicks(tickLower, tickUpper);

        bool flippedLower;
        bool flippedUpper;

        /// @dev update the ticks if necessary
        if (liquidityDelta != 0) {

            VAMMBase.FlipTicksParams memory params;
            params.tickLower = tickLower;
            params.tickUpper = tickUpper;
            params.liquidityDelta = liquidityDelta;
            (flippedLower, flippedUpper) = params.flipTicks(
                self.vars._ticks,
                self.vars._tickBitmap,
                self.vars,
                VAMMBase.VammData({
                    _trackerFixedTokenGrowthGlobalX128: self.vars.trackerFixedTokenGrowthGlobalX128,
                    _trackerBaseTokenGrowthGlobalX128: self.vars.trackerBaseTokenGrowthGlobalX128,
                    _maxLiquidityPerTick: self.immutableConfig._maxLiquidityPerTick,
                    _tickSpacing: self.immutableConfig._tickSpacing
                })
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

        emit VAMMBase.LiquidityChange(self.immutableConfig.marketId, self.immutableConfig.maturityTimestamp, msg.sender, accountId, tickLower, tickUpper, liquidityDelta);
    }

    function vammSwap(
        Data storage self,
        VAMMBase.SwapParams memory params
    )
        internal
        lock(self)
        returns (int256 trackerFixedTokenDelta, int256 trackerBaseTokenDelta)
    {
        VAMMBase.checkCurrentTimestampMaturityTimestampDelta(self.immutableConfig.maturityTimestamp);

        VAMMBase.checksBeforeSwap(params, self.vars, params.amountSpecified > 0);

        uint128 liquidityStart = self.vars.liquidity;

        VAMMBase.SwapState memory state = VAMMBase.SwapState({
            amountSpecifiedRemaining: params.amountSpecified, // base ramaining
            sqrtPriceX96: self.vars.sqrtPriceX96,
            tick: self.vars.tick,
            liquidity: liquidityStart,
            trackerFixedTokenGrowthGlobalX128: self.vars.trackerFixedTokenGrowthGlobalX128,
            trackerBaseTokenGrowthGlobalX128: self.vars.trackerBaseTokenGrowthGlobalX128,
            trackerFixedTokenDeltaCumulative: 0, // for Trader (user invoking the swap)
            trackerBaseTokenDeltaCumulative: 0 // for Trader (user invoking the swap)
        });

        // The following are used n times within the loop, but will not change so they are calculated here
        uint256 secondsTillMaturity = self.immutableConfig.maturityTimestamp - block.timestamp;

        // continue swapping as long as we haven't used the entire input/output and haven't reached the price (implied fixed rate) limit
        bool advanceRight = params.amountSpecified > 0;
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
            if (params.amountSpecified > 0 && step.tickNext > TickMath.MAX_TICK) {
                step.tickNext = TickMath.MAX_TICK;
            }
            if (!(params.amountSpecified > 0) && step.tickNext < TickMath.MIN_TICK) {
                step.tickNext = TickMath.MIN_TICK;
            }
            // get the price for the next tick
            step.sqrtPriceNextX96 = TickMath.getSqrtRatioAtTick(step.tickNext);
            //FT
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
                    liquidity: state.liquidity,
                    amountRemaining: state.amountSpecifiedRemaining,
                    timeToMaturityInSeconds: secondsTillMaturity
                })
            );

            ///// UPDATE TRACKERS /////
            if(params.amountSpecified > 0) {
                step.baseInStep -= step.amountIn.toInt();
                // LP is a Variable Taker
                step.trackerBaseTokenDelta = (step.amountIn).toInt(); // this is positive
            } else {
                step.baseInStep += step.amountOut.toInt();
                // LP is a Fixed Taker
                step.trackerBaseTokenDelta -= step.amountOut.toInt();
            }
            state.amountSpecifiedRemaining += step.baseInStep;

            if (state.liquidity > 0) {
                (
                    state.trackerFixedTokenGrowthGlobalX128,
                    state.trackerBaseTokenGrowthGlobalX128,
                    step.trackerFixedTokenDelta
                ) = VAMMBase._calculateUpdatedGlobalTrackerValues( 
                    state,
                    step,
                    FixedAndVariableMath.accrualFact(secondsTillMaturity),
                    self.mutableConfig.rateOracle.getCurrentIndex()
                );

                state.trackerFixedTokenDeltaCumulative -= step.trackerFixedTokenDelta; // fixedTokens; opposite sign from that of the LP's
                state.trackerBaseTokenDeltaCumulative -= step.trackerBaseTokenDelta; // opposite sign from that of the LP's
            }

            ///// UPDATE TICK AFTER SWAP STEP /////

            // shift tick if we reached the next price
            if (state.sqrtPriceX96 == step.sqrtPriceNextX96) {
                // if the tick is initialized, run the tick transition
                if (step.initialized) {
                    int128 liquidityNet = self.vars._ticks.cross(
                        step.tickNext,
                        state.trackerFixedTokenGrowthGlobalX128,
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
        self.vars.trackerFixedTokenGrowthGlobalX128 = state.trackerFixedTokenGrowthGlobalX128;

        emit VAMMBase.VAMMPriceChange(self.immutableConfig.marketId, self.immutableConfig.maturityTimestamp, self.vars.tick);

        emit VAMMBase.Swap(
            self.immutableConfig,
            msg.sender,
            params.amountSpecified,
            params.sqrtPriceLimitX96,
            trackerFixedTokenDelta,
            trackerBaseTokenDelta
        );

        return (state.trackerFixedTokenDeltaCumulative, state.trackerBaseTokenDeltaCumulative);
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
        view
        returns (uint256 unfilledBaseLong, uint256 unfilledBaseShort)
    {
        uint256 numPositions = self.vars.positionsInAccount[accountId].length;
        if (numPositions != 0) {
            for (uint256 i = 0; i < numPositions; i++) {
                LPPosition.Data storage position = LPPosition.load(self.vars.positionsInAccount[accountId][i]);
                // Get how liquidity is currently arranged. In particular, how much of the liquidity is avail to traders in each direction?
                (uint256 unfilledShortBase, uint256 unfilledLongBase) = _getUnfilledBaseTokenValues(
                    self,
                    position.tickLower,
                    position.tickUpper,
                    position.liquidity
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
        view
        returns (int256 baseBalancePool, int256 quoteBalancePool) {
        
        uint256 numPositions = self.vars.positionsInAccount[accountId].length;

        for (uint256 i = 0; i < numPositions; i++) {
            LPPosition.Data storage position = LPPosition.load(self.vars.positionsInAccount[accountId][i]);
            (int256 trackerFixedTokenGlobalGrowth, int256 trackerBaseTokenGlobalGrowth) = 
                growthBetweenTicks(self, position.tickLower, position.tickUpper);
            (int256 trackerFixedTokenAccumulated, int256 trackerBaseTokenAccumulated) = position.getUpdatedPositionBalances(trackerFixedTokenGlobalGrowth, trackerBaseTokenGlobalGrowth); 

            baseBalancePool += trackerBaseTokenAccumulated;
            quoteBalancePool += trackerFixedTokenAccumulated;
        }

    }

    /// @dev Private but labelled internal for testability.
    ///
    /// Gets the number of "unfilled" (still available as liquidity) base tokens within the specified tick range,
    /// looking both left and right of the current tick.
    function _getUnfilledBaseTokenValues( // TODO: previously called trackValuesBetweenTicks; update python code to match new name
        Data storage self,
        int24 tickLower,
        int24 tickUpper,
        uint128 liquidityPerTick
    ) internal view returns(
        uint256 unfilledBaseTokensLeft,
        uint256 unfilledBaseTokensRight
    ) {
        if (tickLower == tickUpper) {
            return (0, 0);
        }

        // Compute unfilled tokens in our range and to the left of the current tick
        int256 unfilledBaseTokensLeft_ = VAMMBase.baseBetweenTicks(
            tickLower < self.vars.tick ? tickLower : self.vars.tick, // min(tickLower, currentTick)
            tickUpper < self.vars.tick ? tickUpper : self.vars.tick,  // min(tickUpper, currentTick)
            liquidityPerTick.toInt()
        );
        unfilledBaseTokensLeft = unfilledBaseTokensLeft_.toUint();

        // Compute unfilled tokens in our range and to the right of the current tick
        unfilledBaseTokensRight = VAMMBase.baseBetweenTicks(
            tickLower > self.vars.tick ? tickLower : self.vars.tick, // max(tickLower, currentTick)
            tickUpper > self.vars.tick ? tickUpper : self.vars.tick,  // max(tickUpper, currentTick)
            liquidityPerTick.toInt()
        ).toUint();
    }

    function growthBetweenTicks(
        Data storage self,
        int24 tickLower,
        int24 tickUpper
    ) internal view returns (
        int256 trackerFixedTokenGrowthBetween,
        int256 trackerBaseTokenGrowthBetween
    )
    {
        Tick.checkTicks(tickLower, tickUpper);

        int256 trackerFixedTokenBelowLowerTick;
        int256 trackerBaseTokenBelowLowerTick;

        if (tickLower <= self.vars.tick) {
            trackerFixedTokenBelowLowerTick = self.vars._ticks[tickLower].trackerFixedTokenGrowthOutsideX128;
            trackerBaseTokenBelowLowerTick = self.vars._ticks[tickLower].trackerBaseTokenGrowthOutsideX128;
        } else {
            trackerFixedTokenBelowLowerTick = self.vars.trackerFixedTokenGrowthGlobalX128 -
                self.vars._ticks[tickLower].trackerFixedTokenGrowthOutsideX128;
            trackerBaseTokenBelowLowerTick = self.vars.trackerBaseTokenGrowthGlobalX128 -
                self.vars._ticks[tickLower].trackerBaseTokenGrowthOutsideX128;
        }

        int256 trackerFixedTokenAboveUpperTick;
        int256 trackerBaseTokenAboveUpperTick;

        if (tickUpper > self.vars.tick) {
            trackerFixedTokenAboveUpperTick = self.vars._ticks[tickUpper].trackerFixedTokenGrowthOutsideX128;
            trackerBaseTokenAboveUpperTick = self.vars._ticks[tickUpper].trackerBaseTokenGrowthOutsideX128;
        } else {
            trackerFixedTokenAboveUpperTick = self.vars.trackerFixedTokenGrowthGlobalX128 -
                self.vars._ticks[tickUpper].trackerFixedTokenGrowthOutsideX128;
            trackerBaseTokenAboveUpperTick = self.vars.trackerBaseTokenGrowthGlobalX128 -
                self.vars._ticks[tickUpper].trackerBaseTokenGrowthOutsideX128;
        }

        trackerFixedTokenGrowthBetween = self.vars.trackerFixedTokenGrowthGlobalX128 - trackerFixedTokenBelowLowerTick - trackerFixedTokenAboveUpperTick;
        trackerBaseTokenGrowthBetween = self.vars.trackerBaseTokenGrowthGlobalX128 - trackerBaseTokenBelowLowerTick - trackerBaseTokenAboveUpperTick;

    }

    function computeGrowthInside(
        Data storage self,
        int24 tickLower,
        int24 tickUpper
    )
        internal
        view
        returns (int256 fixedTokenGrowthInsideX128, int256 baseTokenGrowthInsideX128)
    {

        Tick.checkTicks(tickLower, tickUpper);

        baseTokenGrowthInsideX128 = self.vars._ticks.getBaseTokenGrowthInside(
            Tick.BaseTokenGrowthInsideParams({
                tickLower: tickLower,
                tickUpper: tickUpper,
                tickCurrent: self.vars.tick,
                baseTokenGrowthGlobalX128: self.vars.trackerBaseTokenGrowthGlobalX128
            })
        );

        fixedTokenGrowthInsideX128 = self.vars._ticks.getFixedTokenGrowthInside(
            Tick.FixedTokenGrowthInsideParams({
                tickLower: tickLower,
                tickUpper: tickUpper,
                tickCurrent: self.vars.tick,
                fixedTokenGrowthGlobalX128: self.vars.trackerFixedTokenGrowthGlobalX128
            })
        );

    }
}
