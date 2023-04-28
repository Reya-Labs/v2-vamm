pragma solidity >=0.8.13;

import "forge-std/Test.sol";
import "forge-std/console2.sol";
import "./DatedIrsVammTest.sol";
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
contract VammTest_WithLiquidity is DatedIrsVammTest {
    using DatedIrsVamm for DatedIrsVamm.Data;
    using SafeCastU256 for uint256;
    using SafeCastU128 for uint128;

    int128 constant BASE_AMOUNT_PER_LP = 50_000_000_000;
    uint128 constant ACCOUNT_1 = 1;
    uint160 constant ACCOUNT_1_LOWER_SQRTPRICEX96 = uint160(1 * FixedPoint96.Q96 / 10); // 0.1 => price = 0.01 = 1%
    uint160 constant ACCOUNT_1_UPPER_SQRTPRICEX96 = uint160(22 * FixedPoint96.Q96 / 100); // 0.22 => price = 0.0484 = 4.84%
    uint128 constant ACCOUNT_2 = 2;
    uint160 constant ACCOUNT_2_LOWER_SQRTPRICEX96 = uint160(15 * FixedPoint96.Q96 / 100); // 0.15 => price = 0.0225 = 2.25%
    uint160 constant ACCOUNT_2_UPPER_SQRTPRICEX96 = uint160(25 * FixedPoint96.Q96 / 100); // 0.25 => price = 0.062
    int24 ACCOUNT_1_TICK_LOWER = TickMath.getTickAtSqrtRatio(ACCOUNT_1_LOWER_SQRTPRICEX96);
    int24 ACCOUNT_1_TICK_UPPER = TickMath.getTickAtSqrtRatio(ACCOUNT_1_UPPER_SQRTPRICEX96);
    int24 ACCOUNT_2_TICK_LOWER = TickMath.getTickAtSqrtRatio(ACCOUNT_2_LOWER_SQRTPRICEX96);
    int24 ACCOUNT_2_TICK_UPPER = TickMath.getTickAtSqrtRatio(ACCOUNT_2_UPPER_SQRTPRICEX96);
    uint256 _mockLiquidityIndex = 2;
    UD60x18 mockLiquidityIndex = convert(_mockLiquidityIndex);
    int256 baseTradeableToLeft;
    int256 baseTradeableToRight;

    function setUp() public {
        DatedIrsVamm.create(initMarketId, initSqrtPriceX96, immutableConfig, mutableConfig);

        vammId = uint256(keccak256(abi.encodePacked(initMarketId, initMaturityTimestamp)));
        DatedIrsVamm.Data storage vamm = DatedIrsVamm.load(vammId);

        // console2.log("requestedBaseAmount (per LP)  ", BASE_AMOUNT_PER_LP);

        {
            // LP 1
            int128 requestedLiquidityAmount = getLiquidityForBase(ACCOUNT_1_TICK_LOWER, ACCOUNT_1_TICK_UPPER, BASE_AMOUNT_PER_LP);
            vamm.executeDatedMakerOrder(ACCOUNT_1,ACCOUNT_1_LOWER_SQRTPRICEX96,ACCOUNT_1_UPPER_SQRTPRICEX96, requestedLiquidityAmount);
        }
        {
            // LP 2
            int128 requestedLiquidityAmount = getLiquidityForBase(ACCOUNT_2_TICK_LOWER, ACCOUNT_2_TICK_UPPER, BASE_AMOUNT_PER_LP);

            vamm.executeDatedMakerOrder(ACCOUNT_2,ACCOUNT_2_LOWER_SQRTPRICEX96,ACCOUNT_2_UPPER_SQRTPRICEX96, requestedLiquidityAmount);
        }

        // We know that the current price is within the range of both LPs, so to calculate base tokens available to trade to the left we add:
        //    liquidity * distance_from_current_price_to_LP2_lower_tick
        // AND
        //    LP1_liquidity_value * distance_from_LP1_lower_tick_to_LP2_lower_tick
        baseTradeableToLeft += VAMMBase.baseBetweenTicks(ACCOUNT_2_TICK_LOWER, vamm.vars.tick, vamm.vars.liquidity.toInt());
        baseTradeableToLeft += VAMMBase.baseBetweenTicks(ACCOUNT_1_TICK_LOWER, ACCOUNT_2_TICK_LOWER, vamm.vars._ticks[ACCOUNT_1_TICK_LOWER].liquidityNet);
        // console2.log("baseTradeableToLeft  ", baseTradeableToLeft);

        // We know that the current price is within the range of both LPs, so to calculate base tokens available to trade to the right we add:
        //    liquidity * distance_from_current_price_to_LP1_upper_tick
        // AND
        //    LP2_per-tick_value * distance_from_LP1_lower_tick_to_LP2_lower_tick
        baseTradeableToRight += VAMMBase.baseBetweenTicks(vamm.vars.tick, ACCOUNT_1_TICK_UPPER, vamm.vars.liquidity.toInt());
        baseTradeableToRight += VAMMBase.baseBetweenTicks(ACCOUNT_1_TICK_UPPER, ACCOUNT_2_TICK_UPPER, -vamm.vars._ticks[ACCOUNT_2_TICK_UPPER].liquidityNet);
        // console2.log("baseTradeableToRight ", baseTradeableToRight);
    }

    function test_TradeableBaseTokens() public {
        assertAlmostEqual(BASE_AMOUNT_PER_LP * 2, baseTradeableToLeft + baseTradeableToRight);
    }

    function test_GetAccountUnfilledBases() public {
        DatedIrsVamm.Data storage vamm = DatedIrsVamm.load(vammId);

        // Positions just opened so no filled balances
        {
            // LP 1
            (int256 baseBalancePool, int256 quoteBalancePool) = vamm.getAccountFilledBalances(ACCOUNT_1);
            assertEq(baseBalancePool, 0);
            assertEq(quoteBalancePool, 0);
        }
        {
            // LP 2
            (int256 baseBalancePool, int256 quoteBalancePool) = vamm.getAccountFilledBalances(ACCOUNT_2);
            assertEq(baseBalancePool, 0);
            assertEq(quoteBalancePool, 0);
        }
    }

    function test_Swap_MovingRight() public {
        DatedIrsVamm.Data storage vamm = DatedIrsVamm.load(vammId);
        int256 baseAmount =  500_000_000;

        VAMMBase.SwapParams memory params = VAMMBase.SwapParams({
            recipient: address(this),
            baseAmountSpecified: baseAmount,
            sqrtPriceLimitX96: ACCOUNT_2_UPPER_SQRTPRICEX96
        });

        // Mock the liquidity index that is read during a swap
        vm.mockCall(mockRateOracle, abi.encodeWithSelector(IRateOracle.getCurrentIndex.selector), abi.encode(mockLiquidityIndex));
        (int256 trackerFixedTokenDelta, int256 trackerBaseTokenDelta) = vamm.vammSwap(params);

        assertAlmostEqual(trackerBaseTokenDelta, -baseAmount);
        // TODO: verify that VAMM state and trackerFixedTokenDelta is as expected
    }

    function test_Swap_MovingLeft() public {
        DatedIrsVamm.Data storage vamm = DatedIrsVamm.load(vammId);
        int256 baseAmount =  -500_000_000;

        VAMMBase.SwapParams memory params = VAMMBase.SwapParams({
            recipient: address(this),
            baseAmountSpecified: baseAmount,
            sqrtPriceLimitX96: TickMath.getSqrtRatioAtTick(TickMath.MIN_TICK + 1)
        });

        // Mock the liquidity index that is read during a swap
        vm.mockCall(mockRateOracle, abi.encodeWithSelector(IRateOracle.getCurrentIndex.selector), abi.encode(mockLiquidityIndex));
        (int256 trackerFixedTokenDelta, int256 trackerBaseTokenDelta) = vamm.vammSwap(params);

        assertAlmostEqual(trackerBaseTokenDelta, -baseAmount);
        // TODO: verify that VAMM state and trackerFixedTokenDelta is as expected
    }

    function test_Swap_MovingMaxRight() public {
        DatedIrsVamm.Data storage vamm = DatedIrsVamm.load(vammId);

        int24 tickLimit = ACCOUNT_2_TICK_UPPER + 1;

        VAMMBase.SwapParams memory params = VAMMBase.SwapParams({
            recipient: address(this),
            baseAmountSpecified: 500_000_000_000_000_000_000_000_000_000_000, // There is not enough liquidity - swap should max out at baseTradeableToRight
            sqrtPriceLimitX96: TickMath.getSqrtRatioAtTick(tickLimit)
        });

        // Mock the liquidity index that is read during a swap
        vm.mockCall(mockRateOracle, abi.encodeWithSelector(IRateOracle.getCurrentIndex.selector), abi.encode(mockLiquidityIndex));
        (int256 trackerFixedTokenDelta, int256 trackerBaseTokenDelta) = vamm.vammSwap(params);

        assertAlmostEqual(trackerBaseTokenDelta, -baseTradeableToRight);
        assertEq(vamm.vars.tick, tickLimit);
        assertEq(vamm.vars.sqrtPriceX96, TickMath.getSqrtRatioAtTick(tickLimit));
        // TODO: verify that trackerFixedTokenDelta is as expected
    }

    function test_Swap_MovingMaxLeft() public {
        DatedIrsVamm.Data storage vamm = DatedIrsVamm.load(vammId);

        int24 tickLimit = TickMath.MIN_TICK + 1;

        VAMMBase.SwapParams memory params = VAMMBase.SwapParams({
            recipient: address(this),
            baseAmountSpecified: -500_000_000_000_000_000_000_000_000_000_000, // There is not enough liquidity - swap should max out at baseTradeableToLeft
            sqrtPriceLimitX96: TickMath.getSqrtRatioAtTick(tickLimit)
        });

        // Mock the liquidity index that is read during a swap
        vm.mockCall(mockRateOracle, abi.encodeWithSelector(IRateOracle.getCurrentIndex.selector), abi.encode(mockLiquidityIndex));

        (int256 trackerFixedTokenDelta, int256 trackerBaseTokenDelta) = vamm.vammSwap(params);

        assertAlmostEqual(trackerBaseTokenDelta, baseTradeableToLeft);
        assertEq(vamm.vars.tick, tickLimit);
        assertEq(vamm.vars.sqrtPriceX96, TickMath.getSqrtRatioAtTick(tickLimit));
        // TODO: verify that trackerFixedTokenDelta is as expected
    }

    // TODO: fully and partially unwind swaps

    // TODO: verify that LPs can withdraw some or all of their liquidity

    // TODO: verify that LPs cannot withdraw more liquidity than they have

    // TODO: Verify that LPs depositing from/to already-used tick boundaries affects the tick state in expected way
}