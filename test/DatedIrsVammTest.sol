pragma solidity >=0.8.13;

import "forge-std/Test.sol";
 import "forge-std/console2.sol";
 import "../contracts/utils/SafeCastUni.sol";
import "../contracts/VAMM/storage/DatedIrsVAMM.sol";
import "../contracts/utils/CustomErrors.sol";
import { UD60x18, convert, ud60x18, uMAX_UD60x18, uUNIT } from "@prb/math/src/UD60x18.sol";
import { SD59x18, sd59x18 } from "@prb/math/src/SD59x18.sol";

// TODO: VoltzTestHelpers into own source file
contract VoltzTestHelpers is Test {

    /// @dev The minimum tick that may be passed to #getSqrtRatioAtTick computed from log base 1.0001 of 2**-128
    int24 internal constant MIN_TICK = -69100;
    /// @dev The maximum tick that may be passed to #getSqrtRatioAtTick computed from log base 1.0001 of 2**128
    int24 internal constant MAX_TICK = -MIN_TICK;

    // Helpers
    function abs(int256 x) pure internal returns (uint256) {
        return x >= 0 ? uint256(x) : uint256(-x);
    }
    function min(int256 a, int256 b) pure internal returns (int256) {
        return a > b ? b : a;
    }
    function min(int24 a, int24 b) pure internal returns (int24) {
        return a > b ? b : a;
    }
    // function max(int256 a, int256 b) pure internal returns (int256) {
    //     return a < b ? b : a;
    // }
    function logTicks(int24 a, int24 b, string memory _message) internal view {
        // string memory message = bytes(_message).length > 0 ? _message : "Ticks: ";
        // console2.log(_message, bytes(_message).length > 0 ? " ticks: " : "Ticks:"); // TODO_delete_log
        console2.logInt(a);
        console2.logInt(b);
    }
    function boundTicks(
        int24 _tickLower,
        int24 _tickUpper)
    internal view returns (int24 tickLower, int24 tickUpper)
    {
        // Ticks must be in range and cannot be equal
        tickLower = int24(bound(_tickLower,  TickMath.MIN_TICK, TickMath.MAX_TICK - 1));
        tickUpper = int24(bound(_tickUpper,  TickMath.MIN_TICK + 1, TickMath.MAX_TICK));
        vm.assume(tickLower < tickUpper);
    }
    function tickDistance(int24 _tickA, int24 _tickB) public view returns (uint256 absoluteDistance) {
        return abs(_tickA - _tickB);
    }

    using SafeCastUni for int256;

    // Assertions
    function assertEq(UD60x18 a, UD60x18 b) internal {
        assertEq(UD60x18.unwrap(a), UD60x18.unwrap(b));
    }
    function assertEq(SD59x18 a, SD59x18 b) internal {
        assertEq(SD59x18.unwrap(a), SD59x18.unwrap(b));
    }
    function assertGt(UD60x18 a, UD60x18 b) internal {
        assertGt(UD60x18.unwrap(a), UD60x18.unwrap(b));
    }
    function assertLt(UD60x18 a, UD60x18 b) internal {
        assertLt(UD60x18.unwrap(a), UD60x18.unwrap(b));
    }
    function assertAlmostEqual(SD59x18 a, SD59x18 b, SD59x18 deltaAsFractionOfA) internal {
        if (SD59x18.unwrap(a) == SD59x18.unwrap(b)) {
            // Equal (needed for case where a = b = 0)
            return;
        }
        SD59x18 upperBound = SD59x18.unwrap(a) >= 0 ? a.add(deltaAsFractionOfA.mul(a)) : a.sub(deltaAsFractionOfA.mul(a));
        SD59x18 lowerBound = SD59x18.unwrap(a) >= 0 ? a.sub(deltaAsFractionOfA.mul(a)) : a.add(deltaAsFractionOfA.mul(a));
        if (b.gt(upperBound) || b.lt(lowerBound)) {
            // console2.log("Expected the following two values to be almost equal:"); // TODO_delete_log
            console2.logInt(SD59x18.unwrap(a));
            console2.logInt(SD59x18.unwrap(b));
        }
        assertGe(SD59x18.unwrap(b), SD59x18.unwrap(lowerBound) );
        assertLe(SD59x18.unwrap(b), SD59x18.unwrap(upperBound) );
    }
    function assertAlmostEqual(UD60x18 a, UD60x18 b, UD60x18 deltaAsFractionOfA) internal {
        if (UD60x18.unwrap(a) == UD60x18.unwrap(b)) {
            // Equal (needed for case where a = b = 0)
            return;
        }

        UD60x18 upperBound = a.add(deltaAsFractionOfA.mul(a));
        UD60x18 lowerBound = a.sub(deltaAsFractionOfA.mul(a));
        if (b.gt(upperBound) || b.lt(lowerBound)) {
            console.log("Expected %s <= %s <= %s", UD60x18.unwrap(lowerBound), UD60x18.unwrap(b), UD60x18.unwrap(upperBound));
        }
        assertGe(UD60x18.unwrap(b), UD60x18.unwrap(lowerBound) );
        assertLe(UD60x18.unwrap(b), UD60x18.unwrap(upperBound) );
    }
    function assertAlmostEqual(UD60x18 a, UD60x18 b) internal {
        UD60x18 deltaAsFractionOfA = ud60x18(1e14); // 0.01%
        assertAlmostEqual(a, b, deltaAsFractionOfA);
    }
    function assertAlmostExactlyEqual(UD60x18 a, UD60x18 b) internal {
        UD60x18 deltaAsFractionOfA = ud60x18(1e12); // 0.0001%
        assertAlmostEqual(a, b, deltaAsFractionOfA);
    }
    function assertAlmostEqual(SD59x18 a, SD59x18 b) internal {
        SD59x18 deltaAsFractionOfA = sd59x18(1e14); // 0.01%
        assertAlmostEqual(a, b, deltaAsFractionOfA);
    }
    function assertAlmostExactlyEqual(SD59x18 a, SD59x18 b) internal {
        SD59x18 deltaAsFractionOfA = sd59x18(1e12); // 0.0001%
        assertAlmostEqual(a, b, deltaAsFractionOfA);
    }
    function assertAlmostEqual(int256 a, int256 b) internal {
        assertAlmostEqual(SD59x18.wrap(a), SD59x18.wrap(b));
    }
    function assertEq(UD60x18 a, UD60x18 b, string memory err) internal {
        assertEq(UD60x18.unwrap(a), UD60x18.unwrap(b), err);
    }
}



