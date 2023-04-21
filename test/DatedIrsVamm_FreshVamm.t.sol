pragma solidity >=0.8.13;

import "forge-std/Test.sol";
 import "forge-std/console2.sol";
 import "./DatedIrsVammTest.sol";
 import "../contracts/utils/SafeCastUni.sol";
 import "../contracts/VAMM/storage/LPPosition.sol";
import "../contracts/VAMM/storage/DatedIrsVAMM.sol";
import "../contracts/utils/CustomErrors.sol";
import "../contracts/VAMM/storage/LPPosition.sol";
import { mulUDxInt } from "../contracts/utils/PrbMathHelper.sol";
import { UD60x18, convert, ud60x18, uMAX_UD60x18, uUNIT } from "@prb/math/src/UD60x18.sol";
import { SD59x18, sd59x18, convert } from "@prb/math/src/SD59x18.sol";

// Constants
UD60x18 constant ONE = UD60x18.wrap(1e18);

// TODO: Break up this growing test contract into more multiple separate tests for increased readability
contract VammTest_FreshVamm is DatedIrsVammTest {
    using DatedIrsVamm for DatedIrsVamm.Data;
    using SafeCastUni for uint256;
    using SafeCastUni for uint128;
    using SafeCastUni for int256;

    function setUp() public {
        DatedIrsVamm.create(initMarketId, initSqrtPriceX96, immutableConfig, mutableConfig);
        vammId = uint256(keccak256(abi.encodePacked(initMarketId, initMaturityTimestamp)));
    }

    function test_Init_State() public {
        DatedIrsVamm.Data storage vamm = DatedIrsVamm.load(vammId);
        assertEq(vamm.vars.sqrtPriceX96, initSqrtPriceX96); 
        assertEq(vamm.vars.tick, TickMath.getTickAtSqrtRatio(initSqrtPriceX96)); 
        assertEq(vamm.vars.observationIndex, 0); 
        assertEq(vamm.vars.observationCardinality, 1); 
        assertEq(vamm.vars.observationCardinalityNext, 1); 
       //assertEq(vamm.vars.feeProtocol, 0); 
        assertEq(vamm.vars.unlocked, true); 
        assertEq(vamm.mutableConfig.priceImpactPhi, mutableConfig.priceImpactPhi); 
        assertEq(vamm.mutableConfig.priceImpactBeta, mutableConfig.priceImpactBeta); 
        assertEq(vamm.mutableConfig.spread, mutableConfig.spread); 
        assertEq(address(vamm.mutableConfig.rateOracle), address(mutableConfig.rateOracle)); 

        // Check that we cannot re-init
        vm.expectRevert();
        vamm.initialize(initSqrtPriceX96);
    }

    function test_Init_Twap_Unadjusted() public {
        DatedIrsVamm.Data storage vamm = DatedIrsVamm.load(vammId);
        int24 tick = vamm.vars.tick;
        assertEq(vamm.observe(0), tick); 

        // no lookback, no adjustments
        UD60x18 geometricMeanPrice = vamm.twap(0, 0, false, false);
        assertEq(geometricMeanPrice, VAMMBase.getPriceFromTick(tick)); 
        assertAlmostEqual(geometricMeanPrice, ud60x18(4e16)); // Approx 0.04. Not exact cos snaps to tick boundary.
    }

    function test_Init_Twap_WithSpread() public {
        DatedIrsVamm.Data storage vamm = DatedIrsVamm.load(vammId);
        int24 tick = vamm.vars.tick;
        assertEq(vamm.observe(0), tick); 

        {
            // no lookback, adjust for spread, positive order size
            UD60x18 twapPrice = vamm.twap(0, 1, false, true);
            // Spread adds 0.3% to the price (as an absolute amount, not as a percentage of the price)
            assertEq(twapPrice, VAMMBase.getPriceFromTick(tick).add(mutableConfig.spread)); 
        }

        {
            // no lookback, adjust for spread, negative order size
            UD60x18 twapPrice = vamm.twap(0, -1, false, true);
            // Spread subtracts 0.3% from the price (as an absolute amount, not as a percentage of the price)
            assertEq(twapPrice, VAMMBase.getPriceFromTick(tick).sub(mutableConfig.spread));
        }
    }

    function test_Init_Twap_WithPriceImpact() public {
        DatedIrsVamm.Data storage vamm = DatedIrsVamm.load(vammId);
        int24 tick = vamm.vars.tick;
        assertEq(vamm.observe(0), tick); 

        {
            // no lookback, adjust for price impact of positive orderSize 100000000
            int256 orderSize = 100000000;
            UD60x18 twapPrice = vamm.twap(0, orderSize, true, false);

            // Price impact adds a multiple of 0.1*orderSize^0.125
            //                               = 0.1*100000000^0.125
            //                               = 0.1*10 = 1 to the price, i.e. doubles the price
            assertAlmostEqual(twapPrice, VAMMBase.getPriceFromTick(tick).mul(ONE.add(ONE)));  
        }

        {
            // no lookback, adjust for price impact of negative orderSize 256
            int256 orderSize = -256;
            UD60x18 twapPrice = vamm.twap(0, orderSize, true, false);

            // Price impact subtracts a multiple of 0.1*abs(orderSize)^0.125
            //                               = 0.1*256^0.125
            //                               = 0.1*2 = 0.2 times the price, i.e. takes 20% off the price
            assertAlmostEqual(twapPrice, VAMMBase.getPriceFromTick(tick).mul(ud60x18(8e17)));  
        }
    }

    /// @dev Useful check that we do not crash (e.g. due to underflow) while making adjustments to TWAP output
    function testFuzz_Init_Twap(int256 orderSize, bool adjustForPriceImpact,  bool adjustForSpread) public {
        vm.assume(orderSize != 0);
        orderSize = bound(orderSize, -int256(uMAX_UD60x18 / uUNIT), int256(uMAX_UD60x18 / uUNIT));

        DatedIrsVamm.Data storage vamm = DatedIrsVamm.load(vammId);
        int24 tick = vamm.vars.tick;
        assertEq(vamm.observe(0), tick);
        UD60x18 instantPrice = VAMMBase.getPriceFromTick(tick);

        // no lookback
        UD60x18 twapPrice = vamm.twap(0, orderSize, adjustForPriceImpact, adjustForSpread);

        if (!adjustForPriceImpact && !adjustForSpread) {
            assertEq(twapPrice, instantPrice); 
        } else if (orderSize < 0) {
             assertLt(twapPrice, instantPrice); 
        } else {
             assertGt(twapPrice, instantPrice); 
        }
    }

    function testFuzz_BaseBetweenTicks(
        int24 tickLower,
        int24 tickUpper,
        int128 basePerTick)
    public {
        (tickLower, tickUpper) = boundTicks(tickLower, tickUpper);
        basePerTick = int128(bound(basePerTick, 0, type(int128).max / tickDistance(tickLower, tickUpper).toInt128()));
        assertEq(VAMMBase.baseBetweenTicks(tickLower, tickUpper, basePerTick), int256(basePerTick) * (tickUpper - tickLower));
    }

    function testFuzz_BasePerTick(
        int24 tickLower,
        int24 tickUpper,
        int128 baseAmount)
    public {
        (tickLower, tickUpper) = boundTicks(tickLower, tickUpper);
        assertEq(VAMMBase.basePerTick(tickLower, tickUpper, baseAmount), baseAmount / (tickUpper - tickLower));
    }

    function averagePriceBetweenTicksUsingLoop(
        int24 tickLower,
        int24 tickUpper)
    internal pure returns (UD60x18)
    {
        UD60x18 sumOfPrices = VAMMBase.getPriceFromTick(tickLower);
        for (int24 i = tickLower + 1; i <= tickUpper; i++) {
            sumOfPrices = sumOfPrices.add(VAMMBase.getPriceFromTick(i));
        }
        return sumOfPrices.div(convert(uint256(int256(1 + tickUpper - tickLower))));
    }

    function test_SumOfAllPricesUpToPlus10k()
    public {
        // The greater the tick range, the more the real answer deviates from a naive average of the top and bottom price
        // a range of ~500 is sufficient to illustrate a diversion, but note that larger ranges have much larger diversions
        int24 tick = 1;

        assertAlmostExactlyEqual(VAMMBase._sumOfAllPricesUpToPlus10k(tick), ud60x18(10000e18 + 20001e14));
    }

    function test_AveragePriceBetweenTicks_SingleTick0()
    public {
        // The greater the tick range, the more the real answer deviates from a naive average of the top and bottom price
        // a range of ~500 is sufficient to illustrate a diversion, but note that larger ranges have much larger diversions
        int24 tickLower = 0;
        int24 tickUpper = 0;
        assertEq(VAMMBase.averagePriceBetweenTicks(tickLower, tickUpper), ud60x18(1e18));
    }

    function test_AveragePriceBetweenTicks_SingleTick1()
    public {
        // The greater the tick range, the more the real answer deviates from a naive average of the top and bottom price
        // a range of ~500 is sufficient to illustrate a diversion, but note that larger ranges have much larger diversions
        int24 tickLower = 1;
        int24 tickUpper = 1;
        assertAlmostExactlyEqual(VAMMBase.averagePriceBetweenTicks(tickLower, tickUpper), ud60x18(10001e14));
    }

    function test_AveragePriceBetweenTicks_TwoTicks()
    public {
        // The greater the tick range, the more the real answer deviates from a naive average of the top and bottom price
        // a range of ~500 is sufficient to illustrate a diversion, but note that larger ranges have much larger diversions
        int24 tickLower = 0;
        int24 tickUpper = 1;
        assertAlmostExactlyEqual(VAMMBase.averagePriceBetweenTicks(tickLower, tickUpper), ud60x18(100005e13));
    }

    function test_AveragePriceBetweenTicks()
    public {
        // The greater the tick range, the more the real answer deviates from a naive average of the top and bottom price
        // a range of ~500 is sufficient to illustrate a diversion, but note that larger ranges have much larger diversions
        int24 tickLower = 2;
        int24 tickUpper = 500;
        UD60x18 expected = averagePriceBetweenTicksUsingLoop(tickLower, tickUpper);
        assertAlmostExactlyEqual(VAMMBase.averagePriceBetweenTicks(tickLower, tickUpper), expected);
    }

    function test_AveragePriceBetweenTicks2()
    public {
        // Test a nagative range
        int24 tickLower = -10;
        int24 tickUpper = 10;
        UD60x18 expected = averagePriceBetweenTicksUsingLoop(tickLower, tickUpper);
        assertAlmostExactlyEqual(VAMMBase.averagePriceBetweenTicks(tickLower, tickUpper), expected);
    }

    function testSlowFuzz_AveragePriceBetweenTicks(
        int24 tickLower,
        int24 tickUpper)
    public {
        (tickLower, tickUpper) = boundTicks(tickLower, tickUpper);
        UD60x18 expected = averagePriceBetweenTicksUsingLoop(tickLower, tickUpper);
        assertAlmostEqual(VAMMBase.averagePriceBetweenTicks(tickLower, tickUpper), expected);
    }

    // todo: move to position tests
    // function testFail_GetUnopenedPosition() public {
    //     vamm.getRawPosition(1);
    // }
    // function openPosition(
    //     uint128 accountId,
    //     int24 tickLower,
    //     int24 tickUpper)
    // internal
    // returns (uint256 positionId, LPPosition.Data memory position)
    // {
    //     positionId = vamm._ensurePositionOpened(accountId,tickLower,tickUpper);
    //     position = vamm.positions[positionId];
    // }

    // function testFuzz_EnsurePositionOpened(uint128 accountId, int24 tickLower, int24 tickUpper) public {
    //     vm.assume(accountId != 0);
    //     (tickLower, tickUpper) = boundTicks(tickLower, tickUpper);

    //     (uint256 positionId, LPPosition.Data memory p) = openPosition(accountId,tickLower,tickUpper);
    //     assertEq(positionId, DatedIrsVamm.getPositionId(accountId,tickLower,tickUpper));
    //     assertEq(p.accountId, accountId);
    //     assertEq(p.tickLower, tickLower);
    //     assertEq(p.tickUpper, tickUpper);
    //     assertEq(p.baseAmount, 0);
    //     assertEq(p.trackerVariableTokenUpdatedGrowth, 0);
    //     assertEq(p.trackerBaseTokenUpdatedGrowth, 0);
    //     assertEq(p.trackerVariableTokenAccumulated, 0);
    //     assertEq(p.trackerBaseTokenAccumulated, 0);
    //     //vamm.getRawPosition(positionId);
    // }

    function testFuzz_GetAccountFilledBalancesUnusedAccount(uint128 accountId) public {
        DatedIrsVamm.Data storage vamm = DatedIrsVamm.load(vammId);
        (int256 baseBalancePool, int256 quoteBalancePool) = vamm.getAccountFilledBalances(accountId);
        assertEq(baseBalancePool, 0);
        assertEq(quoteBalancePool, 0);
    }

    function testFuzz_GetAccountUnfilledBasesUnusedAccount(uint128 accountId) public {
        DatedIrsVamm.Data storage vamm = DatedIrsVamm.load(vammId);
        (int256 unfilledBaseLong, int256 unfilledBaseShort) = vamm.getAccountUnfilledBases(accountId);
        assertEq(unfilledBaseLong, 0);
        assertEq(unfilledBaseShort, 0);
    }

    function test_FixedTokensInHomogeneousTickWindow() public {
      int256 baseAmount = 5e10;
      int24 tickLower = -1;
      int24 tickUpper = 1;
      uint256 mockLiquidityIndex = 2;
      uint256 maturityTimestamp = block.timestamp + convert(FixedAndVariableMath.SECONDS_IN_YEAR);
 
      UD60x18 currentLiquidityIndex = convert(mockLiquidityIndex);
      vm.mockCall(mockRateOracle, abi.encodeWithSelector(IRateOracle.getCurrentIndex.selector), abi.encode(currentLiquidityIndex));

      DatedIrsVamm.Data storage vamm = DatedIrsVamm.load(vammId);
      (int256 trackedValue) = vamm._fixedTokensInHomogeneousTickWindow(baseAmount, tickLower, tickUpper, maturityTimestamp);

      UD60x18 expectedAveragePrice = averagePriceBetweenTicksUsingLoop(tickLower, tickUpper);
      assertAlmostEqual(VAMMBase.averagePriceBetweenTicks(tickLower, tickUpper), ONE);
      assertAlmostEqual(VAMMBase.averagePriceBetweenTicks(tickLower, tickUpper), expectedAveragePrice);

      // We expect -baseTokens * liquidityIndex[current] * (1 + fixedRate[ofSpecifiedTicks] * timeInYearsTillMaturity)
      //         = -5e10       * mockLiquidityIndex      * (1 + expectedAveragePrice        * 1)         
      //         = -5e10       * mockLiquidityIndex      * (1 + ~1)         
      //         = ~-20e10
      assertAlmostEqual(trackedValue, baseAmount * -2 * int256(mockLiquidityIndex));
    }

    function testFuzz_FixedTokensInHomogeneousTickWindow_VaryTicks(int24 tickLower, int24 tickUpper) public {
      (tickLower, tickUpper) = boundTicks(tickLower, tickUpper);
      int256 baseAmount = -9e30;
      uint256 mockLiquidityIndex = 1;
      uint256 maturityTimestamp = block.timestamp + convert(FixedAndVariableMath.SECONDS_IN_YEAR);
 
      UD60x18 currentLiquidityIndex = convert(mockLiquidityIndex);
      vm.mockCall(mockRateOracle, abi.encodeWithSelector(IRateOracle.getCurrentIndex.selector), abi.encode(currentLiquidityIndex));

      DatedIrsVamm.Data storage vamm = DatedIrsVamm.load(vammId);
      (int256 trackedValue) = vamm._fixedTokensInHomogeneousTickWindow(baseAmount, tickLower, tickUpper, maturityTimestamp);

      UD60x18 averagePrice = VAMMBase.averagePriceBetweenTicks(tickLower, tickUpper);

      // We expect -baseTokens * liquidityIndex[current] * (1 + fixedRate[ofSpecifiedTicks] * timeInYearsTillMaturity)
      //         = 9e30        * mockLiquidityIndex      * (1 + expectedAveragePrice        * 1)         
      //         = 9e30        * 2      * (1 + averagePrice)         
      assertAlmostExactlyEqual(SD59x18.wrap(trackedValue),
        SD59x18.wrap(mulUDxInt(
            ONE.add(averagePrice),
            -baseAmount * int256(mockLiquidityIndex)
        ))
      );
    }

    function testFuzz_FixedTokensInHomogeneousTickWindow_VaryTerm(uint256 secondsToMaturity) public {
      int256 baseAmount = -123e20;
      int24 tickLower = -1;
      int24 tickUpper = 1;
      uint256 mockLiquidityIndex = 8;
      uint256 SECONDS_IN_YEAR = convert(FixedAndVariableMath.SECONDS_IN_YEAR);

      // Bound term between 0 and one hundred years
      secondsToMaturity = bound(secondsToMaturity,  0, SECONDS_IN_YEAR * 100);
      uint256 maturityTimestamp = block.timestamp + secondsToMaturity;
      UD60x18 timeInYearsTillMaturity = convert(secondsToMaturity).div(FixedAndVariableMath.SECONDS_IN_YEAR);
 
      UD60x18 currentLiquidityIndex = convert(mockLiquidityIndex);
      vm.mockCall(mockRateOracle, abi.encodeWithSelector(IRateOracle.getCurrentIndex.selector), abi.encode(currentLiquidityIndex));

      DatedIrsVamm.Data storage vamm = DatedIrsVamm.load(vammId);
      (int256 trackedValue) = vamm._fixedTokensInHomogeneousTickWindow(baseAmount, tickLower, tickUpper, maturityTimestamp);
      assertAlmostExactlyEqual(VAMMBase.averagePriceBetweenTicks(tickLower, tickUpper), ONE);

      // We expect -baseTokens * liquidityIndex[current] * (1 + fixedRate[ofSpecifiedTicks] * timeInYearsTillMaturity)
      //         = 123e20        * mockLiquidityIndex      * (1 + ~1                          * timeInYearsTillMaturity)         
      //         = 123e20        * 2      * (1 + ~timeInYearsTillMaturity)         
      assertAlmostExactlyEqual(SD59x18.wrap(trackedValue),
        SD59x18.wrap(mulUDxInt(
            ONE.add(timeInYearsTillMaturity),
            -baseAmount * int256(mockLiquidityIndex)
        ))
      );
    }

    // TODO: test that the weighted average of two average prices, using intervals (a,b) and (b,c) is the same as that of interval (a,c)
    // This assumption may be implicit in the behaviour of `_getUnfilledTokenValues()`, so we should check it.
    // function test_NewPositionTracking() public {
    //     uint128 accountId = 1;
    //     int24 tickLower = 2;
    //     int24 tickUpper = 3;
    //     (uint256 positionId, LPPosition.Data memory p) = openPosition(accountId,tickLower,tickUpper);

    //     // Position just opened so no filled balances
    //     (int256 baseBalancePool, int256 quoteBalancePool) = vamm.getAccountFilledBalances(accountId);
    //     assertEq(baseBalancePool, 0);
    //     assertEq(quoteBalancePool, 0);
    
    //     // Position just opened so no unfilled balances
    //     UD60x18 currentLiquidityIndex = ud60x18(100e18);
    //     vm.mockCall(mockRateOracle, abi.encodeWithSelector(IRateOracle.getCurrentIndex.selector), abi.encode(currentLiquidityIndex));
    //     (int256 unfilledBaseLong, int256 unfilledBaseShort) = vamm.getAccountUnfilledBases(accountId);
    //     assertEq(unfilledBaseLong, 0);
    //     assertEq(unfilledBaseShort, 0);
    // }

    function test_GetAccountUnfilledBases() public {
        DatedIrsVamm.Data storage vamm = DatedIrsVamm.load(vammId);

        uint128 accountId = 1;
        uint160 sqrtLowerPriceX96 = uint160(1 * FixedPoint96.Q96 / 10); // 0.1 => price ~= 0.01 = 1%
        uint160 sqrtUpperPriceX96 = uint160(22 * FixedPoint96.Q96 / 100); // 0.22 => price ~= 0.0484 = ~5%
        // console2.log("sqrtUpperPriceX96 = %s", sqrtUpperPriceX96); // TODO_delete_log
        // console2.log("maxSqrtRatio      = %s", uint256(2507794810551837817144115957740)); // TODO_delete_log

        int24 tickLower = TickMath.getTickAtSqrtRatio(sqrtLowerPriceX96);
        int24 tickUpper = TickMath.getTickAtSqrtRatio(sqrtUpperPriceX96);
        int128 requestedBaseAmount = 50_000_000_000;

        int256 executedBaseAmount = vamm.executeDatedMakerOrder(accountId,sqrtLowerPriceX96,sqrtUpperPriceX96, requestedBaseAmount);
        // console2.log("executedBaseAmount = %s", executedBaseAmount); // TODO_delete_log
        assertAlmostEqual(executedBaseAmount, requestedBaseAmount);

        // Position just opened so no filled balances
        (int256 baseBalancePool, int256 quoteBalancePool) = vamm.getAccountFilledBalances(accountId);
        assertEq(baseBalancePool, 0);
        assertEq(quoteBalancePool, 0);

        // We expect the full base amount is unfilled cos there have been no trades
        (int256 unfilledBaseLong, int256 unfilledBaseShort) = vamm.getAccountUnfilledBases(accountId);
        // console2.log("unfilledBaseLong", unfilledBaseLong); // TODO_delete_log
        // console2.log("unfilledBaseShort", unfilledBaseShort); // TODO_delete_log
        uint256 distanceToLower = tickDistanceFromCurrentToTick(tickLower);
        uint256 distanceToUpper = tickDistanceFromCurrentToTick(tickUpper);
        // console2.log("distanceToLower", distanceToLower); // TODO_delete_log
        // console2.log("distanceToUpper", distanceToUpper); // TODO_delete_log

        if (distanceToLower > distanceToUpper) {
            assertGt(abs(unfilledBaseShort), abs(unfilledBaseLong), "short <= long");
        } else if (distanceToLower < distanceToUpper) {
            assertLt(abs(unfilledBaseShort), abs(unfilledBaseLong), "short >= long");
        } else {
            // Distances are equal
            assertEq(abs(unfilledBaseShort), abs(unfilledBaseLong), "short != long");
        }

        // Absolute value of long and shorts should add up to executed amount
        assertEq(unfilledBaseLong - unfilledBaseShort, executedBaseAmount);

        // The current price is within the tick range, so we expect the accumulator to equal basePerTick
        int128 basePerTick = VAMMBase.basePerTick(tickLower, tickUpper, executedBaseAmount.toInt128());
        assertEq(vamm.vars.accumulator.toInt128(), basePerTick);

        // We also expect liquidityGross to equal basePerTick for both upper and lower ticks 
        assertEq(vamm.vars._ticks[tickLower].liquidityGross.toInt128(), basePerTick);
        assertEq(vamm.vars._ticks[tickUpper].liquidityGross.toInt128(), basePerTick);

        // When moving left to right (right to left), basePerTick should be added (subtracted) at the lower tick and subtracted (added) at the upper tick 
        assertEq(vamm.vars._ticks[tickLower].liquidityNet, basePerTick);
        assertEq(vamm.vars._ticks[tickUpper].liquidityNet, -basePerTick);
    }

    // TODO: extend to 3 or more LPs and test TickInfo when multiple LPs start/end at same tick
    function test_GetAccountUnfilledBases_TwoLPs() public {
        DatedIrsVamm.Data storage vamm = DatedIrsVamm.load(vammId);
        int24 lp1tickLower;
        int24 lp1tickUpper;
        int128 lp1basePerTick;

        // First LP
        {
            uint128 accountId = 1;
            uint160 sqrtLowerPriceX96 = uint160(1 * FixedPoint96.Q96 / 10); // 0.1 => price = 0.01 = 1%
            uint160 sqrtUpperPriceX96 = uint160(22 * FixedPoint96.Q96 / 100); // 0.22 => price = 0.0484 = 4.84%
            // console2.log("sqrtUpperPriceX96 = %s", sqrtUpperPriceX96); // TODO_delete_log
            // console2.log("maxSqrtRatio      = %s", uint256(2507794810551837817144115957740)); // TODO_delete_log

            int24 tickLower = TickMath.getTickAtSqrtRatio(sqrtLowerPriceX96);
            int24 tickUpper = TickMath.getTickAtSqrtRatio(sqrtUpperPriceX96);
            int128 requestedBaseAmount = 50_000_000_000;

            int256 executedBaseAmount = vamm.executeDatedMakerOrder(accountId,sqrtLowerPriceX96,sqrtUpperPriceX96, requestedBaseAmount);
            // console2.log("executedBaseAmount = %s", executedBaseAmount); // TODO_delete_log
            assertAlmostEqual(executedBaseAmount, requestedBaseAmount);

            // Position just opened so no filled balances
            (int256 baseBalancePool, int256 quoteBalancePool) = vamm.getAccountFilledBalances(accountId);
            assertEq(baseBalancePool, 0);
            assertEq(quoteBalancePool, 0);

            // We expect the full base amount is unfilled cos there have been no trades
            (int256 unfilledBaseLong, int256 unfilledBaseShort) = vamm.getAccountUnfilledBases(accountId);
            // console2.log("unfilledBaseLong", unfilledBaseLong); // TODO_delete_log
            // console2.log("unfilledBaseShort", unfilledBaseShort); // TODO_delete_log
            uint256 distanceToLower = tickDistanceFromCurrentToTick(tickLower);
            uint256 distanceToUpper = tickDistanceFromCurrentToTick(tickUpper);
            // console2.log("distanceToLower", distanceToLower); // TODO_delete_log
            // console2.log("distanceToUpper", distanceToUpper); // TODO_delete_log

            if (distanceToLower > distanceToUpper) {
                assertGt(abs(unfilledBaseShort), abs(unfilledBaseLong), "short <= long");
            } else if (distanceToLower < distanceToUpper) {
                assertLt(abs(unfilledBaseShort), abs(unfilledBaseLong), "short >= long");
            } else {
                // Distances are equal
                assertEq(abs(unfilledBaseShort), abs(unfilledBaseLong), "short != long");
            }

            // Absolute value of long and shorts should add up to executed amount
            assertEq(unfilledBaseLong - unfilledBaseShort, executedBaseAmount);

            // The current price is within the tick range, so we expect the accumulator to equal basePerTick
            int128 basePerTick = VAMMBase.basePerTick(tickLower, tickUpper, executedBaseAmount.toInt128());
            assertEq(vamm.vars.accumulator.toInt128(), basePerTick);

            // We also expect liquidityGross to equal basePerTick for both upper and lower ticks 
            assertEq(vamm.vars._ticks[tickLower].liquidityGross.toInt128(), basePerTick);
            assertEq(vamm.vars._ticks[tickUpper].liquidityGross.toInt128(), basePerTick);

            // When moving left to right (right to left), basePerTick should be added (subtracted) at the lower tick and subtracted (added) at the upper tick 
            assertEq(vamm.vars._ticks[tickLower].liquidityNet, basePerTick);
            assertEq(vamm.vars._ticks[tickUpper].liquidityNet, -basePerTick);

            // Save some values for additional testing after extra LPs
            lp1tickLower = tickLower;
            lp1tickUpper = tickUpper;
            lp1basePerTick = basePerTick;
        }

        // Second LP
        {
            uint128 accountId = 2;
            uint160 sqrtLowerPriceX96 = uint160(15 * FixedPoint96.Q96 / 100); // 0.15 => price = 0.0225 = 2.25%
            uint160 sqrtUpperPriceX96 = uint160(25 * FixedPoint96.Q96 / 100); // 0.25 => price = 0.0625 = 6.25%
            // console2.log("sqrtUpperPriceX96 = %s", sqrtUpperPriceX96); // TODO_delete_log
            // console2.log("maxSqrtRatio      = %s", uint256(2507794810551837817144115957740)); // TODO_delete_log

            int24 tickLower = TickMath.getTickAtSqrtRatio(sqrtLowerPriceX96);
            int24 tickUpper = TickMath.getTickAtSqrtRatio(sqrtUpperPriceX96);
            int128 requestedBaseAmount = 50_000_000_000;

            int256 executedBaseAmount = vamm.executeDatedMakerOrder(accountId,sqrtLowerPriceX96,sqrtUpperPriceX96, requestedBaseAmount);
            // console2.log("executedBaseAmount = %s", executedBaseAmount); // TODO_delete_log
            assertAlmostEqual(executedBaseAmount, requestedBaseAmount);

            // Position just opened so no filled balances
            (int256 baseBalancePool, int256 quoteBalancePool) = vamm.getAccountFilledBalances(accountId);
            assertEq(baseBalancePool, 0);
            assertEq(quoteBalancePool, 0);

            // We expect the full base amount is unfilled cos there have been no trades
            (int256 unfilledBaseLong, int256 unfilledBaseShort) = vamm.getAccountUnfilledBases(accountId);
            // console2.log("unfilledBaseLong", unfilledBaseLong); // TODO_delete_log
            // console2.log("unfilledBaseShort", unfilledBaseShort); // TODO_delete_log
            uint256 distanceToLower = tickDistanceFromCurrentToTick(tickLower);
            uint256 distanceToUpper = tickDistanceFromCurrentToTick(tickUpper);
            // console2.log("distanceToLower", distanceToLower); // TODO_delete_log
            // console2.log("distanceToUpper", distanceToUpper); // TODO_delete_log

            if (distanceToLower > distanceToUpper) {
                assertGt(abs(unfilledBaseShort), abs(unfilledBaseLong), "short <= long");
            } else if (distanceToLower < distanceToUpper) {
                assertLt(abs(unfilledBaseShort), abs(unfilledBaseLong), "short >= long");
            } else {
                // Distances are equal
                assertEq(abs(unfilledBaseShort), abs(unfilledBaseLong), "short != long");
            }

            // Absolute value of long and shorts should add up to executed amount
            assertEq(unfilledBaseLong - unfilledBaseShort, executedBaseAmount);

            // The current price is within both tick ranges, so we expect the accumulator to equal the sum of two basePerTick values
            int128 basePerTick = VAMMBase.basePerTick(tickLower, tickUpper, executedBaseAmount.toInt128());
            assertEq(vamm.vars.accumulator.toInt128(), basePerTick + lp1basePerTick);

            // We expect liquidityGross to equal basePerTick for both upper and lower ticks 
            assertEq(vamm.vars._ticks[tickLower].liquidityGross.toInt128(), basePerTick);
            assertEq(vamm.vars._ticks[tickUpper].liquidityGross.toInt128(), basePerTick);

            // When moving left to right (right to left), basePerTick should be added (subtracted) at the lower tick and subtracted (added) at the upper tick 
            assertEq(vamm.vars._ticks[tickLower].liquidityNet, basePerTick);
            assertEq(vamm.vars._ticks[tickUpper].liquidityNet, -basePerTick);
        }
    }

    function testFuzz_GetAccountUnfilledBases(
        uint128 accountId,
        int24 tickLower,
        int24 tickUpper,
        int128 requestedBaseAmount,
        uint256 _mockLiquidityIndex
    ) public {
        vm.assume(accountId != 0);
        (tickLower, tickUpper) = boundTicks(tickLower, tickUpper);
        logTicks(tickLower, tickUpper, "testFuzz_GetAccountUnfilledBases");
        vm.assume(tickUpper != TickMath.MAX_TICK); // TODO: seems to fail (error "LO") at maxTick - is that OK?
        requestedBaseAmount = boundNewPositionLiquidityAmount(requestedBaseAmount, tickLower, tickUpper); // Cannot withdraw liquidity before we add it
        uint160 sqrtLowerPriceX96 = TickMath.getSqrtRatioAtTick(tickLower);
        uint160 sqrtUpperPriceX96 = TickMath.getSqrtRatioAtTick(tickUpper);

        DatedIrsVamm.Data storage vamm = DatedIrsVamm.load(vammId);
        int256 executedBaseAmount = vamm.executeDatedMakerOrder(accountId,sqrtLowerPriceX96,sqrtUpperPriceX96, requestedBaseAmount);
        // console2.log("executedBaseAmount = %s", executedBaseAmount); // TODO_delete_log
        assertLe(executedBaseAmount, requestedBaseAmount);

        // Position just opened so no filled balances
        (int256 baseBalancePool, int256 quoteBalancePool) = vamm.getAccountFilledBalances(accountId);
        assertEq(baseBalancePool, 0);
        assertEq(quoteBalancePool, 0);
    
        // We expect the full base amount is unfilled cos there have been no trades
        (int256 unfilledBaseLong, int256 unfilledBaseShort) = vamm.getAccountUnfilledBases(accountId);
        // console2.log("unfilledBaseLong", unfilledBaseLong); // TODO_delete_log
        // console2.log("unfilledBaseShort", unfilledBaseShort); // TODO_delete_log
        uint256 distanceToLower = tickDistanceFromCurrentToTick(tickLower);
        uint256 distanceToUpper = tickDistanceFromCurrentToTick(tickUpper);
        // console2.log("distanceToLower", distanceToLower); // TODO_delete_log
        // console2.log("distanceToUpper", distanceToUpper); // TODO_delete_log
        if (distanceToLower > distanceToUpper) {
            assertGe(abs(unfilledBaseShort), abs(unfilledBaseLong), "short < long");
        } else if (distanceToLower < distanceToUpper) {
            assertLe(abs(unfilledBaseShort), abs(unfilledBaseLong), "short > long");
        } else {
            // Distances are equal
            assertEq(abs(unfilledBaseShort), abs(unfilledBaseLong), "short != long");
        }
        assertEq(unfilledBaseLong - unfilledBaseShort, executedBaseAmount);
    }
}