// SPDX-License-Identifier: BUSL-1.1

pragma solidity =0.8.9;


abstract contract IRSVamm is VAMMBase {
  using SafeCastUni for uint256;
  using SafeCastUni for int256;
  using Tick for mapping(int24 => Tick.Info);
  using TickBitmap for mapping(int16 => uint256);

  function trackFixedTokens(
      int256 baseAmount,
      int24 tickLower,
      int24 tickUpper
  )
      internal
      view
      returns (
          int256 trackedValue
      )
  {

      int24 averagePrice = (priceAtTick(tickUpper) + priceAtTick(tickLower)) / 2;
      uint256 timeDeltaUntilMaturity = FixedAndVariableMath.accrualFact(termEndTimestampWad - Time.blockTimestampScaled()); 

      // TODO: needs library
      fixedTokenDelta = -FullMath.mulDiv(
            baseAmount,
            oracle.latest(), // TODO: implement Oracle
            1e18
        ) * (FullMath.mulDiv(
                averagePrice,
                timeDeltaUntilMaturity,
                1e18
            ) + 1e18);
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
