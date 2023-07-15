pragma solidity >=0.8.13;

import "forge-std/Test.sol";
import "forge-std/console2.sol";
import "./DatedIrsVammTestUtil.sol";
import "../src/storage/LPPosition.sol";
import "../src/storage/DatedIrsVAMM.sol";
import "../utils/CustomErrors.sol";
import "../src/storage/LPPosition.sol";
import { mulUDxInt } from "@voltz-protocol/util-contracts/src/helpers/PrbMathHelper.sol";
import { UD60x18, convert as convertUd , ud60x18, uMAX_UD60x18, uUNIT } from "@prb/math/UD60x18.sol";
import { SD59x18, sd59x18, convert as convertSd } from "@prb/math/SD59x18.sol";
import "@voltz-protocol/util-contracts/src/helpers/SafeCast.sol";

// Constants
UD60x18 constant ONE = UD60x18.wrap(1e18);

contract VammTest_FreshVamm is DatedIrsVammTestUtil {
    using DatedIrsVamm for DatedIrsVamm.Data;
    using SafeCastU256 for uint256;
    using SafeCastU128 for uint128;
    using SafeCastI256 for int256;

    ExposedDatedIrsVamm vamm;

    uint32[] internal times;
    int24[] internal observedTicks;

    function setUp() public {
        vammId = uint256(keccak256(abi.encodePacked(initMarketId, initMaturityTimestamp)));
        vamm = new ExposedDatedIrsVamm(vammId);

        times = new uint32[](1);
        times[0] = uint32(block.timestamp);

        observedTicks = new int24[](1);
        observedTicks[0] = initialTick;

        vamm.create(initMarketId, initSqrtPriceX96, times, observedTicks, immutableConfig, mutableConfig);
        
        vamm.setMakerPositionsPerAccountLimit(1);
    }

    function test_Init_State() public {
        assertEq(vamm.sqrtPriceX96(), initSqrtPriceX96); 
        assertEq(vamm.tick(), TickMath.getTickAtSqrtRatio(initSqrtPriceX96)); 
        assertEq(vamm.observationIndex(), 0); 
        assertEq(vamm.observationCardinality(), 1); 
        assertEq(vamm.observationCardinalityNext(), 1); 
       //assertEq(vamm.vars.feeProtocol, 0); 
        assertEq(vamm.unlocked(), true); 
        assertEq(vamm.priceImpactPhi(), mutableConfig.priceImpactPhi); 
        assertEq(vamm.priceImpactBeta(), mutableConfig.priceImpactBeta); 
        assertEq(vamm.spread(), mutableConfig.spread); 
        assertEq(address(vamm.rateOracle()), address(mutableConfig.rateOracle)); 

        // Check that we cannot re-init
        vm.expectRevert();
        vamm.initialize(initSqrtPriceX96, times, observedTicks);
    }

    function test_Initialize_OracleBuffer() public {
        vamm = new ExposedDatedIrsVamm(vammId);

        uint256 length = 5;
        uint256 fixedDelta = 10;

        times = new uint32[](length);
        observedTicks = new int24[](length);

        times[0] = uint32(block.timestamp);
        observedTicks[0] = initialTick;
        for (uint256 i = 1; i < length; i += 1) {
            times[i] = times[i-1] + uint32(fixedDelta + i);
            observedTicks[i] = observedTicks[i-1] + int24(int256(i * 60) * ((i % 2 == 0) ? int256(1) : int256(-1)));
        }

        vamm.create(initMarketId, initSqrtPriceX96, times, observedTicks, immutableConfig, mutableConfig);

        assertEq(vamm.observationIndex(), length - 1);
        assertEq(vamm.observationCardinality(), length);
        assertEq(vamm.observationCardinalityNext(), length); 

        int56 tickCumulative = 0;
        for (uint256 i = 0; i < length; i += 1) {
            Oracle.Observation memory observation = vamm.observationAtIndex(uint16(i));
            assertEq(observation.blockTimestamp, times[i]);
            if (i > 0) {
                tickCumulative += int56(observedTicks[i]) * int56(uint56(times[i] - times[i-1]));
            }
            assertEq(observation.tickCumulative, tickCumulative);
        }
    }

    function testFuzz_BaseBetweenTicks(
        int24 tickLower,
        int24 tickUpper,
        int128 liquidity)
    public {
        (tickLower, tickUpper) = boundTicks(tickLower, tickUpper);
        // Check that baseBetweenTicks and getLiquidityForBase are symetric
        liquidity = boundNewPositionLiquidityAmount(type(uint128).max, tickLower, tickUpper, liquidity);
        int256 baseAmount = vamm.baseBetweenTicks(tickLower, tickUpper, liquidity);
        assertOffByNoMoreThan2OrAlmostEqual(getLiquidityForBase(tickLower, tickUpper, baseAmount), liquidity); // TODO: can we do better than off-by-two for small values? is it important?
    }

    function test_Init_Twap_Unadjusted() public {
        int24 tick = vamm.tick();
        assertEq(vamm.observe(0), tick); 

        // no lookback, no adjustments
        UD60x18 geometricMeanPrice = vamm.twap(0, 0, false, false);
        assertEq(geometricMeanPrice, vamm.getPriceFromTick(tick).div(convertUd(100))); 
        assertAlmostEqual(geometricMeanPrice, ud60x18(25e16)); // Approx 0.04. Not exact cos snaps to tick boundary.
    }

    function test_Init_Twap_WithSpread() public {
        int24 tick = vamm.tick();
        assertEq(vamm.observe(0), tick); 

        {
            // no lookback, adjust for spread, positive order size
            UD60x18 twapPrice = vamm.twap(0, 1, false, true);
            // Spread adds 0.3% to the price (as an absolute amount, not as a percentage of the price)
            assertEq(twapPrice, vamm.getPriceFromTick(tick).add(mutableConfig.spread).div(convertUd(100))); 
        }

        {
            // no lookback, adjust for spread, negative order size
            UD60x18 twapPrice = vamm.twap(0, -1, false, true);
            // Spread subtracts 0.3% from the price (as an absolute amount, not as a percentage of the price)
            assertEq(twapPrice, vamm.getPriceFromTick(tick).sub(mutableConfig.spread).div(convertUd(100)));
            console2.log(unwrap(twapPrice));
        }
    }

    function test_Init_Twap_WithPriceImpact() public {
        int24 tick = vamm.tick();
        assertEq(vamm.observe(0), tick); 

        {
            // no lookback, adjust for price impact of positive orderSize 100000000
            int256 orderSize = 100000000;
            UD60x18 twapPrice = vamm.twap(0, orderSize, true, false);

            // Price impact adds a multiple of 0.1*orderSize^0.125
            //                               = 0.1*100000000^0.125
            //                               = 0.1*10 = 1 to the price, i.e. doubles the price
            assertAlmostEqual(twapPrice, vamm.getPriceFromTick(tick).mul(ONE.add(ONE)).div(convertUd(100)));  
        }

        {
            // no lookback, adjust for price impact of negative orderSize 256
            int256 orderSize = -256;
            UD60x18 twapPrice = vamm.twap(0, orderSize, true, false);

            // Price impact subtracts a multiple of 0.1*abs(orderSize)^0.125
            //                               = 0.1*256^0.125
            //                               = 0.1*2 = 0.2 times the price, i.e. takes 20% off the price
            assertAlmostEqual(twapPrice, vamm.getPriceFromTick(tick).mul(ud60x18(8e17)).div(convertUd(100)));  
        }
    }

    /// @dev Useful check that we do not crash (e.g. due to underflow) while making adjustments to TWAP output
    function testFuzz_Init_Twap(int256 orderSize, bool adjustForPriceImpact,  bool adjustForSpread) public {
        vm.assume(orderSize != 0);
        orderSize = bound(orderSize, -int256(uMAX_UD60x18 / uUNIT), int256(uMAX_UD60x18 / uUNIT));

        int24 tick = vamm.tick();
        assertEq(vamm.observe(0), tick);
        UD60x18 instantPrice = vamm.getPriceFromTick(tick).div(convertUd(100));

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

    // function testFuzz_LiquidityPerTick(
    //     int24 tickLower,
    //     int24 tickUpper,
    //     int128 baseAmount)
    // public {
    //     (tickLower, tickUpper) = boundTicks(tickLower, tickUpper);
    //     assertEq(VAMMBase.liquidityPerTick(tickLower, tickUpper, baseAmount), baseAmount / (tickUpper - tickLower));
    // }

    function averagePriceBetweenTicksUsingLoop(
        int24 tickLower,
        int24 tickUpper)
    internal view returns (UD60x18)
    {
        UD60x18 sumOfPrices = vamm.getPriceFromTick(tickLower);
        for (int24 i = tickLower + 1; i <= tickUpper; i++) {
            sumOfPrices = sumOfPrices.add(vamm.getPriceFromTick(i));
        }
        return sumOfPrices.div(convert(uint256(int256(1 + tickUpper - tickLower))));
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
    //     assertEq(p.trackerQuoteTokenUpdatedGrowth, 0);
    //     assertEq(p.trackerBaseTokenUpdatedGrowth, 0);
    //     assertEq(p.trackerQuoteTokenAccumulated, 0);
    //     assertEq(p.trackerBaseTokenAccumulated, 0);
    //     //vamm.getRawPosition(positionId);
    // }

    function testFuzz_GetAccountFilledBalancesUnusedAccount(uint128 accountId) public {
        (int256 baseBalancePool, int256 quoteBalancePool) = vamm.getAccountFilledBalances(accountId);
        assertEq(baseBalancePool, 0);
        assertEq(quoteBalancePool, 0);
    }

    function testFuzz_GetAccountUnfilledBalancesUnusedAccount(uint128 accountId) public {
        (
            uint256 unfilledBaseLong,
            uint256 unfilledBaseShort,
            uint256 unfilledQuoteLong,
            uint256 unfilledQuoteShort
        ) = vamm.getAccountUnfilledBalances(accountId);
        assertEq(unfilledBaseLong, 0);
        assertEq(unfilledBaseShort, 0);
        assertEq(unfilledQuoteLong, 0);
        assertEq(unfilledQuoteShort, 0);
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
    //     (int256 unfilledBaseLong, int256 unfilledBaseShort) = vamm.getAccountUnfilledBalances(accountId);
    //     assertEq(unfilledBaseLong, 0);
    //     assertEq(unfilledBaseShort, 0);
    // }

    function test_GetAccountUnfilledBalances() public {
        uint128 accountId = 1;
        uint160 sqrtLowerPriceX96 = uint160(1 * FixedPoint96.Q96 / 10); // 0.1 => price ~= 0.01 = 1%
        uint160 sqrtUpperPriceX96 = uint160(22 * FixedPoint96.Q96 / 100); // 0.22 => price ~= 0.0484 = ~5%
        // console2.log("sqrtUpperPriceX96 = %s", sqrtUpperPriceX96); // TODO_delete_log
        // console2.log("maxSqrtRatio      = %s", uint256(2507794810551837817144115957740)); // TODO_delete_log

        int24 tickLower = TickMath.getTickAtSqrtRatio(sqrtLowerPriceX96);
        int24 tickUpper = TickMath.getTickAtSqrtRatio(sqrtUpperPriceX96);
        int128 baseAmount = 50_000_000_000;
        int128 liquidityDelta = getLiquidityForBase(tickLower, tickUpper, baseAmount);

        vamm.executeDatedMakerOrder(accountId, tickLower, tickUpper, liquidityDelta);

        // Position just opened so no filled balances
        (int256 baseBalancePool, int256 quoteBalancePool) = vamm.getAccountFilledBalances(accountId);
        assertEq(baseBalancePool, 0);
        assertEq(quoteBalancePool, 0);

        // We expect the full base amount is unfilled cos there have been no trades
        vm.mockCall(mockRateOracle, abi.encodeWithSelector(IRateOracle.getCurrentIndex.selector), abi.encode(ud60x18(1e18)));
        (uint256 unfilledBaseLong, uint256 unfilledBaseShort,,) = vamm.getAccountUnfilledBalances(accountId);
        // console2.log("unfilledBaseLong", unfilledBaseLong); // TODO_delete_log
        // console2.log("unfilledBaseShort", unfilledBaseShort); // TODO_delete_log
        uint256 distanceToLower = tickDistanceFromCurrentToTick(vamm, tickLower);
        uint256 distanceToUpper = tickDistanceFromCurrentToTick(vamm, tickUpper);
        // console2.log("distanceToLower", distanceToLower); // TODO_delete_log
        // console2.log("distanceToUpper", distanceToUpper); // TODO_delete_log

        if (distanceToLower > distanceToUpper) {
            assertGt(unfilledBaseShort, unfilledBaseLong, "short <= long");
        } else if (distanceToLower < distanceToUpper) {
            assertLt(unfilledBaseShort, unfilledBaseLong, "short >= long");
        } else {
            // Distances are equal
            assertEq(unfilledBaseShort, unfilledBaseLong, "short != long");
        }

        // Absolute value of long and shorts should add up to executed amount
        assertAlmostEqual((unfilledBaseLong + unfilledBaseShort).toInt(), baseAmount);

        // The current price is within the tick range, so we expect the liquidity to equal liquidityDelta
        assertEq(vamm.liquidity().toInt(), liquidityDelta);

        // We also expect liquidityGross to equal liquidityPerTick for both upper and lower ticks 
        assertEq(vamm.ticks(tickLower).liquidityGross.toInt(), liquidityDelta);
        assertEq(vamm.ticks(tickUpper).liquidityGross.toInt(), liquidityDelta);

        // When moving left to right (right to left), liquidityPerTick should be added (subtracted) at the lower tick and subtracted (added) at the upper tick 
        assertEq(vamm.ticks(tickLower).liquidityNet, liquidityDelta);
        assertEq(vamm.ticks(tickUpper).liquidityNet, -liquidityDelta);
    }

    // TODO: extend to 3 or more LPs and test TickInfo when multiple LPs start/end at same tick
    // function test_GetAccountUnfilledBalances_TwoLPs() public {
    //     DatedIrsVamm.Data storage vamm = DatedIrsVamm.load(vammId);
    //     int24 lp1tickLower;
    //     int24 lp1tickUpper;
    //     int128 lp1liquidity;

    //     // First LP
    //     {
    //         uint128 accountId = 1;
    //         uint160 sqrtLowerPriceX96 = uint160(1 * FixedPoint96.Q96 / 10); // 0.1 => price = 0.01 = 1%
    //         uint160 sqrtUpperPriceX96 = uint160(22 * FixedPoint96.Q96 / 100); // 0.22 => price = 0.0484 = 4.84%
    //         // console2.log("sqrtUpperPriceX96 = %s", sqrtUpperPriceX96); // TODO_delete_log
    //         // console2.log("maxSqrtRatio      = %s", uint256(2507794810551837817144115957740)); // TODO_delete_log

    //         int24 tickLower = TickMath.getTickAtSqrtRatio(sqrtLowerPriceX96);
    //         int24 tickUpper = TickMath.getTickAtSqrtRatio(sqrtUpperPriceX96);
    //         int128 baseAmount = 50_000_000_000;
    //         int128 liquidityDelta = getLiquidityForBase(tickLower, tickUpper, baseAmount);
    //         vamm.executeDatedMakerOrder(accountId,tickLower,tickUpper, liquidityDelta);

    //         // Position just opened so no filled balances
    //         (int256 baseBalancePool, int256 quoteBalancePool) = vamm.getAccountFilledBalances(accountId);
    //         assertEq(baseBalancePool, 0);
    //         assertEq(quoteBalancePool, 0);

    //         // We expect the full base amount is unfilled cos there have been no trades
    //         (uint256 unfilledBaseLong, uint256 unfilledBaseShort) = vamm.getAccountUnfilledBalances(accountId);
    //         // console2.log("unfilledBaseLong", unfilledBaseLong); // TODO_delete_log
    //         // console2.log("unfilledBaseShort", unfilledBaseShort); // TODO_delete_log
    //         uint256 distanceToLower = tickDistanceFromCurrentToTick(tickLower);
    //         uint256 distanceToUpper = tickDistanceFromCurrentToTick(tickUpper);
    //         // console2.log("distanceToLower", distanceToLower); // TODO_delete_log
    //         // console2.log("distanceToUpper", distanceToUpper); // TODO_delete_log

    //         if (distanceToLower > distanceToUpper) {
    //             assertGt(unfilledBaseShort, unfilledBaseLong, "short <= long");
    //         } else if (distanceToLower < distanceToUpper) {
    //             assertLt(unfilledBaseShort, unfilledBaseLong, "short >= long");
    //         } else {
    //             // Distances are equal
    //             assertEq(unfilledBaseShort, unfilledBaseLong, "short != long");
    //         }

    //         // Absolute value of long and shorts should add up to executed amount
    //         assertAlmostEqual((unfilledBaseLong + unfilledBaseShort).toInt(), baseAmount);

    //         // The current price is within the tick range, so we expect the liquidity to equal liquidityDelta
    //         assertEq(vamm.vars.liquidity.toInt(), liquidityDelta);

    //         // We also expect liquidityGross to equal liquidityDelta for both upper and lower ticks 
    //         assertEq(vamm.vars._ticks[tickLower].liquidityGross.toInt(), liquidityDelta);
    //         assertEq(vamm.vars._ticks[tickUpper].liquidityGross.toInt(), liquidityDelta);

    //         // When moving left to right (right to left), liquidityDelta should be added (subtracted) at the lower tick and subtracted (added) at the upper tick 
    //         assertEq(vamm.vars._ticks[tickLower].liquidityNet, liquidityDelta);
    //         assertEq(vamm.vars._ticks[tickUpper].liquidityNet, -liquidityDelta);

    //         // Save some values for additional testing after extra LPs
    //         lp1tickLower = tickLower;
    //         lp1tickUpper = tickUpper;
    //         lp1liquidity = liquidityDelta;
    //     }

    //     // Second LP
    //     {
    //         uint128 accountId = 2;
    //         uint160 sqrtLowerPriceX96 = uint160(15 * FixedPoint96.Q96 / 100); // 0.15 => price = 0.0225 = 2.25%
    //         uint160 sqrtUpperPriceX96 = uint160(25 * FixedPoint96.Q96 / 100); // 0.25 => price = 0.0625 = 6.25%
    //         // console2.log("sqrtUpperPriceX96 = %s", sqrtUpperPriceX96); // TODO_delete_log
    //         // console2.log("maxSqrtRatio      = %s", uint256(2507794810551837817144115957740)); // TODO_delete_log

    //         int24 tickLower = TickMath.getTickAtSqrtRatio(sqrtLowerPriceX96);
    //         int24 tickUpper = TickMath.getTickAtSqrtRatio(sqrtUpperPriceX96);
    //         int128 baseAmount = 50_000_000_000;
    //         int128 liquidityDelta = getLiquidityForBase(tickLower, tickUpper, baseAmount);
    //         vamm.executeDatedMakerOrder(accountId,tickLower,tickUpper, liquidityDelta);

    //         // Position just opened so no filled balances
    //         (int256 baseBalancePool, int256 quoteBalancePool) = vamm.getAccountFilledBalances(accountId);
    //         assertEq(baseBalancePool, 0);
    //         assertEq(quoteBalancePool, 0);

    //         // We expect the full base amount is unfilled cos there have been no trades
    //         (uint256 unfilledBaseLong, uint256 unfilledBaseShort) = vamm.getAccountUnfilledBalances(accountId);
    //         // console2.log("unfilledBaseLong", unfilledBaseLong); // TODO_delete_log
    //         // console2.log("unfilledBaseShort", unfilledBaseShort); // TODO_delete_log
    //         uint256 distanceToLower = tickDistanceFromCurrentToTick(tickLower);
    //         uint256 distanceToUpper = tickDistanceFromCurrentToTick(tickUpper);
    //         // console2.log("distanceToLower", distanceToLower); // TODO_delete_log
    //         // console2.log("distanceToUpper", distanceToUpper); // TODO_delete_log

    //         if (distanceToLower > distanceToUpper) {
    //             assertGt(unfilledBaseShort, unfilledBaseLong, "short <= long");
    //         } else if (distanceToLower < distanceToUpper) {
    //             assertLt(unfilledBaseShort, unfilledBaseLong, "short >= long");
    //         } else {
    //             // Distances are equal
    //             assertEq(unfilledBaseShort, unfilledBaseLong, "short != long");
    //         }

    //         // Absolute value of long and shorts should add up to executed amount
    //         assertAlmostEqual((unfilledBaseLong + unfilledBaseShort).toInt(), baseAmount);

    //         // The current price is within both tick ranges, so we expect the liquidity to equal the sum of two liquidityDelta values
    //         assertEq(vamm.vars.liquidity.toInt(), liquidityDelta + lp1liquidity);

    //         // We expect liquidityGross to equal liquidityDelta for both upper and lower ticks 
    //         assertEq(vamm.vars._ticks[tickLower].liquidityGross.toInt(), liquidityDelta);
    //         assertEq(vamm.vars._ticks[tickUpper].liquidityGross.toInt(), liquidityDelta);

    //         // When moving left to right (right to left), liquidityDelta should be added (subtracted) at the lower tick and subtracted (added) at the upper tick 
    //         assertEq(vamm.vars._ticks[tickLower].liquidityNet, liquidityDelta);
    //         assertEq(vamm.vars._ticks[tickUpper].liquidityNet, -liquidityDelta);
    //     }
    // }

    function testFuzz_GetAccountUnfilledTokens_QuoteLong(
        uint128 accountId,
        int24 tickLower,
        int24 tickUpper,
        int128 liquidityDelta
    ) public {
        vm.assume(accountId != 0);
        vm.assume(liquidityDelta != 0);
        (tickLower, tickUpper) = boundTicks(tickLower, tickUpper);
        liquidityDelta = boundNewPositionLiquidityAmount(vamm, tickLower, tickUpper, liquidityDelta);

        vamm.executeDatedMakerOrder(accountId,tickLower,tickUpper, liquidityDelta);

        // Position just opened so no filled balances
        (int256 baseBalancePool, int256 quoteBalancePool) = vamm.getAccountFilledBalances(accountId);
        assertEq(baseBalancePool, 0);
        assertEq(quoteBalancePool, 0);
    
        // We expect the full base amount is unfilled cos there have been no trades
        vm.mockCall(mockRateOracle, abi.encodeWithSelector(IRateOracle.getCurrentIndex.selector), abi.encode(ud60x18(1e18)));
        (
            uint256 unfilledBaseLong,
            uint256 unfilledBaseShort,
            uint256 unfilledQuoteLong,
        ) = vamm.getAccountUnfilledBalances(accountId);
        if (tickDistanceFromCurrentToTick(vamm, tickLower) > 0) {
            assertGe(unfilledBaseShort, 0, "short unexpectedlly zero");
        }
        if (tickDistanceFromCurrentToTick(vamm, tickUpper) > 0) {
            assertGe(unfilledBaseLong, 0, "long unexpectedlly zero");
        }

        assertOffByNoMoreThan2OrAlmostEqual((unfilledBaseLong + unfilledBaseShort).toInt(), vamm.baseBetweenTicks(tickLower, tickUpper, liquidityDelta));

        (int256 quoteTokenDelta2,) = _swapMaxRight(-vamm.baseBetweenTicks(tickLower, tickUpper, liquidityDelta) - 1e18);
        assertAlmostEqual(
            (unfilledQuoteLong).toInt(), 
            quoteTokenDelta2,
            1e16 // 1% diff -> cause by adding spread to price at each step of the swap vs on avg price for unfilled
        );
    }

    function testFuzz_GetAccountUnfilledTokens_QuoteShort(
        uint128 accountId,
        int24 tickLower,
        int24 tickUpper,
        int128 liquidityDelta
    ) public {
        vm.assume(accountId != 0);
        vm.assume(liquidityDelta != 0);
        (tickLower, tickUpper) = boundTicks(tickLower, tickUpper);
        liquidityDelta = boundNewPositionLiquidityAmount(vamm, tickLower, tickUpper, liquidityDelta);

        vamm.executeDatedMakerOrder(accountId,tickLower,tickUpper, liquidityDelta);

        // Position just opened so no filled balances
        (int256 baseBalancePool, int256 quoteBalancePool) = vamm.getAccountFilledBalances(accountId);
        assertEq(baseBalancePool, 0);
        assertEq(quoteBalancePool, 0);
    
        // We expect the full base amount is unfilled cos there have been no trades
        vm.mockCall(mockRateOracle, abi.encodeWithSelector(IRateOracle.getCurrentIndex.selector), abi.encode(ud60x18(1e18)));
        (
            uint256 unfilledBaseLong,
            uint256 unfilledBaseShort,,
            uint256 unfilledQuoteShort
        ) = vamm.getAccountUnfilledBalances(accountId);
        if (tickDistanceFromCurrentToTick(vamm, tickLower) > 0) {
            assertGe(unfilledBaseShort, 0, "short unexpectedlly zero");
        }
        if (tickDistanceFromCurrentToTick(vamm, tickUpper) > 0) {
            assertGe(unfilledBaseLong, 0, "long unexpectedlly zero");
        }

        assertOffByNoMoreThan2OrAlmostEqual((unfilledBaseLong + unfilledBaseShort).toInt(), vamm.baseBetweenTicks(tickLower, tickUpper, liquidityDelta));

        (int256 quoteTokenDelta1,) = _swapMaxLeft(vamm.baseBetweenTicks(tickLower, tickUpper, liquidityDelta) + 1e18);
        assertAlmostEqual(
            -(unfilledQuoteShort).toInt(),
            quoteTokenDelta1,
            1e16 // 1% difference
        );
        
    }

    function _swapMaxRight(int256 baseAmount) public returns (int256 quoteTokenDelta, int256 baseTokenDelta) {
        if(baseAmount == 0) return (0,0);

        DatedIrsVamm.SwapParams memory params = DatedIrsVamm.SwapParams({
            amountSpecified: -baseAmount, // There is not enough liquidity - swap should max out at baseTradeableToRight
            sqrtPriceLimitX96: TickMath.getSqrtRatioAtTick(MAX_TICK - 1)
        });

        // Mock the liquidity index that is read during a swap
        vm.mockCall(mockRateOracle, abi.encodeWithSelector(IRateOracle.getCurrentIndex.selector), abi.encode(1e18));
        (quoteTokenDelta, baseTokenDelta) = vamm.vammSwap(params);
    }

    function _swapMaxLeft(int256 baseAmount) public returns (int256 quoteTokenDelta, int256 baseTokenDelta) {
        if(baseAmount == 0) return (0,0);
        DatedIrsVamm.SwapParams memory params = DatedIrsVamm.SwapParams({
            amountSpecified: -baseAmount, // There is not enough liquidity - swap should max out at baseTradeableToRight
            sqrtPriceLimitX96: TickMath.getSqrtRatioAtTick(MIN_TICK + 1)
        });

        // Mock the liquidity index that is read during a swap
        vm.mockCall(mockRateOracle, abi.encodeWithSelector(IRateOracle.getCurrentIndex.selector), abi.encode(1e18));
        (quoteTokenDelta, baseTokenDelta) = vamm.vammSwap(params);
    }
}