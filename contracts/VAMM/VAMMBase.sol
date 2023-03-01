// SPDX-License-Identifier: BUSL-1.1

pragma solidity =0.8.9;
import "./core_libraries/Tick.sol";
//import "./storage/VAMMStorage.sol";
//import "./interfaces/IVAMM.sol";
//import "./interfaces/IPeriphery.sol";
import "./core_libraries/TickBitmap.sol";
import "./utils/SafeCastUni.sol";
import "./utils/SqrtPriceMath.sol";
import "./core_libraries/SwapMath.sol";
//import "./interfaces/rate_oracles/IgwapOracle.sol";
//import "./interfaces/IERC20Minimal.sol";
//import "./interfaces/IFactory.sol";
import "prb-math/contracts/PRBMathUD60x18.sol";
import "prb-math/contracts/PRBMathSD59x18.sol";
import "./core_libraries/FixedAndVariableMath.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "./utils/FixedPoint128.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";


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

  function changePauser(address account, bool permission) external onlyOwner {
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

  // https://docs.openzeppelin.com/upgrades-plugins/1.x/writing-upgradeable
  /// @custom:oz-upgrades-unsafe-allow constructor
  constructor () initializer {}

  /// @inheritdoc IVAMMBase
  function initialize(address _gwapOracle, uint256 _termEndTimestampWad, int24 __tickSpacing) external override initializer {

    require(address(__marginEngine) != address(0), "ME = 0");
    // tick spacing is capped at 16384 to prevent the situation where tickSpacing is so large that
    // TickBitmap#nextInitializedTickWithinOneWord overflows int24 container from a valid tick
    // 16384 ticks represents a >5x price change with ticks of 1 bips
    require(__tickSpacing > 0 && __tickSpacing < Tick.MAXIMUM_TICK_SPACING, "TSOOB");

    gwapOracle = _gwapOracle;
    _tickSpacing = __tickSpacing;
    _maxLiquidityPerTick = Tick.tickSpacingToMaxLiquidityPerTick(_tickSpacing);
    termEndTimestampWad = _termEndTimestampWad;

    __Ownable_init();
    __UUPSUpgradeable_init();
  }

  // To authorize the owner to upgrade the contract we implement _authorizeUpgrade with the onlyOwner modifier.
  // ref: https://forum.openzeppelin.com/t/uups-proxies-tutorial-solidity-javascript/7786
  function _authorizeUpgrade(address) internal override onlyOwner {}

  /// @inheritdoc IVAMMBase
  function writeToGwapOracle(address _gwapOracle)
      external
      override
      onlyOwner
  {
      gwapOracle = _gwapOracle;
  }

  /// @inheritdoc IVAMMBase
    function getGwapOracle() external view override returns (IgwapOracle) {
        return gwapOracle;
    }


  // GETTERS FOR STORAGE SLOTS

  /// @inheritdoc IVAMMBase
  function tickSpacing() external view override returns (int24) {
      return _tickSpacing;
  }
  /// @inheritdoc IVAMMBase
  function maxLiquidityPerTick() external view override returns (uint128) {
      return _maxLiquidityPerTick;
  }
  /// @inheritdoc IVAMMBase
  function fixedTokenGrowthGlobalX128() external view override returns (int256) {
      return _fixedTokenGrowthGlobalX128;
  }
  /// @inheritdoc IVAMMBase
  function variableTokenGrowthGlobalX128() external view override returns (int256) {
      return _variableTokenGrowthGlobalX128;
  }
  /// @inheritdoc IVAMMBase
  function liquidity() external view override returns (uint128) {
      return _liquidity;
  }
  /// @inheritdoc IVAMMBase
  function ticks(int24 tick)
    external
    view
    override
    returns (Tick.Info memory) {
    return _ticks[tick];
  }
  /// @inheritdoc IVAMMBase
  function tickBitmap(int16 wordPosition) external view override returns (uint256) {
    return _tickBitmap[wordPosition];
  }
  /// @inheritdoc IVAMMBase
  function vammVars() external view override returns (VAMMVars memory) {
      return _vammVars;
  }

  function updateProtocolFees(uint256 protocolFeesCollected)
    external
    override
    onlyMarginEngine
  {
    if (_protocolFees < protocolFeesCollected) {
      revert CustomErrors.NotEnoughFunds(protocolFeesCollected, _protocolFees);
    }
    _protocolFees -= protocolFeesCollected;
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

    gwapOracle.update_oracle(tick); // TODO: implement GWAP Oracle

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
      params.liquidityDelta,
      _fixedTokenGrowthGlobalX128,
      _variableTokenGrowthGlobalX128,
      false,
      _maxLiquidityPerTick
    );

    /// @dev isUpper = true
    flippedUpper = _ticks.update(
      params.tickUpper,
      _vammVars.tick,
      params.liquidityDelta,
      _fixedTokenGrowthGlobalX128,
      _variableTokenGrowthGlobalX128,
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


  function updatePosition(ModifyPositionParams memory params) private returns(int256 positionMarginRequirement) {

    /// @dev give a more descriptive name

    Tick.checkTicks(params.tickLower, params.tickUpper);

    VAMMVars memory lvammVars = _vammVars; // SLOAD for gas optimization

    bool flippedLower;
    bool flippedUpper;

    /// @dev update the ticks if necessary
    if (params.liquidityDelta != 0) {
      (flippedLower, flippedUpper) = flipTicks(params);
    }

    positionMarginRequirement = 0;
    if (msg.sender != address(_marginEngine)) {
      // this only happens if the margin engine triggers a liquidation which in turn triggers a burn
      // the state updated in the margin engine in that case are done directly in the liquidatePosition function
      positionMarginRequirement = _marginEngine.updatePositionPostVAMMInducedMintBurn(params);
    }

    // clear any tick data that is no longer needed
    if (params.liquidityDelta < 0) {
      if (flippedLower) {
        _ticks.clear(params.tickLower);
      }
      if (flippedUpper) {
        _ticks.clear(params.tickUpper);
      }
    }

    gwapOracle.writeOracleEntry();

    if (params.liquidityDelta != 0) {
      if (
        (lvammVars.tick >= params.tickLower) && (lvammVars.tick < params.tickUpper)
      ) {
        // current tick is inside the passed range
        uint128 liquidityBefore = _liquidity; // SLOAD for gas optimization

        _liquidity = LiquidityMath.addDelta(
          liquidityBefore,
          params.liquidityDelta
        );
      }
    }
  }

  function averageBase(
    int24 tickLower,
    int24 tickUpper,
    uint128 baseAmount
  ) internal retrun (uint128) {
    return base / (tick_upper - tick_lower);
  }

  /// @inheritdoc IVAMMBase
  function mint(
    address recipient,
    int24 tickLower,
    int24 tickUpper,
    uint128 amount
  ) external override checkIsAlpha whenNotPaused checkCurrentTimestampTermEndTimestampDelta lock returns(int256 positionMarginRequirement) {
    
   /// @dev give a more descriptive name

    Tick.checkTicks(tickLower, tickUpper);

    VAMMVars memory lvammVars = _vammVars; // SLOAD for gas optimization

    bool flippedLower;
    bool flippedUpper;

    uint128 average_base = averageBase(tickLower, tickUpper, baseAmount);
    int128 liquidityDelta = int256(uint256(average_base)).toInt128();

    /// @dev update the ticks if necessary
    if (params.liquidityDelta != 0) {
      (flippedLower, flippedUpper) = flipTicks(
        FlipTicksParams({
            owner: recipient,
            tickLower: tickLower,
            tickUpper: tickUpper,
            deltaAccumulator: int256(uint256(average_base)).toInt128()
        })
      );
    }

    // TODO: send info to account manager
    // positionMarginRequirement = 0;
    // if (msg.sender != address(_marginEngine)) {
    //   // this only happens if the margin engine triggers a liquidation which in turn triggers a burn
    //   // the state updated in the margin engine in that case are done directly in the liquidatePosition function
    //   positionMarginRequirement = _marginEngine.updatePositionPostVAMMInducedMintBurn(params);
    // }

    // clear any tick data that is no longer needed
    if (params.liquidityDelta < 0) {
      if (flippedLower) {
        _ticks.clear(params.tickLower);
      }
      if (flippedUpper) {
        _ticks.clear(params.tickUpper);
      }
    }

    if (params.liquidityDelta != 0) {
      if (
        (lvammVars.tick >= params.tickLower) && (lvammVars.tick < params.tickUpper)
      ) {
        // current tick is inside the passed range
        uint128 liquidityBefore = _liquidity; // SLOAD for gas optimization

        _liquidity = LiquidityMath.addDelta(
          liquidityBefore,
          params.liquidityDelta
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
    returns (int256 fixedTokenDelta, int256 variableTokenDelta, int256 fixedTokenDeltaUnbalanced)
  {

    Tick.checkTicks(params.tickLower, params.tickUpper);

    VAMMVars memory vammVarsStart = _vammVars;

    checksBeforeSwap(params, vammVarsStart, params.amountSpecified > 0);

    // if (!(msg.sender == address(_marginEngine) || msg.sender==address(_marginEngine.fcm()))) {
    //   require(msg.sender==params.recipient || _factory.isApproved(params.recipient, msg.sender), "only sender or approved integration");
    // }

    /// @dev lock the vamm while the swap is taking place
    _unlocked = false;

    SwapCache memory cache = SwapCache({
      liquidityStart: _liquidity
    });

    SwapState memory state = SwapState({
      amountSpecifiedRemaining: params.amountSpecified, // base ramaining
      amountCalculated: 0, // ?
      sqrtPriceX96: vammVarsStart.sqrtPriceX96, // ? current tick?
      tick: vammVarsStart.tick,
      liquidity: cache.liquidityStart,
      fixedTokenGrowthGlobalX128: _fixedTokenGrowthGlobalX128,
      variableTokenGrowthGlobalX128: _variableTokenGrowthGlobalX128,
      fixedTokenDeltaCumulative: 0, // for Trader (user invoking the swap)
      variableTokenDeltaCumulative: 0, // for Trader (user invoking the swap),
      fixedTokenDeltaUnbalancedCumulative: 0, //  for Trader (user invoking the swap)
    });

    /// @dev write an entry to the rate oracle (given no throttling)

    // gwapOracle.update_oracle(_vammVars.tick);

    // continue swapping as long as we haven't used the entire input/output and haven't reached the price (implied fixed rate) limit
    bool advanceRight = params.amountSpecified > 0;
      // Fixed Taker
    while (
      state.amountSpecifiedRemaining != 0 &&
      state.sqrtPriceX96 != params.sqrtPriceLimitX96
    ) {
      StepComputations memory step;

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
            timeToMaturityInSecondsWad: termEndTimestampWad - Time.blockTimestampScaled()
        })
      );

      // exact input
      /// prb math is not used in here (following v3 logic)
      state.amountSpecifiedRemaining += advanceRight ? -(step.amountIn).toInt256 : step.amountOut.toInt256(); // this value is positive
      state.amountCalculated += advanceRight ? -(step.amountOut).toInt256 : step.amountIn.toInt256(); // this value is negative

      if(advanceRight) {
        // LP is a Variable Taker
        step.variableTokenDelta = (step.amountIn).toInt256();
        step.fixedTokenDeltaUnbalanced = -step.amountOut.toInt256();
      } else {
        // LP is a Fixed Taker
        step.variableTokenDelta -= step.amountOut.toInt256();
        step.fixedTokenDeltaUnbalanced += step.amountIn.toInt256();
      }

      if (state.liquidity > 0) {
        (
          state.variableTokenGrowthGlobalX128,
          state.fixedTokenGrowthGlobalX128,
          step.fixedTokenDelta // for LP
        ) = calculateUpdatedGlobalTrackerValues( // abstract
          state,
          step
        );

        state.fixedTokenDeltaCumulative -= step.fixedTokenDelta; // opposite sign from that of the LP's
        state.variableTokenDeltaCumulative -= step.variableTokenDelta; // opposite sign from that of the LP's

        // necessary for testing purposes, also handy to quickly compute the fixed rate at which an interest rate swap is created
        state.fixedTokenDeltaUnbalancedCumulative -= step.fixedTokenDeltaUnbalanced;
      }

      // shift tick if we reached the next price
      if (state.sqrtPriceX96 == step.sqrtPriceNextX96) {
        // if the tick is initialized, run the tick transition
        if (step.initialized) {
          int128 liquidityNet = _ticks.cross(
            step.tickNext,
            state.fixedTokenGrowthGlobalX128,
            state.variableTokenGrowthGlobalX128
          );

          state.liquidity = LiquidityMath.addDelta(
            state.liquidity,
            advanceRight ? liquidityNet : -liquidityNet
          );

        }

        state.tick = advanceRight ? step.tickNext : step.tickNext - 1;
      } else if (state.sqrtPriceX96 != step.sqrtPriceStartX96) {
        // recompute unless we're on a lower tick boundary (i.e. already transitioned ticks), and haven't moved
        state.tick = TickMath.getTickAtSqrtRatio(state.sqrtPriceX96);
      }
    }
    _vammVars.sqrtPriceX96 = state.sqrtPriceX96;

    if (state.tick != vammVarsStart.tick) {
       // update the tick in case it changed
      _vammVars.tick = state.tick;
    }

    // update liquidity if it changed
    if (cache.liquidityStart != state.liquidity) _liquidity = state.liquidity;

    _variableTokenGrowthGlobalX128 = state.variableTokenGrowthGlobalX128;
    _fixedTokenGrowthGlobalX128 = state.fixedTokenGrowthGlobalX128;

    fixedTokenDelta = state.fixedTokenDeltaCumulative;
    variableTokenDelta = state.variableTokenDeltaCumulative;
    fixedTokenDeltaUnbalanced = state.fixedTokenDeltaUnbalancedCumulative;

    // TODO: update accout based on swap changes OR return to pool & let pool execute update
    // marginRequirement = _marginEngine.updatePositionPostVAMMInducedSwap(params.recipient, params.tickLower, params.tickUpper, state.fixedTokenDeltaCumulative, state.variableTokenDeltaCumulative, state.cumulativeFeeIncurred, state.fixedTokenDeltaUnbalancedCumulative);

    emit VAMMPriceChange(_vammVars.tick);

    emit Swap(
      msg.sender,
      params.recipient,
      params.tickLower,
      params.tickUpper,
      params.amountSpecified,
      params.sqrtPriceLimitX96,
      cumulativeFeeIncurred,
      fixedTokenDelta,
      variableTokenDelta,
      fixedTokenDeltaUnbalanced
    );

    _unlocked = true;
  }

  /// @inheritdoc IVAMMBase
  function computeGrowthInside(
    int24 tickLower,
    int24 tickUpper
  )
    external
    view
    override
    returns (int256 fixedTokenGrowthInsideX128, int256 variableTokenGrowthInsideX128)
  {

    Tick.checkTicks(tickLower, tickUpper);

    fixedTokenGrowthInsideX128 = _ticks.getFixedTokenGrowthInside(
      Tick.FixedTokenGrowthInsideParams({
        tickLower: tickLower,
        tickUpper: tickUpper,
        tickCurrent: _vammVars.tick,
        fixedTokenGrowthGlobalX128: _fixedTokenGrowthGlobalX128
      })
    );

    variableTokenGrowthInsideX128 = _ticks.getVariableTokenGrowthInside(
      Tick.VariableTokenGrowthInsideParams({
        tickLower: tickLower,
        tickUpper: tickUpper,
        tickCurrent: _vammVars.tick,
        variableTokenGrowthGlobalX128: _variableTokenGrowthGlobalX128
      })
    );

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
          revert CustomErrors.CanOnlyTradeIfUnlocked(_unlocked);
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
      virtual
      returns (
          uint256 stateFeeGrowthGlobalX128,
          int256 stateVariableTokenGrowthGlobalX128,
          int256 stateFixedTokenGrowthGlobalX128,
          int256 fixedTokenDelta// for LP
      )
  {}

}
