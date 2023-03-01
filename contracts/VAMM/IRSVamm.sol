// SPDX-License-Identifier: BUSL-1.1

pragma solidity =0.8.9;


abstract contract IRSVamm is VAMMBase {
  using SafeCastUni for uint256;
  using SafeCastUni for int256;
  using Tick for mapping(int24 => Tick.Info);
  using TickBitmap for mapping(int16 => uint256);

  function calculateUpdatedGlobalTrackerValues(
      SwapState memory state,
      StepComputations memory step
  )
      internal
      view
      returns (
          int256 stateVariableTokenGrowthGlobalX128,
          int256 stateFixedTokenGrowthGlobalX128,
          int256 fixedTokenDelta// for LP
      )
  {

      int24 averagePrice = (priceAtTick(state.tick) + priceAtTick(step.nextTick)) / 2;
      uint256 timeDeltaUntilMaturity = FixedAndVariableMath.accrualFact(termEndTimestampWad - Time.blockTimestampScaled()); 

      fixedTokenDelta = -FullMath.mulDiv(
            step.fixedTokenDeltaUnbalanced,
            oracle.latest(),
            1e18
        ) * (FullMath.mulDiv(
                averagePrice,
                timeDeltaUntilMaturity,
                1e18
            ) + 1e18);

      stateVariableTokenGrowthGlobalX128 = state.variableTokenGrowthGlobalX128 + FullMath.mulDivSigned(step.variableTokenDelta, FixedPoint128.Q128, state.liquidity);

      stateFixedTokenGrowthGlobalX128 = state.fixedTokenGrowthGlobalX128 + FullMath.mulDivSigned(fixedTokenDelta, FixedPoint128.Q128, state.liquidity);
  }

  function averageBase(
    int24 tickLower,
    int24 tickUpper,
    int128 baseAmount
  ) internal override returns(int128) {
    return base / (tick_upper - tick_lower);
  }

  function priceAtTick(int24 tick) internal returns(int128) {
    return tick / 100000;
  }

}