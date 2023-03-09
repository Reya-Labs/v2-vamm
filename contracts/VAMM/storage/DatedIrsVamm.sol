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
import "prb-math/contracts/PRBMathUD60x18.sol"; // TODO: update to latst vrsion and use custom types
import "prb-math/contracts/PRBMathSD59x18.sol";
import "../libraries/FixedAndVariableMath.sol";
import "../../utils/FixedPoint128.sol";
import "../libraries/VAMMBase.sol";
import "../../utils/CustomErrors.sol";
import "../libraries/Oracle.sol";

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
        /// @inheritdoc IVAMMBase
        IVAMMBase.VAMMVars _vammVars;
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
        string name; // TODO: necessary? If so, initialize.
        /**
         * @dev Creator of the vamm, which has configuration access rights for the vamm.
         *
         * See onlyVAMMOwner.
         */
        address owner; // TODO: move owner config to DatedIRSVammPool?
        /**
         * @dev Maps from position ID (see `getPositionId` to the properties of that position
         */
        mapping(uint256 => LPPosition) positions;
        /**
         * @dev Maps from an account address to a list of the position IDs of positions associated with that account address. Use the `positions` mapping to see full details of any given `LPPosition`.
         */
        mapping(uint128 => uint256[]) positionsInAccount;

        /// Circular buffer of Oracle Observations. Resizable but no more than type(uint16).max slots in the buffer
        Oracle.Observation[65535] observations;
        /// @dev the phi value to use when adjusting a TWAP price for the likely price impact of liquidation
        uint256 priceImpactPhi;
        /// @dev the beta value to use when adjusting a TWAP price for the likely price impact of liquidation
        uint256 priceImpactBeta;

        address gtwapOracle; // TODO: replace with GWAP interface
        uint256 termEndTimestampWad; // TODO: change to non-wad or to PRB Math type
        uint128 _maxLiquidityPerTick;
        uint128 _accumulator;
        int256 _tracker0GrowthGlobalX128;
        int256 _tracker1GrowthGlobalX128;
        int24 _tickSpacing;
        mapping(int24 => Tick.Info) _ticks;
        mapping(int16 => uint256) _tickBitmap;
        mapping(address => bool) pauser; // TODO: move pauser config to DatedIRSVammPool?
        bool paused; // TODO: move pause state to DatedIRSVammPool?
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
     * returns the vamm stored at the specified vamm id. Reverts if no such VAMM is found.
     */
    function loadByMaturityAndMarket(uint128 marketId, uint256 maturityTimestamp) internal view returns (Data storage irsVamm) {
        uint256 id = uint256(keccak256(abi.encodePacked(marketId, maturityTimestamp)));
        irsVamm = load(id);
        if (irsVamm.termEndTimestampWad == 0) {
            revert CustomErrors.MarketAndMaturityCombinaitonNotSupported(marketId, maturityTimestamp);
        }
    }

    /**
     * @dev Finds the vamm id using market id and maturity and
     * returns the vamm stored at the specified vamm id. Reverts if no such VAMM is found.
     */
    function createByMaturityAndMarket(uint128 marketId, uint256 maturityTimestamp,  uint160 sqrtPriceX96) internal returns (Data storage irsVamm) {
        require(maturityTimestamp != 0);
        uint256 id = uint256(keccak256(abi.encodePacked(marketId, maturityTimestamp)));
        irsVamm = load(id);
        if (irsVamm.termEndTimestampWad != 0) {
            revert CustomErrors.MarketAndMaturityCombinaitonAlreadyExists(marketId, maturityTimestamp);
        }
        initialize(irsVamm, sqrtPriceX96, maturityTimestamp, marketId);
    }

    /// @dev not locked because it initializes unlocked
    function initialize(Data storage self, uint160 sqrtPriceX96, uint256 _termEndTimestampWad, uint128 _marketId) internal {
        require(self._vammVars.sqrtPriceX96 == 0, 'AI');

        int24 tick = TickMath.getTickAtSqrtRatio(sqrtPriceX96);

        self.marketId = _marketId;
        self.termEndTimestampWad = _termEndTimestampWad;

        // TODO: add other VAMM config such as _maxLiquidityPerTick

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

        // emit Initialize(sqrtPriceX96, tick); // TODO: emit log for new VAMM, either here or in DatedIrsVAMMPool
    }

    /// @notice Calculates time-weighted geometric mean price based on the past `secondsAgo` seconds
    /// @param secondsAgo Number of seconds in the past from which to calculate the time-weighted means
    /// @param adjustForSpread Whether or not to adjust the returned price by the VAMM's configured spread.
    /// @param priceImpactOrderSize The order size to use when adjusting the price for price impact. Or `0` to ignore price impact.
    /// @return adjustedGeometricMeanPriceX96 The geometric mean price, adjusted according to requested parameters.
    function twap(Data storage self, uint32 secondsAgo, uint256 priceImpactOrderSize, bool adjustForSpread)
        internal
        view
        returns (uint256 adjustedGeometricMeanPriceX96) // TODO: expose result as PRB math instead?
    {
        int24 arithmeticMeanTick = observe(self, secondsAgo);

        // Not yet adjusted
        adjustedGeometricMeanPriceX96 = getPriceX96FromTick(arithmeticMeanTick);

        if (adjustForSpread) {
            // TODO
        }

        if (priceImpactOrderSize != 0) {
            // TODO
        }

        return adjustedGeometricMeanPriceX96;
    }

    function getPriceX96FromTick(int24 tick) public pure returns(uint256 priceX96) {
        uint160 sqrtPriceX96 = TickMath.getSqrtRatioAtTick(tick);
        return FullMath.mulDiv(sqrtPriceX96, sqrtPriceX96, FixedPoint96.Q96);
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

            (int56[] memory tickCumulatives, uint160[] memory secondsPerLiquidityCumulativeX128s) =
                observe(self, secondsAgos);

            int56 tickCumulativesDelta = tickCumulatives[1] - tickCumulatives[0];
            uint160 secondsPerLiquidityCumulativesDelta =
                secondsPerLiquidityCumulativeX128s[1] - secondsPerLiquidityCumulativeX128s[0];

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
     * @dev Reverts if the caller is not the owner of the specified vamm
     */
    function onlyVAMMOwner(Data storage self, address caller) internal view {
        if (self.owner != caller) {
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

        require(position.baseAmount + requestedBaseAmount >= 0, "Burning too much"); // TODO: CustomError

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

    function changePauser(Data storage self, address account, bool permission) internal { // TODO: move to DatedIRSVammPool?
      // not sure if msg.sender is the caller
      onlyVAMMOwner(self, msg.sender);
      self.pauser[account] = permission;
    }

    function setPausability(Data storage self, bool state) internal { // TODO: move to DatedIRSVammPool?
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
        self._vammVars.unlocked.lock(); // TODO: should lock move to executeDatedMakerOrder if that is the only possible entry point?

        Tick.checkTicks(tickLower, tickUpper);

        IVAMMBase.VAMMVars memory lvammVars = self._vammVars; // SLOAD for gas optimization

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

        self._vammVars.unlocked.unlock();

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

        IVAMMBase.VAMMVars memory vammVarsStart = self._vammVars;

        VAMMBase.checksBeforeSwap(params, vammVarsStart, params.amountSpecified > 0);

        /// @dev lock the vamm while the swap is taking place
        self._vammVars.unlocked.lock();

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

        self._tracker1GrowthGlobalX128 = state.tracker1GrowthGlobalX128;
        self._tracker0GrowthGlobalX128 = state.tracker0GrowthGlobalX128;

        tracker0Delta = state.tracker0DeltaCumulative;
        tracker1Delta = state.tracker1DeltaCumulative;

        emit VAMMBase.VAMMPriceChange(self._vammVars.tick);

        emit VAMMBase.Swap(
            msg.sender,
            params.tickLower,
            params.tickUpper,
            params.amountSpecified,
            params.sqrtPriceLimitX96,
            tracker0Delta,
            tracker1Delta
        );

        self._vammVars.unlocked.unlock();
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
