pragma solidity >=0.8.13;

import "forge-std/Test.sol";
 import "forge-std/console2.sol";
 import "./DatedIrsVammTestUtil.sol";
 import "../src/storage/LPPosition.sol";
import "../src/storage/DatedIrsVAMM.sol";
import "../utils/CustomErrors.sol";
import "../src/storage/LPPosition.sol";
import { mulUDxInt } from "@voltz-protocol/util-contracts/src/helpers/PrbMathHelper.sol";
import { UD60x18, convert, ud60x18, uMAX_UD60x18, uUNIT } from "@prb/math/UD60x18.sol";
import { SD59x18, sd59x18, convert } from "@prb/math/SD59x18.sol";
import "@voltz-protocol/util-contracts/src/helpers/SafeCast.sol";

// Constants
UD60x18 constant ONE = UD60x18.wrap(1e18);

// TODO: Break up this growing test contract into more multiple separate tests for increased readability
contract VammTest_FreshVamm is DatedIrsVammTestUtil {
    using DatedIrsVamm for DatedIrsVamm.Data;
    using SafeCastU256 for uint256;
    using SafeCastU128 for uint128;
    using SafeCastI256 for int256;

    ExposedDatedIrsVamm vamm;

    function setUp() public {
        vammId = uint256(keccak256(abi.encodePacked(initMarketId, initMaturityTimestamp)));
        vamm = new ExposedDatedIrsVamm(vammId);
        vamm.create(initMarketId, initSqrtPriceX96, immutableConfig, mutableConfig);
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
        vamm.initialize(initSqrtPriceX96);
    }

    function test_Init_Twap_Unadjusted() public {
        int24 tick = vamm.tick();
        assertEq(vamm.observe(0), tick); 

        // no lookback, no adjustments
        UD60x18 geometricMeanPrice = vamm.twap(0, 0, false, false);
        assertEq(geometricMeanPrice, VAMMBase.getPriceFromTick(tick)); 
        assertAlmostEqual(geometricMeanPrice, ud60x18(4e16)); // Approx 0.04. Not exact cos snaps to tick boundary.
    }

    function test_Init_Twap_WithSpread() public {
        int24 tick = vamm.tick();
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
        int24 tick = vamm.tick();
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

        int24 tick = vamm.tick();
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
    internal pure returns (UD60x18)
    {
        UD60x18 sumOfPrices = VAMMBase.getPriceFromTick(tickLower);
        for (int24 i = tickLower + 1; i <= tickUpper; i++) {
            sumOfPrices = sumOfPrices.add(VAMMBase.getPriceFromTick(i));
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
    //     assertEq(p.trackerFixedTokenUpdatedGrowth, 0);
    //     assertEq(p.trackerBaseTokenUpdatedGrowth, 0);
    //     assertEq(p.trackerFixedTokenAccumulated, 0);
    //     assertEq(p.trackerBaseTokenAccumulated, 0);
    //     //vamm.getRawPosition(positionId);
    // }

    function testFuzz_GetAccountFilledBalancesUnusedAccount(uint128 accountId) public {
        (int256 baseBalancePool, int256 quoteBalancePool) = vamm.getAccountFilledBalances(accountId);
        assertEq(baseBalancePool, 0);
        assertEq(quoteBalancePool, 0);
    }

    function testFuzz_GetAccountUnfilledBasesUnusedAccount(uint128 accountId) public {
        (uint256 unfilledBaseLong, uint256 unfilledBaseShort) = vamm.getAccountUnfilledBases(accountId);
        assertEq(unfilledBaseLong, 0);
        assertEq(unfilledBaseShort, 0);
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
        (uint256 unfilledBaseLong, uint256 unfilledBaseShort) = vamm.getAccountUnfilledBases(accountId);
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
    // function test_GetAccountUnfilledBases_TwoLPs() public {
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
    //         (uint256 unfilledBaseLong, uint256 unfilledBaseShort) = vamm.getAccountUnfilledBases(accountId);
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
    //         (uint256 unfilledBaseLong, uint256 unfilledBaseShort) = vamm.getAccountUnfilledBases(accountId);
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

    function testFuzz_GetAccountUnfilledBases(
        uint128 accountId,
        int24 tickLower,
        int24 tickUpper,
        int128 liquidityDelta
    ) public {
        vm.assume(accountId != 0);
        (tickLower, tickUpper) = boundTicks(tickLower, tickUpper);
        liquidityDelta = boundNewPositionLiquidityAmount(vamm, tickLower, tickUpper, liquidityDelta);

        vamm.executeDatedMakerOrder(accountId,tickLower,tickUpper, liquidityDelta);

        // Position just opened so no filled balances
        (int256 baseBalancePool, int256 quoteBalancePool) = vamm.getAccountFilledBalances(accountId);
        assertEq(baseBalancePool, 0);
        assertEq(quoteBalancePool, 0);
    
        // We expect the full base amount is unfilled cos there have been no trades
        (uint256 unfilledBaseLong, uint256 unfilledBaseShort) = vamm.getAccountUnfilledBases(accountId);
        uint256 distanceToLower = tickDistanceFromCurrentToTick(vamm, tickLower);
        uint256 distanceToUpper = tickDistanceFromCurrentToTick(vamm, tickUpper);
        if (distanceToLower > 0) {
            assertGe(unfilledBaseShort, 0, "short unexpectedlly zero");
        }
        if (distanceToUpper > 0) {
            assertGe(unfilledBaseLong, 0, "long unexpectedlly zero");
        }

        int256 baseAmount = VAMMBase.baseBetweenTicks(tickLower, tickUpper, liquidityDelta);
        assertOffByNoMoreThan2OrAlmostEqual((unfilledBaseLong + unfilledBaseShort).toInt(), baseAmount);
    }
}