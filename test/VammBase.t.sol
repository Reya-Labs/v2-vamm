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
contract VammBaseTest is DatedIrsVammTestUtil {
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

    function testFuzz_BaseBetweenTicks(
        int24 tickLower,
        int24 tickUpper,
        int128 liquidity)
    public {
        (tickLower, tickUpper) = boundTicks(tickLower, tickUpper);
        // Check that baseBetweenTicks and getLiquidityForBase are symetric
        liquidity = boundNewPositionLiquidityAmount(type(uint128).max, tickLower, tickUpper, liquidity);
        int256 baseAmount = VAMMBase.baseBetweenTicks(tickLower, tickUpper, liquidity);
        assertOffByNoMoreThan2OrAlmostEqual(getLiquidityForBase(tickLower, tickUpper, baseAmount), liquidity); // TODO: can we do better than off-by-two for small values? is it important?
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

    // TODO: move to separate VAMMBase test file (with others)
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

    // TODO: move to separate VAMMBase test file (with others)
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

    function test_FixedTokensInHomogeneousTickWindow() public {
      int256 baseAmount = 5e10;
      int24 tickLower = -1;
      int24 tickUpper = 1;
      uint256 mockLiquidityIndex = 2;
 
      UD60x18 currentLiquidityIndex = convert(mockLiquidityIndex);

      (int256 trackedValue) = VAMMBase._fixedTokensInHomogeneousTickWindow(baseAmount, tickLower, tickUpper, convert(uint256(1)), currentLiquidityIndex);

      UD60x18 expectedAveragePrice = averagePriceBetweenTicksUsingLoop(tickLower, tickUpper);
      assertAlmostEqual(VAMMBase.averagePriceBetweenTicks(tickLower, tickUpper), ONE);
      assertAlmostEqual(VAMMBase.averagePriceBetweenTicks(tickLower, tickUpper), expectedAveragePrice);

      // We expect -baseTokens * liquidityIndex[current] * (1 + fixedRate[ofSpecifiedTicks] * timeInYearsTillMaturity)
      //         = -5e10       * mockLiquidityIndex      * (1 + expectedAveragePrice        * 1)         
      //         = -5e10       * mockLiquidityIndex      * (1 + ~1)         
      //         = ~-20e10
      assertAlmostEqual(trackedValue, baseAmount * -2 * int256(mockLiquidityIndex));
    }

    // TODO: move to separate VAMMBase test file (with others)
    function testFuzz_FixedTokensInHomogeneousTickWindow_VaryTicks(int24 tickLower, int24 tickUpper) public {
      (tickLower, tickUpper) = boundTicks(tickLower, tickUpper);
      int256 baseAmount = -9e30;
      uint256 mockLiquidityIndex = 1;
      UD60x18 currentLiquidityIndex = convert(mockLiquidityIndex);

      (int256 trackedValue) = VAMMBase._fixedTokensInHomogeneousTickWindow(baseAmount, tickLower, tickUpper, convert(uint256(1)), currentLiquidityIndex);

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

    // TODO: move to separate VAMMBase test file (with others)
    function testFuzz_FixedTokensInHomogeneousTickWindow_VaryTerm(uint256 secondsToMaturity) public {
      int256 baseAmount = -123e20;
      int24 tickLower = -1;
      int24 tickUpper = 1;
      uint256 mockLiquidityIndex = 8;
      uint256 SECONDS_IN_YEAR = convert(FixedAndVariableMath.SECONDS_IN_YEAR);

      // Bound term between 0 and one hundred years
      secondsToMaturity = bound(secondsToMaturity,  0, SECONDS_IN_YEAR * 100);
      UD60x18 timeInYearsTillMaturity = convert(secondsToMaturity).div(FixedAndVariableMath.SECONDS_IN_YEAR);
 
      UD60x18 currentLiquidityIndex = convert(mockLiquidityIndex);

      (int256 trackedValue) = VAMMBase._fixedTokensInHomogeneousTickWindow(baseAmount, tickLower, tickUpper, timeInYearsTillMaturity, currentLiquidityIndex);
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
}