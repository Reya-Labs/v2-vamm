// SPDX-License-Identifier: BUSL-1.1

pragma solidity >=0.8.13;
import "./libraries/Tick.sol";
import "./libraries/TickBitmap.sol";
import "../utils/SafeCastUni.sol";
import "../utils/SqrtPriceMath.sol";
import "./libraries/SwapMath.sol";
import "prb-math/contracts/PRBMathUD60x18.sol";
import "prb-math/contracts/PRBMathSD59x18.sol";
import "./libraries/FixedAndVariableMath.sol";
import "../utils/FixedPoint128.sol";
import "./interfaces/IVAMMBase.sol";


abstract contract VAMMBase is IVAMMBase {
  using SafeCastUni for uint256;
  using SafeCastUni for int256;
  using Tick for mapping(int24 => Tick.Info);
  using TickBitmap for mapping(int16 => uint256);

  bytes32 public constant VOLTZ_PAUSER = keccak256("VOLTZ_PAUSER");

  modifier whenNotPaused() {
        require(!paused, "Paused");
        _;
    }

  // TODO: olyOwner
  function changePauser(address account, bool permission) external {
      pauser[account] = permission;
  }

  function setPausability(bool state) external {
      require(pauser[msg.sender], "no role");
      paused = state;
  }

  /// @dev Mutually exclusive reentrancy protection into the vamm to/from a method. This method also prevents entrance
  /// to a function before the vamm is initialized. The reentrancy guard is required throughout the contract.
  modifier lock() {
    require(_unlocked, "LOK");
    _unlocked = false;
    _;
    _unlocked = true;
  }

  // https://ethereum.stackexchange.com/questions/68529/solidity-modifiers-in-library
  /// @dev Modifier that ensures new LP positions cannot be minted after one day before the maturity of the vamm
  /// @dev also ensures new swaps cannot be conducted after one day before maturity of the vamm
  modifier checkCurrentTimestampTermEndTimestampDelta() {
    if (Time.isCloseToMaturityOrBeyondMaturity(termEndTimestampWad)) {
      revert("closeToOrBeyondMaturity");
    }
    _;
  }


  constructor(address _gtwapOracle, uint256 _termEndTimestampWad, int24 __tickSpacing) {

    // tick spacing is capped at 16384 to prevent the situation where tickSpacing is so large that
    // TickBitmap#nextInitializedTickWithinOneWord overflows int24 container from a valid tick
    // 16384 ticks represents a >5x price change with ticks of 1 bips
    require(__tickSpacing > 0 && __tickSpacing < Tick.MAXIMUM_TICK_SPACING, "TSOOB");

    gtwapOracle = _gtwapOracle;
    _tickSpacing = __tickSpacing;
    _maxLiquidityPerTick = Tick.tickSpacingToMaxLiquidityPerTick(_tickSpacing);
    termEndTimestampWad = _termEndTimestampWad;

    __Ownable_init();
    __UUPSUpgradeable_init();
  }

  /// GETTERS & TRACKETS

  function averageBase(
    int24 tickLower,
    int24 tickUpper,
    int128 baseAmount
  ) external virtual returns(int128);

  function baseBetweenTicks(
    int24 tickLower,
    int24 tickUpper,
    int128 accumulator
  ) internal returns(int128) {
    return accumulator * (tickUpper - tickUpper);
  }

  function trackValuesBetweenTicksOutside(
    int128 averageBase,
    int24 tickLower,
    int24 tickUpper
  ) internal returns(
    int128 tracker0GrowthOutside,
    int128 tracker1GrowthOutside
  ) {
    if (tickLower == tickUpper) {
        return (0, 0);
    }

    int128 base = baseBetweenTicks(tickLower, tickUpper, averageBase);

    tracker0GrowthOutside = trackFixedTokens(averageBase, tickLower, tickUpper);
    tracker1GrowthOutside = averageBase;

  }

  function trackValuesBetweenTicks(
    int24 tickLower,
    int24 tickUpper,
    int128 base
  ) internal returns(
    int128 tracker0GrowthOutsideLeft,
    int128 tracker1GrowthOutsideLeft,
    int128 tracker0GrowthOutsideRight,
    int128 tracker1GrowthOutsideRight
  ) {
    if (tickLower == tickUpper) {
        return (0, 0, 0, 0);
    }

    int128 averageBase = averageBase(tickLower, tickUpper, baseAmount);

    (int128 tracker0GrowthOutsideLeft_, int128 tracker1GrowthOutsideLeft_) = trackValuesBetweenTicksOutside(
        averageBase,
        tickLower < _tick ? tickLower : vammVars.tick,
        tickUpper > _tick ? tickUpper : vammVars.tick
    );
    tracker0GrowthOutsideLeft = -tracker0GrowthOutsideLeft_;
    tracker1GrowthOutsideLeft = -tracker1GrowthOutsideLeft_;

    (tracker0GrowthOutsideRight, tracker1GrowthOutsideRight) = trackValuesBetweenTicksOutside(
        averageBase,
        tickLower < _tick ? tickLower : vammVars.tick,
        tickUpper > _tick ? tickUpper : vammVars.tick
    );

  }

  /// @inheritdoc IVAMMBase
  function refreshGTWAPOracle(address _gtwapOracle)
      external
      override
  {
      gtwapOracle = _gtwapOracle;
  }

  /// @dev not locked because it initializes unlocked
  function initializeVAMM(uint160 sqrtPriceX96) external override {

    require(sqrtPriceX96 != 0, "zero input price");
    require((sqrtPriceX96 < TickMath.MAX_SQRT_RATIO) && (sqrtPriceX96 >= TickMath.MIN_SQRT_RATIO), "R"); 

    /// @dev initializeVAMM should only be callable given the initialize function was already executed
    /// @dev we can check if the initialize function was executed by making sure the address of the margin engine is non-zero since it is set in the initialize function
    require(address(_marginEngine) != address(0), "vamm not initialized");

    if (_vammVars.sqrtPriceX96 != 0)  {
      revert CustomErrors.ExpectedSqrtPriceZeroBeforeInit(_vammVars.sqrtPriceX96);
    }

    int24 tick = TickMath.getTickAtSqrtRatio(sqrtPriceX96);

    _vammVars = VAMMVars({ sqrtPriceX96: sqrtPriceX96, tick: tick});

    gtwapOracle.update_oracle(tick); // TODO: implement GWAP Oracle

    _unlocked = true;

    emit VAMMInitialization(sqrtPriceX96, tick);
  }

  function flipTicks(FlipTicksParams memory params)
    internal
    returns (bool flippedLower, bool flippedUpper)
  {

    Tick.checkTicks(params.tickLower, params.tickUpper);


    /// @dev isUpper = false
    flippedLower = _ticks.update(
      params.tickLower,
      _vammVars.tick,
      params.accumulatorDelta,
      _tracker0GrowthGlobalX128,
      _tracker1GrowthGlobalX128,
      false,
      _maxLiquidityPerTick
    );

    /// @dev isUpper = true
    flippedUpper = _ticks.update(
      params.tickUpper,
      _vammVars.tick,
      params.accumulatorDelta,
      _tracker0GrowthGlobalX128,
      _tracker1GrowthGlobalX128,
      true,
      _maxLiquidityPerTick
    );

    if (flippedLower) {
      _tickBitmap.flipTick(params.tickLower, _tickSpacing);
    }

    if (flippedUpper) {
      _tickBitmap.flipTick(params.tickUpper, _tickSpacing);
    }
  }

  /// @inheritdoc IVAMMBase
  function mint(
    address recipient,
    int24 tickLower,
    int24 tickUpper,
    uint128 amount
  ) external override whenNotPaused checkCurrentTimestampTermEndTimestampDelta lock returns(int256 positionMarginRequirement) {
    
   /// @dev give a more descriptive name

    Tick.checkTicks(tickLower, tickUpper);

    VAMMVars memory lvammVars = _vammVars; // SLOAD for gas optimization

    bool flippedLower;
    bool flippedUpper;

    int128 averageBase = averageBase(tickLower, tickUpper, baseAmount);

    /// @dev update the ticks if necessary
    if (averageBase != 0) {
      (flippedLower, flippedUpper) = flipTicks(
        FlipTicksParams({
            owner: recipient,
            tickLower: tickLower,
            tickUpper: tickUpper,
            deltaAccumulator: averageBase
        })
      );
    }

    // clear any tick data that is no longer needed
    if (averageBase < 0) {
      if (flippedLower) {
        _ticks.clear(params.tickLower);
      }
      if (flippedUpper) {
        _ticks.clear(params.tickUpper);
      }
    }

    if (averageBase != 0) {
      if (
        (lvammVars.tick >= params.tickLower) && (lvammVars.tick < params.tickUpper)
      ) {
        // current tick is inside the passed range
        uint128 accumulatorBefore = _accumulator; // SLOAD for gas optimization

        _accumulator = LiquidityMath.addDelta(
          accumulatorBefore,
          averageBase
        );
      }
    }

    emit Mint(msg.sender, recipient, tickLower, tickUpper, amount);
  }

  /// @inheritdoc IVAMMBase
  function swap(SwapParams memory params)
    external
    override
    whenNotPaused
    checkCurrentTimestampTermEndTimestampDelta
    returns (int256 tracker0Delta, int256 tracker1Delta)
  {

    Tick.checkTicks(params.tickLower, params.tickUpper);

    VAMMVars memory vammVarsStart = _vammVars;

    checksBeforeSwap(params, vammVarsStart, params.amountSpecified > 0);

    /// @dev lock the vamm while the swap is taking place
    _unlocked = false;

    uint128 accumulatorStart = _accumulator;

    SwapState memory state = SwapState({
      amountSpecifiedRemaining: params.amountSpecified, // base ramaining
      baseInStep: 0,
      sqrtPriceX96: vammVarsStart.sqrtPriceX96,
      tick: vammVarsStart.tick,
      accumulator: cache.accumulatorStart,
      tracker0GrowthGlobalX128: _tracker0GrowthGlobalX128,
      tracker1GrowthGlobalX128: _tracker1GrowthGlobalX128,
      tracker0DeltaCumulative: 0, // for Trader (user invoking the swap)
      tracker1DeltaCumulative: 0 // for Trader (user invoking the swap)
    });

    // continue swapping as long as we haven't used the entire input/output and haven't reached the price (implied fixed rate) limit
    bool advanceRight = params.amountSpecified > 0;
    while (
      state.amountSpecifiedRemaining != 0 &&
      state.sqrtPriceX96 != params.sqrtPriceLimitX96
    ) {
      StepComputations memory step;

      ///// GET NEXT TICK /////

      step.sqrtPriceStartX96 = state.sqrtPriceX96;

      /// @dev if isFT (fixed taker) (moving right to left), the nextInitializedTick should be more than or equal to the current tick
      /// @dev if !isFT (variable taker) (moving left to right), the nextInitializedTick should be less than or equal to the current tick
      /// add a test for the statement that checks for the above two conditions
      (step.tickNext, step.initialized) = _tickBitmap
        .nextInitializedTickWithinOneWord(state.tick, _tickSpacing, !advanceRight);

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
            accumulator: state.accumulator,
            amountRemaining: state.amountSpecifiedRemaining,
            timeToMaturityInSecondsWad: termEndTimestampWad - Time.blockTimestampScaled()
        })
      );

      ///// UPDATE TRACKERS /////

      state.baseInStep = advanceRight ? -(step.amountIn).toInt256 : step.amountOut.toInt256();
      state.amountSpecifiedRemaining += baseInStep;

      if(advanceRight) {
        // LP is a Variable Taker
        step.tracker1Delta = (step.amountIn).toInt256();
      } else {
        // LP is a Fixed Taker
        step.tracker1Delta -= step.amountOut.toInt256();
      }

      if (state.accumulator > 0) {
        (
          state.tracker1GrowthGlobalX128,
          state.tracker0GrowthGlobalX128,
          step.tracker0Delta // for LP
        ) = calculateUpdatedGlobalTrackerValues( //
          state,
          step
        );

        state.tracker0DeltaCumulative -= step.tracker0Delta; // opposite sign from that of the LP's
        state.tracker1DeltaCumulative -= step.tracker1Delta; // opposite sign from that of the LP's
      }

      ///// UPDATE TICK AFTER SWAP STEP /////

      // shift tick if we reached the next price
      if (state.sqrtPriceX96 == step.sqrtPriceNextX96) {
        // if the tick is initialized, run the tick transition
        if (step.initialized) {
          int128 accumulatorNet = _ticks.cross(
            step.tickNext,
            state.tracker0GrowthGlobalX128,
            state.tracker1GrowthGlobalX128
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

    _vammVars.sqrtPriceX96 = state.sqrtPriceX96;

    if (state.tick != vammVarsStart.tick) {
       // update the tick in case it changed
      _vammVars.tick = state.tick;
    }

    // update liquidity if it changed
    if (cache.accumulatorStart != state.accumulator) _accumulator = state.accumulator;

    _tracker1GrowthGlobalX128 = state.tracker1GrowthGlobalX128;
    _tracker0GrowthGlobalX128 = state.tracker0GrowthGlobalX128;

    tracker0Delta = state.tracker0DeltaCumulative;
    tracker1Delta = state.tracker1DeltaCumulative;

    emit VAMMPriceChange(_vammVars.tick);

    emit Swap(
      msg.sender,
      params.recipient,
      params.tickLower,
      params.tickUpper,
      params.amountSpecified,
      params.sqrtPriceLimitX96,
      cumulativeFeeIncurred,
      tracker0Delta,
      tracker1Delta
    );

    _unlocked = true;
  }

  function checksBeforeSwap(
      SwapParams memory params,
      VAMMVars memory vammVarsStart,
      bool isFT
  ) internal view {

      if (params.amountSpecified == 0) {
          revert CustomErrors.IRSNotionalAmountSpecifiedMustBeNonZero();
      }

      if (!_unlocked) {
          // TODO: add CustomError
          revert;
      }

      /// @dev if a trader is an FT, they consume fixed in return for variable
      /// @dev Movement from right to left along the VAMM, hence the sqrtPriceLimitX96 needs to be higher than the current sqrtPriceX96, but lower than the MAX_SQRT_RATIO
      /// @dev if a trader is a VT, they consume variable in return for fixed
      /// @dev Movement from left to right along the VAMM, hence the sqrtPriceLimitX96 needs to be lower than the current sqrtPriceX96, but higher than the MIN_SQRT_RATIO

      require(
          isFT
              ? params.sqrtPriceLimitX96 > vammVarsStart.sqrtPriceX96 &&
                  params.sqrtPriceLimitX96 < TickMath.MAX_SQRT_RATIO
              : params.sqrtPriceLimitX96 < vammVarsStart.sqrtPriceX96 &&
                  params.sqrtPriceLimitX96 > TickMath.MIN_SQRT_RATIO,
          "SPL"
      );
  }

  function calculateUpdatedGlobalTrackerValues(
      SwapState memory state,
      StepComputations memory step
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
        step.nextTick
      );

      // update global trackers
      stateVariableTokenGrowthGlobalX128 = state.tracker1GrowthGlobalX128 + FullMath.mulDivSigned(step.tracker1Delta, FixedPoint128.Q128, state.accumulator);

      stateFixedTokenGrowthGlobalX128 = state.tracker0GrowthGlobalX128 + FullMath.mulDivSigned(tracker0Delta, FixedPoint128.Q128, state.accumulator);
  }

  function trackFixedTokens(
      int256 baseAmount,
      int24 tickLower,
      int24 tickUpper
  )
      public
      virtual
      returns (int256 trackedValue);

}
