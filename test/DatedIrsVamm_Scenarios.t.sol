pragma solidity >=0.8.13;

import "forge-std/Test.sol";
import "forge-std/console2.sol";
import "./DatedIrsVammTestUtil.sol";
import "../src/storage/LPPosition.sol";
import "../src/storage/DatedIrsVAMM.sol";
import "../utils/CustomErrors.sol";
import "../src/storage/LPPosition.sol";
import { mulUDxInt } from "@voltz-protocol/util-contracts/src/helpers/PrbMathHelper.sol";
import { UD60x18, convert, unwrap, ud60x18, uMAX_UD60x18, uUNIT } from "@prb/math/UD60x18.sol";
import { SD59x18, sd59x18, convert } from "@prb/math/SD59x18.sol";
import "@voltz-protocol/util-contracts/src/helpers/SafeCast.sol";

// Constants
UD60x18 constant ONE = UD60x18.wrap(1e18);

contract DatedIrsVammTest is DatedIrsVammTestUtil {
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
    ExposedDatedIrsVamm vamm;

    function setUp() public {

        vammId = uint256(keccak256(abi.encodePacked(initMarketId, initMaturityTimestamp)));
        vamm = new ExposedDatedIrsVamm(vammId);
        vamm.create(initMarketId, initSqrtPriceX96, immutableConfig, mutableConfig);

        // console2.log("requestedBaseAmount (per LP)  ", BASE_AMOUNT_PER_LP);

        {
            // LP 1
            int128 requestedLiquidityAmount = getLiquidityForBase(ACCOUNT_1_TICK_LOWER, ACCOUNT_1_TICK_UPPER, BASE_AMOUNT_PER_LP);
            vamm.executeDatedMakerOrder(ACCOUNT_1,ACCOUNT_1_TICK_LOWER,ACCOUNT_1_TICK_UPPER, requestedLiquidityAmount);
        }
        {
            // LP 2
            int128 requestedLiquidityAmount = getLiquidityForBase(ACCOUNT_2_TICK_LOWER, ACCOUNT_2_TICK_UPPER, BASE_AMOUNT_PER_LP);

            vamm.executeDatedMakerOrder(ACCOUNT_2,ACCOUNT_2_TICK_LOWER,ACCOUNT_2_TICK_UPPER, requestedLiquidityAmount);
        }

        // We know that the current price is within the range of both LPs, so to calculate base tokens available to trade to the left we add:
        //    liquidity * distance_from_current_price_to_LP2_lower_tick
        // AND
        //    LP1_liquidity_value * distance_from_LP1_lower_tick_to_LP2_lower_tick
        baseTradeableToLeft += VAMMBase.baseBetweenTicks(ACCOUNT_2_TICK_LOWER, vamm.tick(), vamm.liquidity().toInt());
        baseTradeableToLeft += VAMMBase.baseBetweenTicks(ACCOUNT_1_TICK_LOWER, ACCOUNT_2_TICK_LOWER, vamm.ticks( ACCOUNT_1_TICK_LOWER).liquidityNet);
        // console2.log("baseTradeableToLeft  ", baseTradeableToLeft);

        // We know that the current price is within the range of both LPs, so to calculate base tokens available to trade to the right we add:
        //    liquidity * distance_from_current_price_to_LP1_upper_tick
        // AND
        //    LP2_per-tick_value * distance_from_LP1_lower_tick_to_LP2_lower_tick
        baseTradeableToRight += VAMMBase.baseBetweenTicks(vamm.tick(), ACCOUNT_1_TICK_UPPER, vamm.liquidity().toInt());
        baseTradeableToRight += VAMMBase.baseBetweenTicks(ACCOUNT_1_TICK_UPPER, ACCOUNT_2_TICK_UPPER, -vamm.ticks(ACCOUNT_2_TICK_UPPER).liquidityNet);
        // console2.log("baseTradeableToRight ", baseTradeableToRight);
    }

    function test_TradeableBaseTokens() public {
        assertAlmostEqual(BASE_AMOUNT_PER_LP * 2, baseTradeableToLeft + baseTradeableToRight);
    }

    function test_CorrectCreation() public {
        assertEq(vamm.tick(), TickMath.getTickAtSqrtRatio(initSqrtPriceX96));
    }

    function test_GetAccountUnfilledBases() public {
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
        int256 amountSpecified =  500_000_000;

        VAMMBase.SwapParams memory params = VAMMBase.SwapParams({
            amountSpecified: amountSpecified,
            sqrtPriceLimitX96: ACCOUNT_2_UPPER_SQRTPRICEX96
        });

        // Mock the liquidity index that is read during a swap
        vm.mockCall(mockRateOracle, abi.encodeWithSelector(IRateOracle.getCurrentIndex.selector), abi.encode(mockLiquidityIndex));
        (int256 trackerFixedTokenDelta, int256 trackerBaseTokenDelta) = vamm.vammSwap(params);

        assertAlmostEqual(trackerBaseTokenDelta, amountSpecified);
        // TODO: verify that VAMM state and trackerFixedTokenDelta is as expected
    }

    function test_Swap_MovingLeft() public {
        int256 amountSpecified =  -500_000_000;

        VAMMBase.SwapParams memory params = VAMMBase.SwapParams({
            amountSpecified: amountSpecified,
            sqrtPriceLimitX96: TickMath.getSqrtRatioAtTick(TickMath.MIN_TICK + 1)
        });

        // Mock the liquidity index that is read during a swap
        vm.mockCall(mockRateOracle, abi.encodeWithSelector(IRateOracle.getCurrentIndex.selector), abi.encode(mockLiquidityIndex));
        (int256 trackerFixedTokenDelta, int256 trackerBaseTokenDelta) = vamm.vammSwap(params);

        assertAlmostEqual(trackerBaseTokenDelta, amountSpecified);
        // TODO: verify that VAMM state and trackerFixedTokenDelta is as expected
    }

    function test_Swap_MovingMaxRight() public {
        int24 tickLimit = ACCOUNT_2_TICK_UPPER + 1;

        VAMMBase.SwapParams memory params = VAMMBase.SwapParams({
            amountSpecified: 500_000_000_000_000_000_000_000_000_000_000, // There is not enough liquidity - swap should max out at baseTradeableToRight
            sqrtPriceLimitX96: TickMath.getSqrtRatioAtTick(tickLimit)
        });

        // Mock the liquidity index that is read during a swap
        vm.mockCall(mockRateOracle, abi.encodeWithSelector(IRateOracle.getCurrentIndex.selector), abi.encode(mockLiquidityIndex));
        (int256 trackerFixedTokenDelta, int256 trackerBaseTokenDelta) = vamm.vammSwap(params);

        assertAlmostEqual(trackerBaseTokenDelta, baseTradeableToRight);
        assertEq(vamm.tick(), tickLimit);
        assertEq(vamm.sqrtPriceX96(), TickMath.getSqrtRatioAtTick(tickLimit));
        // TODO: verify that trackerFixedTokenDelta is as expected
    }

    function test_Swap_MovingMaxLeft() public {
        int24 tickLimit = TickMath.MIN_TICK + 1;

        VAMMBase.SwapParams memory params = VAMMBase.SwapParams({
            amountSpecified: -500_000_000_000_000_000_000_000_000_000_000, // There is not enough liquidity - swap should max out at baseTradeableToLeft
            sqrtPriceLimitX96: TickMath.getSqrtRatioAtTick(tickLimit)
        });

        // Mock the liquidity index that is read during a swap
        vm.mockCall(mockRateOracle, abi.encodeWithSelector(IRateOracle.getCurrentIndex.selector), abi.encode(mockLiquidityIndex));

        (int256 trackerFixedTokenDelta, int256 trackerBaseTokenDelta) = vamm.vammSwap(params);

        assertAlmostEqual(trackerBaseTokenDelta, -baseTradeableToLeft);
        assertEq(vamm.tick(), tickLimit);
        assertEq(vamm.sqrtPriceX96(), TickMath.getSqrtRatioAtTick(tickLimit));
        // TODO: verify that trackerFixedTokenDelta is as expected
    }

    function test_FirstMint() public returns (int256, int24, int24, uint128) {
        int256 baseAmount =  500_000_000;
        int24 tickLower = -3300;
        int24 tickUpper = -2940;
        uint128 accountId = 738;

        console2.log("TICK", vamm.ticks(tickLower).trackerBaseTokenGrowthOutsideX128);
        console2.log("TICK", vamm.ticks(tickUpper).trackerBaseTokenGrowthOutsideX128);
        console2.log(
            vamm.trackerBaseTokenGrowthGlobalX128() 
        );

        int128 requestedLiquidityAmount = getLiquidityForBase(tickLower, tickUpper, baseAmount);
        vamm.executeDatedMakerOrder(accountId, tickLower, tickUpper, requestedLiquidityAmount);

        uint128 posId = LPPosition.getPositionId(accountId, tickLower, tickUpper);
        LPPosition.Data memory position = vamm.position(posId);
        assertEq(position.liquidity.toInt(), requestedLiquidityAmount);
        assertEq(position.trackerFixedTokenAccumulated, 0);
        assertEq(position.trackerBaseTokenAccumulated, 0);
        assertEq(position.trackerBaseTokenUpdatedGrowth, 0);
        assertEq(position.trackerFixedTokenUpdatedGrowth, 0);

        // get global growth 
        // given ticks, check g

        return (baseAmount, tickLower, tickUpper, accountId);
    }

    function test_SecondMint_SameTicks() public {
        (int256 baseAmount, int24 tickLower, int24 tickUpper, uint128 accountId) = test_FirstMint();

        int128 requestedLiquidityAmount = getLiquidityForBase(tickLower, tickUpper, baseAmount);
        vamm.executeDatedMakerOrder(accountId, tickLower, tickUpper, requestedLiquidityAmount);

        uint128 posId = LPPosition.getPositionId(accountId, tickLower, tickUpper);
        LPPosition.Data memory position = vamm.position(posId);
        assertEq(position.liquidity.toInt(), requestedLiquidityAmount * 2);
        assertEq(position.trackerFixedTokenAccumulated, 0);
        assertEq(position.trackerBaseTokenAccumulated, 0);
        assertEq(position.trackerBaseTokenUpdatedGrowth, 0);
        assertEq(position.trackerFixedTokenUpdatedGrowth, 0);
    }

    function test_MintAndSwap_TrackerValue() public {
        (int256 baseAmount, int24 tickLower, int24 tickUpper, uint128 accountId) = test_FirstMint();

        int256 amountSwap =  -10;
        console2.log("Liq", vamm.liquidity());

        VAMMBase.SwapParams memory params = VAMMBase.SwapParams({
            amountSpecified: amountSwap,
            sqrtPriceLimitX96: TickMath.MIN_SQRT_RATIO + 1
        });

        // Mock the liquidity index that is read during a swap
        vm.mockCall(mockRateOracle, abi.encodeWithSelector(IRateOracle.getCurrentIndex.selector), abi.encode(mockLiquidityIndex));
        (int256 trackerFixedTokenDelta, int256 trackerBaseTokenDelta) = vamm.vammSwap(params);

        console2.log("FTs", trackerFixedTokenDelta);
        console2.log("VTs", trackerBaseTokenDelta);

        /*
        ((1 + (1.0001 ^ 32095) * 1) * 2 * -base) * 2^128 / 916703985467
         (1 + (1.0001 ^ midtick) * yearsToMaturity) * oracleINdex * -base * Q128 / liquidity = FT delta /liquidity
            -------avg price----
        */
    }
}