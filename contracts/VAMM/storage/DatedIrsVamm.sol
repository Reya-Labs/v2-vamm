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
import "prb-math/contracts/PRBMathUD60x18.sol";
import "prb-math/contracts/PRBMathSD59x18.sol";
import "../libraries/FixedAndVariableMath.sol";
import "../../utils/FixedPoint128.sol";
import "../libraries/VAMMBase.sol";

/**
 * @title Connects external contracts that implement the `IVAMM` interface to the protocol.
 *
 */
library DatedIrsVamm {

    using SafeCastUni for uint256;
    using SafeCastUni for int256;
    using VAMMBase for VAMMBase.FlipTicksParams;
    using VAMMBase for bool;
    using Tick for mapping(int24 => Tick.Info);
    using TickBitmap for mapping(int16 => uint256);

    /**
     * @dev Thrown when a specified vamm is not found.
     */
    error IRSVammNotFound(uint128 vammId);

    struct LPPosition {
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
        uint256 id;
        /**
         * Note: maybe we can find a better way of identifying a market than just a simple id
         */
        uint128 marketId;
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
        /**
         * @dev Maps from position ID (see `getPositionId` to the properties of that position
         */
        mapping(uint256 => LPPosition) positions;
        /**
         * @dev Maps from an account address to a list of the position IDs of positions associated with that account address. Use the `positions` mapping to see full details of any given `LPPosition`.
         */
        mapping(uint128 => uint256[]) positionsInAccount;

        address gtwapOracle; // TODO: replace with GWAP interface
        uint256 termEndTimestampWad;
        uint128 _maxLiquidityPerTick;
        bool _unlocked; // Mutex
        uint128 _accumulator;
        int256 _tracker0GrowthGlobalX128;
        int256 _tracker1GrowthGlobalX128;
        int24 _tickSpacing;
        mapping(int24 => Tick.Info) _ticks;
        mapping(int16 => uint256) _tickBitmap;
        VAMMBase.VAMMVars _vammVars;
        mapping(address => bool) pauser;
        bool paused;
    }

    /**
     * @dev Returns the vamm stored at the specified vamm id.
     */
    function load(uint256 id) internal pure returns (Data storage irsVamm) {
        bytes32 s = keccak256(abi.encode("xyz.voltz.DatedIRSVamm", id));
        assembly {
            irsVamm.slot := s
        }
    }

    /**
     * @dev Finds the vamm id using market id and maturity and
     * returns the vamm stored at the specified vamm id.
     */
    function loadByMaturityAndMarket(uint128 marketId, uint256 maturityTimestamp) internal pure returns (Data storage irsVamm) {
        uint256 id = uint256(keccak256(abi.encodePacked(marketId, maturityTimestamp)));
        return load(id);
    }

    /**
     * @dev Reverts if the caller is not the owner of the specified vamm
     */
    function onlyVAMMOwner(uint256 vammId, address caller) internal view {
        if (DatedIrsVamm.load(vammId).owner != caller) {
            revert AccessError.Unauthorized(caller);
        }
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

        require(position.baseAmount + requestedBaseAmount >= 0, "Burning too much");

        vammMint(self, msg.sender, tickLower, tickUpper, requestedBaseAmount);

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

        if(self.positions[positionId].accountId == 0) {
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

        // TODO: check/enforce assertion that zero is not a valid account ID
        require(self.positions[positionId].accountId != 0, "Missing position");
        
        propagatePosition(self, positionId);
        return self.positions[positionId];
    }

    function propagatePosition(
        Data storage self,
        uint256 positionId
    )
        internal {

        LPPosition memory position = self.positions[positionId];

        (int256 tracker0GlobalGrowth, int256 tracker1GlobalGrowth) = 
            growthBetweenTicks(self, position.tickLower, position.tickUpper);

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

    function changePauser(Data storage self, address account, bool permission) internal {
      // not sure if msg.sender is the caller
      onlyVAMMOwner(self.id, msg.sender);
      self.pauser[account] = permission;
    }

    function setPausability(Data storage self, bool state) internal {
        require(self.pauser[msg.sender], "no role");
        self.paused = state;
    }

    // TODO: move in Creator
    // constructor(address _gtwapOracle, uint256 _termEndTimestampWad, int24 __tickSpacing) {

    //     // tick spacing is capped at 16384 to prevent the situation where tickSpacing is so large that
    //     // TickBitmap#nextInitializedTickWithinOneWord overflows int24 container from a valid tick
    //     // 16384 ticks represents a >5x price change with ticks of 1 bips
    //     require(__tickSpacing > 0 && __tickSpacing < Tick.MAXIMUM_TICK_SPACING, "TSOOB");

    //     gtwapOracle = _gtwapOracle;
    //     _tickSpacing = __tickSpacing;
    //     _maxLiquidityPerTick = Tick.tickSpacingToMaxLiquidityPerTick(_tickSpacing);
    //     termEndTimestampWad = _termEndTimestampWad;

    //     __Ownable_init();
    //     __UUPSUpgradeable_init();
    // }

    /// GETTERS & TRACKERS

    function getAverageBase(
        int24 tickLower,
        int24 tickUpper,
        int128 baseAmount
    ) internal pure returns(int128) {
        return baseAmount / (tickUpper - tickLower);
    }

    function trackFixedTokens(
      int256 baseAmount,
      int24 tickLower,
      int24 tickUpper,
      uint256 termEndTimestampWad
    )
        internal
        view
        returns (
            int256 trackedValue
        )
    {

        uint160 averagePrice = (TickMath.getSqrtRatioAtTick(tickUpper) + TickMath.getSqrtRatioAtTick(tickLower)) / 2;
        uint256 timeDeltaUntilMaturity = FixedAndVariableMath.accrualFact(termEndTimestampWad - Time.blockTimestampScaled()); 

        // TODO: needs library
        // self.oracle.latest() TODO: implement Oracle
        trackedValue = ( ( -baseAmount * 100 ) / 1e18 ) * ( ( uint256(averagePrice).toInt256() * int256(timeDeltaUntilMaturity) ) / 1e18  + 1e18);
    }

    function refreshGTWAPOracle(Data storage self, address _gtwapOracle)
        internal
    {
        self.gtwapOracle = _gtwapOracle;
    }

    // TODO: return data
    function vammMint(
        Data storage self,
        address recipient,
        int24 tickLower,
        int24 tickUpper,
        int128 baseAmount
    ) internal {
        self.paused.whenNotPaused();
        VAMMBase.checkCurrentTimestampTermEndTimestampDelta(self.termEndTimestampWad);
        self._unlocked.lock();

        Tick.checkTicks(tickLower, tickUpper);

        VAMMBase.VAMMVars memory lvammVars = self._vammVars; // SLOAD for gas optimization

        bool flippedLower;
        bool flippedUpper;

        int128 averageBase = getAverageBase(tickLower, tickUpper, baseAmount);

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
                self._tracker0GrowthGlobalX128,
                self._tracker1GrowthGlobalX128,
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

        self._unlocked.unlock();

        emit VAMMBase.Mint(msg.sender, recipient, tickLower, tickUpper, baseAmount);
    }

    function vammSwap(
        Data storage self,
        VAMMBase.SwapParams memory params
    )
        internal
        returns (int256 tracker0Delta, int256 tracker1Delta)
    {
        self.paused.whenNotPaused();
        VAMMBase.checkCurrentTimestampTermEndTimestampDelta(self.termEndTimestampWad);

        Tick.checkTicks(params.tickLower, params.tickUpper);

        VAMMBase.VAMMVars memory vammVarsStart = self._vammVars;

        VAMMBase.checksBeforeSwap(params, vammVarsStart, params.amountSpecified > 0);

        /// @dev lock the vamm while the swap is taking place
        self._unlocked.lock();

        uint128 accumulatorStart = self._accumulator;

        VAMMBase.SwapState memory state = VAMMBase.SwapState({
            amountSpecifiedRemaining: params.amountSpecified, // base ramaining
            sqrtPriceX96: vammVarsStart.sqrtPriceX96,
            tick: vammVarsStart.tick,
            accumulator: accumulatorStart,
            tracker0GrowthGlobalX128: self._tracker0GrowthGlobalX128,
            tracker1GrowthGlobalX128: self._tracker1GrowthGlobalX128,
            tracker0DeltaCumulative: 0, // for Trader (user invoking the swap)
            tracker1DeltaCumulative: 0 // for Trader (user invoking the swap)
        });

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
                    timeToMaturityInSecondsWad: self.termEndTimestampWad - Time.blockTimestampScaled()
                })
            );

            ///// UPDATE TRACKERS /////

            if(advanceRight) {
                step.baseInStep -= step.amountIn.toInt256();
                // LP is a Variable Taker
                step.tracker1Delta = (step.amountIn).toInt256();
            } else {
                step.baseInStep += step.amountOut.toInt256();
                // LP is a Fixed Taker
                step.tracker1Delta -= step.amountOut.toInt256();
            }
            state.amountSpecifiedRemaining += step.baseInStep;

            if (state.accumulator > 0) {
                (
                    state.tracker1GrowthGlobalX128,
                    state.tracker0GrowthGlobalX128,
                    step.tracker0Delta // for LP
                ) = calculateUpdatedGlobalTrackerValues( 
                    state,
                    step,
                    self.termEndTimestampWad
                );

                state.tracker0DeltaCumulative -= step.tracker0Delta; // opposite sign from that of the LP's
                state.tracker1DeltaCumulative -= step.tracker1Delta; // opposite sign from that of the LP's
            }

            ///// UPDATE TICK AFTER SWAP STEP /////

            // shift tick if we reached the next price
            if (state.sqrtPriceX96 == step.sqrtPriceNextX96) {
                // if the tick is initialized, run the tick transition
                if (step.initialized) {
                int128 accumulatorNet = self._ticks.cross(
                    step.tickNext,
                    state.tracker0GrowthGlobalX128,
                    state.tracker1GrowthGlobalX128,
                    0
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

        self._vammVars.sqrtPriceX96 = state.sqrtPriceX96;

        if (state.tick != vammVarsStart.tick) {
            // update the tick in case it changed
            self._vammVars.tick = state.tick;
        }

        // update liquidity if it changed
        if (accumulatorStart != state.accumulator) self._accumulator = state.accumulator;

        self._tracker1GrowthGlobalX128 = state.tracker1GrowthGlobalX128;
        self._tracker0GrowthGlobalX128 = state.tracker0GrowthGlobalX128;

        tracker0Delta = state.tracker0DeltaCumulative;
        tracker1Delta = state.tracker1DeltaCumulative;

        emit VAMMBase.VAMMPriceChange(self._vammVars.tick);

        emit VAMMBase.Swap(
            msg.sender,
            params.recipient,
            params.tickLower,
            params.tickUpper,
            params.amountSpecified,
            params.sqrtPriceLimitX96,
            tracker0Delta,
            tracker1Delta
        );

        self._unlocked.unlock();
    }

    function calculateUpdatedGlobalTrackerValues(
        VAMMBase.SwapState memory state,
        VAMMBase.StepComputations memory step,
        uint256 termEndTimestampWad
    )
        internal
        view
        returns (
            int256 stateVariableTokenGrowthGlobalX128,
            int256 stateFixedTokenGrowthGlobalX128,
            int256 tracker0Delta// for LP
        )
    {
        tracker0Delta = trackFixedTokens(
            step.baseInStep,
            state.tick,
            step.tickNext,
            termEndTimestampWad
        );

        // update global trackers
        stateVariableTokenGrowthGlobalX128 = state.tracker1GrowthGlobalX128 + FullMath.mulDivSigned(step.tracker1Delta, FixedPoint128.Q128, state.accumulator);

        stateFixedTokenGrowthGlobalX128 = state.tracker0GrowthGlobalX128 + FullMath.mulDivSigned(tracker0Delta, FixedPoint128.Q128, state.accumulator);
    }

    function trackValuesBetweenTicksOutside(
        Data storage self,
        int256 averageBase,
        int24 tickLower,
        int24 tickUpper
    ) internal view returns(
        int256 tracker0GrowthOutside,
        int256 tracker1GrowthOutside
    ) {
        if (tickLower == tickUpper) {
            return (0, 0);
        }

        int256 base = VAMMBase.baseBetweenTicks(tickLower, tickUpper, averageBase);

        tracker0GrowthOutside = trackFixedTokens(averageBase, tickLower, tickUpper, self.termEndTimestampWad);
        tracker1GrowthOutside = averageBase;

    }

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

                (int256 unfilledLong,, int256 unfilledShort,) = trackValuesBetweenTicks(
                    self,
                    position.tickLower,
                    position.tickUpper,
                    position.baseAmount
                );

                unfilledBaseLong += unfilledLong;
                unfilledBaseShort += unfilledShort;
            }
        }
    }

    function getAccountFilledBalances(
        Data storage self,
        uint128 accountId
    )
        internal
        returns (int256 baseBalancePool, int256 quoteBalancePool) {
        
        uint256 numPositions = self.positionsInAccount[accountId].length;

        for (uint256 i = 0; i < numPositions; i++) {
            LPPosition memory position = getRawPosition(self, self.positionsInAccount[accountId][i]); 

            baseBalancePool += position.tracker0Accumulated;
            quoteBalancePool += position.tracker1Accumulated;
        }

    }

    function trackValuesBetweenTicks(
        Data storage self,
        int24 tickLower,
        int24 tickUpper,
        int128 baseAmount
    ) internal view returns(
        int256 tracker0GrowthOutsideLeft,
        int256 tracker1GrowthOutsideLeft,
        int256 tracker0GrowthOutsideRight,
        int256 tracker1GrowthOutsideRight
    ) {
        if (tickLower == tickUpper) {
            return (0, 0, 0, 0);
        }

        int128 averageBase = getAverageBase(tickLower, tickUpper, baseAmount);

        (int256 tracker0GrowthOutsideLeft_, int256 tracker1GrowthOutsideLeft_) = trackValuesBetweenTicksOutside(
            self,
            averageBase,
            tickLower < self._vammVars.tick ? tickLower : self._vammVars.tick,
            tickUpper > self._vammVars.tick ? tickUpper : self._vammVars.tick
        );
        tracker0GrowthOutsideLeft = -tracker0GrowthOutsideLeft_;
        tracker1GrowthOutsideLeft = -tracker1GrowthOutsideLeft_;

        (tracker0GrowthOutsideRight, tracker1GrowthOutsideRight) = trackValuesBetweenTicksOutside(
            self,
            averageBase,
            tickLower < self._vammVars.tick ? tickLower : self._vammVars.tick,
            tickUpper > self._vammVars.tick ? tickUpper : self._vammVars.tick
        );

    }

    function growthBetweenTicks(
        Data storage self,
        int24 tickLower,
        int24 tickUpper
    ) internal view returns (
        int256 tracker0GrowthBetween,
        int256 tracker1GrowthBetween
    )
    {
        Tick.checkTicks(tickLower, tickUpper);

        int256 tracker0BelowLowerTick;
        int256 tracker1BelowLowerTick;

        if (tickLower <= self._vammVars.tick) {
            tracker0BelowLowerTick = self._ticks[tickLower].tracker0GrowthOutsideX128;
            tracker1BelowLowerTick = self._ticks[tickLower].tracker1GrowthOutsideX128;
        } else {
            tracker0BelowLowerTick = self._tracker0GrowthGlobalX128 -
                self._ticks[tickLower].tracker0GrowthOutsideX128;
            tracker1BelowLowerTick = self._tracker1GrowthGlobalX128 -
                self._ticks[tickLower].tracker1GrowthOutsideX128;
        }

        int256 tracker0AboveUpperTick;
        int256 tracker1AboveUpperTick;

        if (tickUpper > self._vammVars.tick) {
            tracker0AboveUpperTick = self._ticks[tickUpper].tracker0GrowthOutsideX128;
            tracker1AboveUpperTick = self._ticks[tickUpper].tracker1GrowthOutsideX128;
        } else {
            tracker0AboveUpperTick = self._tracker0GrowthGlobalX128 -
                self._ticks[tickUpper].tracker0GrowthOutsideX128;
            tracker1AboveUpperTick = self._tracker1GrowthGlobalX128 -
                self._ticks[tickUpper].tracker1GrowthOutsideX128;
        }

        tracker0GrowthBetween = self._tracker0GrowthGlobalX128 - tracker0BelowLowerTick - tracker0AboveUpperTick;
        tracker1GrowthBetween = self._tracker1GrowthGlobalX128 - tracker1BelowLowerTick - tracker1AboveUpperTick;

    }
}