// Constants
UD60x18 constant ONE = UD60x18.wrap(1e18);

// TODO: Break up this growing test contract into more multiple separate tests for increased readability
contract VammTest is VoltzTestHelpers {
    // Contracts under test
    using DatedIrsVamm for DatedIrsVamm.Data;
    using SafeCastUni for uint256;
    DatedIrsVamm.Data internal vamm;

    address constant mockRateOracle = 0xAa73aA73Aa73Aa73AA73Aa73aA73AA73aa73aa73;

    // Test state
    // uint256 latestPositionId;

    // Initial VAMM state
    uint160 initSqrtPriceX96 = uint160(2 * FixedPoint96.Q96 / 10); // 0.2 => price ~= 0.04 = 4%
    uint128 initMarketId = 1;
    int24 initTickSpacing = 1; // TODO: test with different tick spacing; need to adapt boundTicks()
    DatedIrsVamm.Config internal config = DatedIrsVamm.Config({
        priceImpactPhi: ud60x18(1e17), // 0.1
        priceImpactBeta: ud60x18(125e15), // 0.125
        spread: ud60x18(3e15), // 0.3%
        rateOracle: IRateOracle(mockRateOracle)
    });

    function setUp() public {
        vamm.initialize(initSqrtPriceX96, block.timestamp + convert(FixedAndVariableMath.SECONDS_IN_YEAR), initMarketId, initTickSpacing, config);
    }

    function test_Init_State() public {
        assertEq(vamm._vammVars.sqrtPriceX96, initSqrtPriceX96); 
        assertEq(vamm._vammVars.tick, TickMath.getTickAtSqrtRatio(initSqrtPriceX96)); 
        assertEq(vamm._vammVars.observationIndex, 0); 
        assertEq(vamm._vammVars.observationCardinality, 1); 
        assertEq(vamm._vammVars.observationCardinalityNext, 1); 
        assertEq(vamm._vammVars.feeProtocol, 0); 
        assertEq(vamm._vammVars.unlocked, true); 
        assertEq(vamm.config.priceImpactPhi, config.priceImpactPhi); 
        assertEq(vamm.config.priceImpactBeta, config.priceImpactBeta); 
        assertEq(vamm.config.spread, config.spread); 
        assertEq(address(vamm.config.rateOracle), address(config.rateOracle)); 

        // Check that we cannot re-init
        vm.expectRevert();
        vamm.initialize(initSqrtPriceX96, block.timestamp + 100, initMarketId, initTickSpacing, config);
    }

    function test_Init_Twap_Unadjusted() public {
        int24 tick = vamm._vammVars.tick;
        assertEq(vamm.observe(0), tick); 

        // no lookback, no adjustments
        UD60x18 geometricMeanPrice = vamm.twap(0, 0, false, false);
        assertEq(geometricMeanPrice, VAMMBase.getPriceFromTick(tick)); 
        assertAlmostEqual(geometricMeanPrice, ud60x18(4e16)); // Approx 0.04. Not exact cos snaps to tick boundary.
    }

    function test_Init_Twap_WithSpread() public {
        int24 tick = vamm._vammVars.tick;
        assertEq(vamm.observe(0), tick); 

        {
            // no lookback, adjust for spread, positive order size
            UD60x18 twapPrice = vamm.twap(0, 1, false, true);
            // Spread adds 0.3% to the price (as an absolute amount, not as a percentage of the price)
            assertEq(twapPrice, VAMMBase.getPriceFromTick(tick).add(config.spread)); 
        }

        {
            // no lookback, adjust for spread, negative order size
            UD60x18 twapPrice = vamm.twap(0, -1, false, true);
            // Spread subtracts 0.3% from the price (as an absolute amount, not as a percentage of the price)
            assertEq(twapPrice, VAMMBase.getPriceFromTick(tick).sub(config.spread));
        }
    }

    function test_Init_Twap_WithPriceImpact() public {
        int24 tick = vamm._vammVars.tick;
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

        int24 tick = vamm._vammVars.tick;
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
    internal returns (UD60x18)
    {
        UD60x18 sumOfPrices = VAMMBase.getPriceFromTick(tickLower);
        for (int24 i = tickLower + 1; i <= tickUpper; i++) {
            sumOfPrices = sumOfPrices.add(VAMMBase.getPriceFromTick(i));
        }
        return sumOfPrices.div(convert(uint256(int256(1 + tickUpper - tickLower))));
    }

    function test_AveragePriceBetweenTicks()
    public {
        // The greater the tick range, the more the real answer deviates from a naive average of the top and bottom price
        // a range of ~500 is sufficient to illustrate a diversion, but note that larger ranges have much larger diversions
        int24 tickLower = 2;
        int24 tickUpper = 500;
        UD60x18 expected = averagePriceBetweenTicksUsingLoop(tickLower, tickUpper);
        assertAlmostEqual(VAMMBase.averagePriceBetweenTicks(tickLower, tickUpper), expected);
    }

    function test_AveragePriceBetweenTicks2()
    public {
        // Test a nagative range
        int24 tickLower = -10;
        int24 tickUpper = 10;
        UD60x18 expected = averagePriceBetweenTicksUsingLoop(tickLower, tickUpper);
        assertAlmostEqual(VAMMBase.averagePriceBetweenTicks(tickLower, tickUpper), expected);
    }

    function testSlowFuzz_AveragePriceBetweenTicks(
        int24 tickLower,
        int24 tickUpper)
    public {
        (tickLower, tickUpper) = boundTicks(tickLower, tickUpper);
        UD60x18 expected = averagePriceBetweenTicksUsingLoop(tickLower, tickUpper);
        assertAlmostEqual(VAMMBase.averagePriceBetweenTicks(tickLower, tickUpper), expected);
    }

    function testFail_GetUnopenedPosition() public {
        vamm.getRawPosition(1);
    }

    function testFuzz_GetAccountFilledBalancesUnusedAccount(uint128 accountId) public {
        (int256 baseBalancePool, int256 quoteBalancePool) = vamm.getAccountFilledBalances(accountId);
        assertEq(baseBalancePool, 0);
        assertEq(quoteBalancePool, 0);
    }

    function testFuzz_GetAccountUnfilledBasesUnusedAccount(uint128 accountId) public {
        (int256 unfilledBaseLong, int256 unfilledBaseShort) = vamm.getAccountUnfilledBases(accountId);
        assertEq(unfilledBaseLong, 0);
        assertEq(unfilledBaseShort, 0);
    }

    function openPosition(
        uint128 accountId,
        int24 tickLower,
        int24 tickUpper)
    internal
    returns (uint256 positionId, DatedIrsVamm.LPPosition memory position)
    {
        positionId = vamm._ensurePositionOpened(accountId,tickLower,tickUpper);
        position = vamm.positions[positionId];
    }

    function testFuzz_EnsurePositionOpened(uint128 accountId, int24 tickLower, int24 tickUpper) public {
        vm.assume(accountId != 0);
        (tickLower, tickUpper) = boundTicks(tickLower, tickUpper);

        (uint256 positionId, DatedIrsVamm.LPPosition memory p) = openPosition(accountId,tickLower,tickUpper);
        assertEq(positionId, DatedIrsVamm.getPositionId(accountId,tickLower,tickUpper));
        assertEq(p.accountId, accountId);
        assertEq(p.tickLower, tickLower);
        assertEq(p.tickUpper, tickUpper);
        assertEq(p.baseAmount, 0);
        assertEq(p.trackerVariableTokenUpdatedGrowth, 0);
        assertEq(p.trackerBaseTokenUpdatedGrowth, 0);
        assertEq(p.trackerVariableTokenAccumulated, 0);
        assertEq(p.trackerBaseTokenAccumulated, 0);
        vamm.getRawPosition(positionId);
    }

    function test_TrackFixedTokens() public {
      int256 baseAmount = 5e10;
      int24 tickLower = -1;
      int24 tickUpper = 1;
      uint256 mockLiquidityIndex = 2;
      uint256 termEndTimestamp = block.timestamp + convert(FixedAndVariableMath.SECONDS_IN_YEAR);
 
      UD60x18 currentLiquidityIndex = convert(mockLiquidityIndex);
      vm.mockCall(mockRateOracle, abi.encodeWithSelector(IRateOracle.getCurrentIndex.selector), abi.encode(currentLiquidityIndex));

      (int256 trackedValue) = vamm._trackFixedTokens(baseAmount, tickLower, tickUpper, termEndTimestamp);

      UD60x18 expectedAveragePrice = averagePriceBetweenTicksUsingLoop(tickLower, tickUpper);
      assertAlmostEqual(VAMMBase.averagePriceBetweenTicks(tickLower, tickUpper), ONE);

      // We expect -baseTokens * liquidityIndex[current] * (1 + fixedRate[ofSpecifiedTicks] * timeInYearsTillMaturity)
      //         = -5e10       * mockLiquidityIndex      * (1 + expectedAveragePrice        * 1)         
      //         = -5e10       * mockLiquidityIndex      * (1 + ~1)         
      //         = ~-20e10
      assertAlmostEqual(trackedValue, baseAmount * -2 * int256(mockLiquidityIndex));
    }

    function testFuzz_TrackFixedTokens_VaryTicks(int24 tickLower, int24 tickUpper) public {
      (tickLower, tickUpper) = boundTicks(tickLower, tickUpper);
      int256 baseAmount = -9e30;
      uint256 mockLiquidityIndex = 1;
      uint256 termEndTimestamp = block.timestamp + convert(FixedAndVariableMath.SECONDS_IN_YEAR);
 
      UD60x18 currentLiquidityIndex = convert(mockLiquidityIndex);
      vm.mockCall(mockRateOracle, abi.encodeWithSelector(IRateOracle.getCurrentIndex.selector), abi.encode(currentLiquidityIndex));

      (int256 trackedValue) = vamm._trackFixedTokens(baseAmount, tickLower, tickUpper, termEndTimestamp);

      UD60x18 averagePrice = VAMMBase.averagePriceBetweenTicks(tickLower, tickUpper);

      // We expect -baseTokens * liquidityIndex[current] * (1 + fixedRate[ofSpecifiedTicks] * timeInYearsTillMaturity)
      //         = 9e30        * mockLiquidityIndex      * (1 + expectedAveragePrice        * 1)         
      //         = 9e30        * 2      * (1 + averagePrice)         
      assertAlmostExactlyEqual(convert(trackedValue), convert(-baseAmount * int256(mockLiquidityIndex)).mul(VAMMBase.sd59x18(ONE.add(averagePrice))));
    }

    function testFuzz_TrackFixedTokens_VaryTerm(uint256 secondsToMaturity) public {
      int256 baseAmount = -123e20;
      int24 tickLower = -1;
      int24 tickUpper = 1;
      uint256 mockLiquidityIndex = 8;
      uint256 SECONDS_IN_YEAR = convert(FixedAndVariableMath.SECONDS_IN_YEAR);

      // Bound term between 0 and one hundred years
      secondsToMaturity = bound(secondsToMaturity,  0, SECONDS_IN_YEAR * 100);
      uint256 termEndTimestamp = block.timestamp + secondsToMaturity;
      UD60x18 timeInYearsTillMaturity = convert(secondsToMaturity).div(FixedAndVariableMath.SECONDS_IN_YEAR);
 
      UD60x18 currentLiquidityIndex = convert(mockLiquidityIndex);
      vm.mockCall(mockRateOracle, abi.encodeWithSelector(IRateOracle.getCurrentIndex.selector), abi.encode(currentLiquidityIndex));

      (int256 trackedValue) = vamm._trackFixedTokens(baseAmount, tickLower, tickUpper, termEndTimestamp);
      assertAlmostExactlyEqual(VAMMBase.averagePriceBetweenTicks(tickLower, tickUpper), ONE);

      // We expect -baseTokens * liquidityIndex[current] * (1 + fixedRate[ofSpecifiedTicks] * timeInYearsTillMaturity)
      //         = 123e20        * mockLiquidityIndex      * (1 + ~1                          * timeInYearsTillMaturity)         
      //         = 123e20        * 2      * (1 + ~timeInYearsTillMaturity)         
      assertAlmostExactlyEqual(convert(trackedValue), convert(-baseAmount * int256(mockLiquidityIndex)).mul(VAMMBase.sd59x18(timeInYearsTillMaturity.add(ONE))));
    }

    // TODO: test that the weighted average of two average prices, using intervals (a,b) and (b,c) is the same as that of interval (a,c)
    // This assumption may be implicit in the behaviour of `_trackValuesBetweenTicks()`, so we should check it.
    function test_NewPositionTracking() public {
        uint128 accountId = 1;
        int24 tickLower = 2;
        int24 tickUpper = 3;
        (uint256 positionId, DatedIrsVamm.LPPosition memory p) = openPosition(accountId,tickLower,tickUpper);

        // Position just opened so no filled balances
        (int256 baseBalancePool, int256 quoteBalancePool) = vamm.getAccountFilledBalances(accountId);
        assertEq(baseBalancePool, 0);
        assertEq(quoteBalancePool, 0);
    
        // Position just opened so no unfilled balances
        UD60x18 currentLiquidityIndex = ud60x18(100e18);
        vm.mockCall(mockRateOracle, abi.encodeWithSelector(IRateOracle.getCurrentIndex.selector), abi.encode(currentLiquidityIndex));
        (int256 unfilledBaseLong, int256 unfilledBaseShort) = vamm.getAccountUnfilledBases(accountId);
        assertEq(unfilledBaseLong, 0);
        assertEq(unfilledBaseShort, 0);
    }

    function test_GetAccountUnfilledBases() public {
        uint128 accountId = 1;
        uint160 sqrtLowerPriceX96 = uint160(1 * FixedPoint96.Q96 / 10); // 0.1 => price ~= 0.01 = 1%
        uint160 sqrtUpperPriceX96 = uint160(22 * FixedPoint96.Q96 / 100); // 0.22 => price ~= 0.0484 = ~5%
        // console2.log("sqrtUpperPriceX96 = %s", sqrtUpperPriceX96); // TODO_delete_log
        // console2.log("maxSqrtRatio      = %s", uint256(2507794810551837817144115957740)); // TODO_delete_log

        int24 tickLower = TickMath.getTickAtSqrtRatio(sqrtLowerPriceX96);
        int24 tickUpper = TickMath.getTickAtSqrtRatio(sqrtUpperPriceX96);
        uint256 _mockLiquidityIndex = 2;
        UD60x18 mockLiquidityIndex = convert(_mockLiquidityIndex);
        int128 requestedBaseAmount = 50000000000;

        int256 executedBaseAmount = vamm.executeDatedMakerOrder(accountId,sqrtLowerPriceX96,sqrtUpperPriceX96, requestedBaseAmount);
        // console2.log("executedBaseAmount = %s", executedBaseAmount); // TODO_delete_log
        assertAlmostEqual(executedBaseAmount, requestedBaseAmount);

        // Position just opened so no filled balances
        (int256 baseBalancePool, int256 quoteBalancePool) = vamm.getAccountFilledBalances(accountId);
        assertEq(baseBalancePool, 0);
        assertEq(quoteBalancePool, 0);
    
        // TODO: liquidity index only required for fixed tokens; mocking should not be required if we only want base token values
        vm.mockCall(mockRateOracle, abi.encodeWithSelector(IRateOracle.getCurrentIndex.selector), abi.encode(mockLiquidityIndex));

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
        assertEq(unfilledBaseLong - unfilledBaseShort, executedBaseAmount);
    }

    function tickDistanceFromCurrentToTick(int24 _tick) public view returns (uint256 absoluteDistance) {
        int24 currentTick = vamm._vammVars.tick;
        return tickDistance(currentTick, _tick);
    }
    function boundNewPositionLiquidityAmount(
        int128 unboundBaseToken,
        int24 _tickLower,
        int24 _tickUpper)
    internal returns (int128 boundBaseTokens)
    {
        // Ticks must be in range and cannot be equal
        uint256 tickRange = tickDistance(_tickLower, _tickUpper);
        uint128 maxLiquidityPerTick = vamm._maxLiquidityPerTick;
        // console2.log("tickRange", tickRange); // TODO_delete_log
        // console2.log("maxLiquidityPerTick", maxLiquidityPerTick, maxLiquidityPerTick * tickRange); // TODO_delete_log
        int256 max = min(int256(type(int128).max), int256(uint256(maxLiquidityPerTick)) * int256(tickRange));

        return int128(bound(unboundBaseToken, 0, max)); // New positions cannot withdraw liquidity so >= 0
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
        _mockLiquidityIndex = bound(_mockLiquidityIndex, 1, 1000000e18); // TODO: push this higher - when does it break? Document limitations.
        vm.assume(_mockLiquidityIndex != 0);
        UD60x18 mockLiquidityIndex = ud60x18(_mockLiquidityIndex);

        int256 executedBaseAmount = vamm.executeDatedMakerOrder(accountId,sqrtLowerPriceX96,sqrtUpperPriceX96, requestedBaseAmount);
        // console2.log("executedBaseAmount = %s", executedBaseAmount); // TODO_delete_log
        assertLe(executedBaseAmount, requestedBaseAmount);

        // Position just opened so no filled balances
        (int256 baseBalancePool, int256 quoteBalancePool) = vamm.getAccountFilledBalances(accountId);
        assertEq(baseBalancePool, 0);
        assertEq(quoteBalancePool, 0);
    
        // TODO: liquidity index only required for fixed tokens; mocking should not be required if we only want base token values
        vm.mockCall(mockRateOracle, abi.encodeWithSelector(IRateOracle.getCurrentIndex.selector), abi.encode(mockLiquidityIndex));

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